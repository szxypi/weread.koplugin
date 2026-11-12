-- Bounded independent EPUB reads. No extraction, network, or reader-owned ZIP.
local Model=require('weread.lib.translation')
local Identity=require('weread.lib.book_file_identity')
local Crypto=require('weread.lib.crypto')
local M={MAX_META=1024*1024,MAX_TOTAL=32*1024*1024,MAX_SPINE=2000,MAX_PAIRS=20000,MAX_ENTRIES=100000}
local function fail(reason) error('translation_archive/'..reason,0) end
local function unescape(value)
    local ok=true
    value=value:gsub('&([^;]+);',function(name)
        local named={amp='&',lt='<',gt='>',quot='"',apos="'"}
        if named[name] then return named[name] end
        local n=tonumber(name:match('^#(%d+)$') or '') or tonumber(name:match('^#[xX](%x+)$') or '',16)
        if not n or n<1 or n>0x10ffff or n>=0xd800 and n<=0xdfff then ok=false;return '' end
        if n<128 then return string.char(n) end
        if n<2048 then return string.char(192+math.floor(n/64),128+n%64) end
        if n<65536 then return string.char(224+math.floor(n/4096),128+math.floor(n/64)%64,128+n%64) end
        return string.char(240+math.floor(n/262144),128+math.floor(n/4096)%64,128+math.floor(n/64)%64,128+n%64)
    end)
    if not ok then fail('xml_entity') end
    return value
end
local function xml(raw)
    if type(raw)~='string' or #raw>M.MAX_META or raw:find('<!DOCTYPE',1,true) or raw:find('<!ENTITY',1,true) then fail('xml_invalid') end
    local root,stack,count,at=nil,{},0,1
    while at<=#raw do
        local start=raw:find('<',at,true)
        local text=raw:sub(at,start and start-1 or #raw)
        if #stack>0 then stack[#stack].text=stack[#stack].text..text elseif text:find('%S') then fail('xml_invalid') end
        if not start then break end
        local finish
        if raw:sub(start,start+3)=='<!--' then
            finish=raw:find('-->',start+4,true);if not finish then fail('xml_invalid') end
            at=finish+3
        elseif raw:sub(start,start+1)=='<?' then
            finish=raw:find('?>',start+2,true);if not finish then fail('xml_invalid') end
            at=finish+2
        else
            local quote
            for index=start+1,#raw do
                local char=raw:sub(index,index)
                if quote then if char==quote then quote=nil end
                elseif char=='"' or char=="'" then quote=char
                elseif char=='>' then finish=index;break end
            end
            if not finish then fail('xml_invalid') end
            local token=raw:sub(start+1,finish-1)
            local closing,full,attrs=token:match('^%s*(/?)%s*([%w_:.-]+)(.-)%s*$')
            if not full then fail('xml_invalid') end
            local name=full:match('([^:]+)$')
            if closing=='/' then
                if attrs:find('%S') or not stack[#stack] or stack[#stack].full~=full then fail('xml_invalid') end
                table.remove(stack)
            else
                count=count+1;if count>20000 or #stack>=64 then fail('xml_limit') end
                local node={name=name,full=full,attrs={},children={},text=''}
                local self_close=attrs:match('/%s*$')~=nil
                if self_close then attrs=attrs:gsub('/%s*$','') end
                local cursor=1
                while cursor<=#attrs do
                    local s,e,key,_,value=attrs:find('^%s*([%w_:.-]+)%s*=%s*([\'"])(.-)%2',cursor)
                    if not s then if attrs:sub(cursor):find('%S') then fail('xml_attributes') end;break end
                    if node.attrs[key]~=nil then fail('xml_attributes') end
                    node.attrs[key]=unescape(value);cursor=e+1
                end
                if #stack>0 then local children=stack[#stack].children;children[#children+1]=node
                elseif root then fail('xml_invalid') else root=node end
                if not self_close then stack[#stack+1]=node end
            end
            at=finish+1
        end
    end
    if #stack>0 or not root then fail('xml_invalid') end
    return root
end
local function children(node,name)
    local out={};for _,child in ipairs(node.children) do if child.name==name then out[#out+1]=child end end;return out
end
local function single(node,name)
    local list=children(node,name);if #list~=1 then fail('xml_structure') end;return list[1]
end
function M.path(base,href)
    if type(href)~='string' or href=='' or #href>1024 or href:gsub('%%[%x][%x]',''):find('%%') then fail('path_invalid') end
    href=href:gsub('%%(%x%x)',function(value) return string.char(tonumber(value,16)) end)
    if href:find('[%z%c\\:#?]') or href:sub(1,1)=='/' then fail('path_invalid') end
    local parts={}
    for part in ((base or '')..href):gmatch('[^/]+') do
        if part=='..' then if #parts==0 then fail('path_invalid') end;table.remove(parts)
        elseif part~='.' then parts[#parts+1]=part end
    end
    local result=table.concat(parts,'/')
    if result=='' or #result>1024 then fail('path_invalid') end
    return result
end
function M.container(raw)
    local root=xml(raw);if root.name~='container' then fail('container_invalid') end
    local entries=children(single(root,'rootfiles'),'rootfile')
    if #entries~=1 or entries[1].attrs['media-type']~='application/oebps-package+xml' then fail('container_invalid') end
    return M.path('',entries[1].attrs['full-path'])
end
function M.plan(path,raw,book_id,identity_raw)
    if type(book_id)~='string' or #book_id>128 or not book_id:match('^[%w_-]+$') then fail('book_invalid') end
    local root=xml(raw);if root.name~='package' then fail('package_invalid') end
    local metadata=single(root,'metadata');local selected
    for _,node in ipairs(children(metadata,'identifier')) do
        if node.attrs.id==root.attrs['unique-identifier'] then if selected then fail('book_invalid') end;selected=unescape(node.text) end
    end
    local prefix='weread-'..book_id..'-'
    if not selected or selected:sub(1,#prefix)~=prefix then fail('book_mismatch') end
    local identity=identity_raw and Identity.decode(identity_raw)
    if identity_raw and (not identity or identity.book_id~=book_id) then fail('book_mismatch') end
    local manifest={}
    for _,item in ipairs(children(single(root,'manifest'),'item')) do
        local id=item.attrs.id
        if not id or id=='' or manifest[id] then fail('manifest_invalid') end
        manifest[id]=item.attrs
    end
    local result={schema=1,book_id=book_id,file_id=identity and identity.file_id or '',opf_path=path,
        opf_sha256=Crypto.sha256_hex(raw),members={}}
    local base=path:match('^(.*/)') or '';local seen={}
    for index,item in ipairs(children(single(root,'spine'),'itemref')) do
        local entry=manifest[item.attrs.idref]
        if index>M.MAX_SPINE or not entry or item.attrs.linear=='no'
            or entry['media-type']~='application/xhtml+xml' and entry['media-type']~='text/html' then fail('spine_invalid') end
        local member=M.path(base,entry.href)
        if seen[member] then fail('spine_invalid') end
        seen[member]=true;result.members[index]=member
    end
    if #result.members==0 or identity and identity.chapter_count~=#result.members then fail('spine_invalid') end
    return result
end
-- Scan a fresh descriptor to EOF: reject duplicate selected entries and never
-- accept a first match from a malformed or ambiguous archive.
local function scan(path,wanted,visit)
    local ffi=require('ffi');require('ffi/libarchive_h')
    local lib=ffi.loadlib('archive','13');local archive,entry
    local ok,result=pcall(function()
        archive,entry=lib.archive_read_new(),lib.archive_entry_new()
        if archive==nil or entry==nil or lib.archive_read_support_format_all(archive)~=lib.ARCHIVE_OK
            or lib.archive_read_support_filter_all(archive)~=lib.ARCHIVE_OK
            or lib.archive_read_open_filename(archive,path,10240)~=lib.ARCHIVE_OK then fail('archive_unavailable') end
        local found,total={},0
        for _i=1,M.MAX_ENTRIES do
            local status=lib.archive_read_next_header2(archive,entry)
            if status==lib.ARCHIVE_EOF then return found end
            if status~=lib.ARCHIVE_OK then fail('archive_invalid') end
            local pointer=lib.archive_entry_pathname(entry);if pointer==nil then fail('archive_invalid') end
            local name=ffi.string(pointer);local maximum=wanted[name]
            if maximum then
                local size=tonumber(lib.archive_entry_size(entry))
                if found[name] or lib.archive_entry_filetype(entry)~=lib.AE_IFREG or not size or size<0 or size>maximum or size%1~=0 then fail('member_invalid') end
                local chunks,bytes={},0;local buffer=ffi.new('char[65536]')
                while true do
                    local count=tonumber(lib.archive_read_data(archive,buffer,65536))
                    if not count or count<0 then fail('member_invalid') end
                    if count==0 then break end
                    bytes,total=bytes+count,total+count
                    if bytes>size or total>M.MAX_TOTAL then fail('content_limit') end
                    chunks[#chunks+1]=ffi.string(buffer,count)
                end
                if bytes~=size then fail('member_invalid') end
                visit(name,table.concat(chunks));found[name]=true
            end
        end
        fail('archive_limit')
    end)
    if archive~=nil then pcall(lib.archive_read_close,archive);pcall(lib.archive_free,archive) end
    if entry~=nil then pcall(lib.archive_entry_free,entry) end
    if not ok then error(result,0) end
    return result
end
function M.inspect(path,book_id)
    local ok,profile=pcall(function()
        if type(path)~='string' or #path>4096 or path:find('[%z%c]') then fail('path_invalid') end
        local meta={}
        local found=scan(path,{['META-INF/container.xml']=M.MAX_META,[Identity.PATH]=Identity.MAX_BYTES},function(name,raw) meta[name]=raw end)
        if not found['META-INF/container.xml'] then fail('container_missing') end
        local opf=M.container(meta['META-INF/container.xml']);local package
        found=scan(path,{[opf]=M.MAX_META},function(_name,raw) package=raw end)
        if not found[opf] then fail('package_missing') end
        local plan=M.plan(opf,package,book_id,meta[Identity.PATH])
        local result={schema=1,book_id=plan.book_id,file_id=plan.file_id,opf_path=opf,opf_sha256=plan.opf_sha256,blocks=0,pairs=0,chapters={}}
        local wanted,ordinals={},{}
        for index,name in ipairs(plan.members) do wanted[name]=Model.MAX_HTML_BYTES;ordinals[name]=index end
        found=scan(path,wanted,function(name,raw)
            local index=ordinals[name]
            local chapter=Model.analyze(raw,tostring(index),index)
            if not chapter then fail('chapter_invalid') end
            result.blocks=result.blocks+chapter.blocks;result.pairs=result.pairs+#chapter.pairs
            if result.pairs>M.MAX_PAIRS then fail('pair_limit') end
            result.chapters[index]=chapter
        end)
        for _,name in ipairs(plan.members) do if not found[name] then fail('chapter_missing') end end
        return result
    end)
    if not ok then return nil,type(profile)=='string' and profile:match('^translation_archive/[a-z_]+$') or 'translation_archive/unavailable' end
    return profile
end
return M
