-- Network-free conversion of a saved MP article to a standalone EPUB.
-- A fresh child owns every input handle; the native reader is never inherited.
local Protocol=require('weread.lib.protocol')
local M={MAX_HTML=4*1024*1024,MAX_OUTPUT=72*1024*1024,MAX_IMAGE=32*1024*1024,
    MAX_ASSETS=512,MAX_ASSET_BYTES=64*1024*1024,MAX_NODES=100000}
local function fail(reason) error('mp_export/'..reason,0) end
local function valid_text(value,limit)
    return type(value)=='string' and #value<=limit and not value:find('[%z\1-\8\11\12\14-\31\127]')
        and not value:find('\239\191\190',1,true) and not value:find('\239\191\191',1,true)
        and Protocol.utf8_substr(value,#value+1)==value
end
local function escaped(value)
    return (value:gsub('&','&amp;'):gsub('<','&lt;'):gsub('>','&gt;'):gsub('"','&quot;'))
end
local function metadata(value,fallback)
    if value==nil or value=='' then value=fallback or '' end
    if not valid_text(value,4096) then fail('invalid_metadata') end
    return value:gsub('[\n\r\t]+',' ')
end
function M.directory(settings)
    local root=settings.data_dir
    if type(root)~='string' or root=='' or root:find('[%z%c]') then return nil end
    return root:gsub('/+$','')..'/exports/articles'
end
function M.is_export_path(settings,path)
    local root=M.directory(settings)
    return root and type(path)=='string' and path:sub(1,#root+1)==root..'/' or false
end
function M.same(a,b)
    return a and b and a.mode=='file' and b.mode=='file' and a.dev==b.dev and a.ino==b.ino
        and a.size==b.size and a.modification==b.modification
end
function M.mime(head)
    if head:sub(1,8)=='\137PNG\r\n\26\n' then return 'image/png','png' end
    if head:sub(1,3)=='\255\216\255' then return 'image/jpeg','jpg' end
    if head:sub(1,6)=='GIF87a' or head:sub(1,6)=='GIF89a' then return 'image/gif','gif' end
    if head:sub(1,4)=='RIFF' and head:sub(9,12)=='WEBP' then return 'image/webp','webp' end
end
local tags={p='p',div='div',section='div',article='div',figure='div',figcaption='div',span='span',
    h1='h1',h2='h2',h3='h3',h4='h4',h5='h5',h6='h6',ul='ul',ol='ol',li='li',dl='dl',dt='dt',dd='dd',
    blockquote='blockquote',pre='pre',code='code',em='em',strong='strong',b='b',i='i',u='u',s='s',
    sup='sup',sub='sub',ruby='ruby',rt='rt',rp='rp',a='a',table='table',thead='thead',tbody='tbody',
    tfoot='tfoot',tr='tr',td='td',th='th',caption='caption',br='br',hr='hr',img='img'}
local void={br=true,hr=true,img=true,meta=true,link=true,input=true,source=true,area=true,base=true,wbr=true,col=true,embed=true}
local skip={script=true,style=true,iframe=true,object=true,embed=true,svg=true,math=true,template=true,
    audio=true,video=true,noscript=true}
local function tag_end(html,start)
    local quote
    for at=start+1,#html do
        local byte=html:sub(at,at)
        if quote then if byte==quote then quote=nil end
        elseif byte=='"' or byte=="'" then quote=byte
        elseif byte=='>' then return at end
    end
    fail('invalid_html')
end
local function attributes(raw,decode)
    local result,at={},1
    while at<=#raw do
        local _,last,key=raw:find('^%s*([%w_:.-]+)',at)
        if not last then if raw:sub(at):match('^%s*/?%s*$') then break end;fail('invalid_html') end
        key=key:lower();at=last+1
        local _,equals=raw:find('^%s*=%s*',at)
        local value=''
        if equals then
            at=equals+1;local quote=raw:sub(at,at)
            if quote=='"' or quote=="'" then
                local finish=raw:find(quote,at+1,true);if not finish then fail('invalid_html') end
                value=raw:sub(at+1,finish-1);at=finish+1
            else
                local start,finish=raw:find('^[^%s>]+',at);if not start then fail('invalid_html') end
                value=raw:sub(start,finish);at=finish+1
            end
        end
        if key=='src' or key=='data-src' or key=='href' or key=='id' or key=='alt' or key=='colspan' or key=='rowspan' then
            if result[key]~=nil then fail('invalid_html') end
            value=decode(value)
            if not valid_text(value,M.MAX_HTML) then fail('invalid_html') end
            result[key]=value
        end
    end
    return result
end
-- Normalize saved HTML into well-formed passive XHTML. Only saved bitmap
-- resources and explicit HTTPS/fragment links survive; no CSS/JS/URL fetches.
function M.convert(html,resolve,decode,missing_label)
    if not valid_text(html,M.MAX_HTML) then fail('invalid_html') end
    local out,stack,ids={}, {},{}
    local lower,at,body,closed,seen,nodes,bytes,missing=html:lower(),1,false,false,false,0,0,0
    local function emit(value)
        bytes=bytes+#value;if bytes>M.MAX_HTML*2 then fail('too_large') end
        out[#out+1]=value
    end
    local function pop(to)
        for index=#stack,to,-1 do emit('</'..stack[index].tag..'>');stack[index]=nil end
    end
    while at<=#html do
        local start=html:find('<',at,true)
        if body then
            local text=decode(html:sub(at,start and start-1 or #html))
            if not valid_text(text,M.MAX_HTML) then fail('invalid_html') end
            emit(escaped(text))
        end
        if not start then break end
        if html:sub(start,start+3)=='<!--' then
            local finish=html:find('-->',start+4,true);if not finish then fail('invalid_html') end;at=finish+3
        else
            local finish=tag_end(html,start)
            local closing,name,raw=html:sub(start+1,finish-1):match('^%s*(/?)%s*([%w:-]+)(.-)%s*$')
            at=finish+1
            if name then
                name=name:lower();nodes=nodes+1;if nodes>M.MAX_NODES then fail('too_large') end
                if name=='body' then
                    if closing=='/' then if not body then fail('invalid_html') end;pop(1);body=false;closed=true
                    else if seen or closed then fail('invalid_html') end;seen=true;body=true end
                elseif body then
                    if skip[name] and closing~='/' and not void[name] and not raw:match('/%s*$') then
                        local ending=lower:find('</'..name..'%s*>',at)
                        if not ending then fail('invalid_html') end;at=tag_end(html,ending)+1
                    elseif not skip[name] and tags[name] then
                        if closing=='/' then
                            for index=#stack,1,-1 do if stack[index].name==name then pop(index);break end end
                        else
                            local attrs=attributes(raw,decode)
                            -- HTML's common implicit end tags remain readable.
                            if name=='p' or name=='li' or name=='tr' or name=='td' or name=='th' then
                                for index=#stack,1,-1 do
                                    local prior=stack[index].name
                                    if prior==name or (name=='td' or name=='th') and (prior=='td' or prior=='th') then pop(index);break end
                                    if prior=='div' or prior=='table' or prior=='ul' or prior=='ol' then break end
                                end
                            end
                            local tag,extra=tags[name],''
                            if name=='img' then
                                local href=resolve(attrs.src or attrs['data-src'] or '')
                                if href then extra=' src="'..escaped(href)..'" alt="'..escaped(attrs.alt or '')..'"'
                                else missing=missing+1;emit('<span>['..escaped(attrs.alt~='' and attrs.alt or missing_label or 'Image unavailable')..']</span>');tag=nil end
                            elseif name=='a' then
                                local href=attrs.href or ''
                                if href:match('^#[%w_.:-]+$') and #href<=129 then extra=' href="#mp-'..escaped(href:sub(2))..'"'
                                elseif #href<=4096 and (href:match('^https://[^/@%s?#]+[/#?]') or href:match('^https://[^/@%s?#]+$'))
                                    and not href:find('[%z%c%s]') then extra=' href="'..escaped(href)..'"' end
                            elseif name=='td' or name=='th' then
                                for _i,key in ipairs({'colspan','rowspan'}) do
                                    local n=tonumber(attrs[key]);if n and n>=1 and n<=100 and n%1==0 then extra=extra..' '..key..'="'..n..'"' end
                                end
                            end
                            local id=attrs.id
                            if tag and id and #id<=128 and id:match('^[%w_.:-]+$') and not ids[id] then ids[id]=true;extra=extra..' id="mp-'..escaped(id)..'"' end
                            if tag then
                                emit('<'..tag..extra..(void[name] and '/>' or '>'))
                                if not void[name] then
                                    if raw:match('/%s*$') then emit('</'..tag..'>')
                                    else stack[#stack+1]={name=name,tag=tag};if #stack>128 then fail('too_large') end end
                                end
                            end
                        end
                    end
                end
            elseif body and html:sub(start,start+1)~='<!' then fail('invalid_html') end
        end
    end
    if not seen or not closed or #stack>0 then fail('invalid_html') end
    return table.concat(out),missing
end
local function checked_file(path,identity,limit)
    local lfs=require('libs/libkoreader-lfs')
    local info=lfs.symlinkattributes(path)
    if not info or info.mode~='file' or info.size<1 or info.size>limit or identity and not M.same(info,identity) then fail('source_changed') end
    local file=io.open(path,'rb');if not file then fail('source_unavailable') end
    return file,info
end
local function image_resolver(input,assets)
    local root=input.path:match('^(.*)/[^/]+$')
    local key=tostring(input.article.reviewId or '')
    if key=='' then key=tostring(input.article.originalId or '') end
    if key=='' then key=tostring(input.article.bookId or input.book.book_id or input.book.bookId or '') end
    if key=='' then key=tostring(input.article.title or 'article') end
    local directory='.weread-mp-'..key:gsub('[^%w%._-]','_')..'-assets'
    local seen,total={},0
    return function(src)
        if seen[src]~=nil then return seen[src] or nil end
        seen[src]=false
        local asset={}
        if src:sub(1,11)=='data:image/' then
            local encoded=src:match('^data:image/[%w.+-]+;base64,([A-Za-z0-9+/=\r\n]+)$')
            if not encoded or #encoded>M.MAX_HTML or #encoded%4~=0 then return nil end
            asset.data=require('mime').unb64(encoded)
            if type(asset.data)~='string' then return nil end
            asset.size=#asset.data;asset.media,asset.ext=M.mime(asset.data)
        elseif src:sub(1,#directory+1)==directory..'/' and src:sub(#directory+2):match('^img%-%d+%.[%w]+$') then
            local lfs=require('libs/libkoreader-lfs')
            if lfs.symlinkattributes(root..'/'..directory,'mode')~='directory' then return nil end
            asset.path=root..'/'..src
            local info=lfs.symlinkattributes(asset.path)
            if not info or info.mode~='file' then return nil end
            if info.size>M.MAX_IMAGE then fail('too_large') end
            local file=io.open(asset.path,'rb');if not file then return nil end
            local head=file:read(32) or '';file:close()
            asset.media,asset.ext=M.mime(head);asset.size=info.size;asset.identity=info
        else return nil end
        if not asset.media or asset.size<1 then return nil end
        total=total+asset.size
        if #assets>=M.MAX_ASSETS or total>M.MAX_ASSET_BYTES then fail('too_large') end
        asset.href='images/image-'..(#assets+1)..'.'..asset.ext;assets[#assets+1]=asset
        seen[src]=asset.href;return asset.href
    end
end
function M.write(input,output,labels)
    labels=labels or {}
    local file,info=checked_file(input.path,input.identity,input.path:match('%.epub$') and M.MAX_OUTPUT or M.MAX_HTML)
    local resources,missing={},0
    local writer
    local ok,result=pcall(function()
        if input.path:match('%.epub$') then
            local members=require('weread.lib.source_archive').read(input.path,{mimetype=64})
            if not members or members.mimetype~='application/epub+zip' then fail('invalid_epub') end
            local remaining=info.size
            while remaining>0 do
                local chunk=file:read(math.min(65536,remaining))
                if not chunk or #chunk==0 or not output:write(chunk) then fail('write_failed') end
                remaining=remaining-#chunk
            end
        else
            local raw=file:read(M.MAX_HTML+1)
            if not raw or #raw~=info.size then fail('source_changed') end
            local body
            body,missing=M.convert(raw,image_resolver(input,resources),require('util').htmlEntitiesToUtf8,labels.missing)
            local title=metadata(input.article.title,'Article')
            local author=metadata(input.book.title or input.book.author)
            local creator=author~='' and '<dc:creator>'..escaped(author)..'</dc:creator>' or ''
            local id='urn:sha256:'..require('weread.lib.crypto').sha256_hex(raw..'\0'..title..'\0'..author)
            local manifest={}
            for index,asset in ipairs(resources) do manifest[#manifest+1]='<item id="img'..index..'" href="'..asset.href..'" media-type="'..asset.media..'"/>' end
            local xml='<?xml version="1.0" encoding="UTF-8"?>\n'
            local xhtml=xml..'<html xmlns="http://www.w3.org/1999/xhtml" lang="zh-CN"><head><title>'..escaped(title)..'</title>'
                ..'<style>body { line-height:1.7; } img { max-width:100%; height:auto; } pre { white-space:pre-wrap; } table { max-width:100%; }</style>'
                ..'</head><body>'..body..'</body></html>'
            writer=require('weread.lib.epub_export_writer').new(output.fd)
            writer:add('mimetype','application/epub+zip',20,true)
            local entries={
                {'META-INF/container.xml',xml..'<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="EPUB/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>'},
                {'EPUB/package.opf',xml..'<package version="3.0" xmlns="http://www.idpf.org/2007/opf" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">'..id..'</dc:identifier><dc:title>'..escaped(title)..'</dc:title>'..creator..'<dc:language>zh-CN</dc:language><meta property="dcterms:modified">'..os.date('!%Y-%m-%dT%H:%M:%SZ')..'</meta></metadata><manifest><item id="article" href="article.xhtml" media-type="application/xhtml+xml"/><item id="nav" href="nav.xhtml" properties="nav" media-type="application/xhtml+xml"/>'..table.concat(manifest)..'</manifest><spine><itemref idref="article"/></spine></package>'},
                {'EPUB/nav.xhtml',xml..'<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="zh-CN"><head><title>'..escaped(title)..'</title></head><body><nav epub:type="toc"><h1>'..escaped(title)..'</h1><ol><li><a href="article.xhtml">'..escaped(title)..'</a></li></ol></nav></body></html>'},
                {'EPUB/article.xhtml',xhtml},
            }
            for _i,entry in ipairs(entries) do writer:add(entry[1],entry[2],#entry[2]) end
            for _i,asset in ipairs(resources) do
                if asset.data then writer:add('EPUB/'..asset.href,asset.data,asset.size,true)
                else
                    local image=checked_file(asset.path,asset.identity,M.MAX_IMAGE)
                    local added=pcall(writer.add,writer,'EPUB/'..asset.href,function() return image:read(65536) end,asset.size,true)
                    image:close()
                    if not added or not M.same(asset.identity,require('libs/libkoreader-lfs').symlinkattributes(asset.path)) then fail('source_changed') end
                end
            end
            if not writer:close() then fail('write_failed') end;writer=nil
        end
        if not M.same(info,require('libs/libkoreader-lfs').symlinkattributes(input.path)) then fail('source_changed') end
        if not output:sync() then fail('write_failed') end
        local bytes=tonumber(output.ffi.C.lseek(output.fd,0,output.ffi.C.SEEK_CUR))
        if not bytes or bytes<1 or bytes>M.MAX_OUTPUT then fail('too_large') end
        return {ok=true,bytes=bytes,images=#resources,missing=missing,copied=input.path:match('%.epub$')~=nil}
    end)
    file:close();if writer then pcall(writer.close,writer) end
    if not ok then fail(type(result)=='string' and result:match('^mp_export/([a-z_]+)$') or 'unavailable') end
    return result
end
return M
