-- Read-only cloud targets. Real snapshots were verified by the Python probe.
-- Matching an EPUB's source never grants wire upload permission.
local Access=require('weread.lib.read_access')
local Cookie=require('weread.lib.cookie')
local Coordinates=require('weread.lib.source_coordinates')
local Crypto=require('weread.lib.crypto')
local Protocol=require('weread.lib.protocol')
local Source=require('weread.lib.position_source')
local M={capture=Access.capture,matches=Access.matches}
local function fail(reason) error('source_cloud/'..reason,0) end
local function number(value,maximum)
    return type(value)=='number' and value==value and value>=0 and value<=maximum
end
local function position(value,id)
    for _i=1,4 do
        if type(value)~='table' then break end
        if (value.errcode~=nil and tonumber(value.errcode)~=0) or (value.errCode~=nil and tonumber(value.errCode)~=0)
            or (value.succ~=nil and value.succ~=true and tonumber(value.succ)~=1) then fail('position_invalid') end
        local returned=value.bookId or value.book_id
        if returned~=nil and tostring(returned)~=id then fail('position_invalid') end
        if value.chapterUid~=nil or value.chapterOffset~=nil then
            local uid=Access.book_id(value.chapterUid)
            if not uid or not number(value.chapterOffset,2147483647) or value.chapterOffset%1~=0
                or not number(value.progress,100) then fail('position_invalid') end
            return {chapter_uid=uid,chapter_offset=value.chapterOffset,percent=value.progress}
        end
        value=value.book or value.data or value.result
    end
    fail('position_invalid')
end
local function same(first,last)
    return first.chapter_uid==last.chapter_uid and first.chapter_offset==last.chapter_offset and first.percent==last.percent
end
local function check_reader(id,first,reader)
    if type(reader)~='table' or type(reader.bookInfo)~='table' or Access.book_id(reader.bookInfo.bookId)~=id
        or type(reader.currentChapter)~='table' or Access.book_id(reader.currentChapter.chapterUid)~=first.chapter_uid
        or not same(first,position(reader.progress,id)) then fail('reader_mismatch') end
end

function M.project(id,before,reader,raw,after,format)
    format=format or 'web_xhtml'
    if format~='web_xhtml' and format~='web_txt' then fail('source_invalid') end
    id=Access.book_id(id)
    if not id then fail('invalid_book') end
    local first,last=position(before,id),position(after,id)
    if not same(first,last) then fail('target_changed') end
    check_reader(id,first,reader)
    if type(raw)~='string' or #raw<1 or #raw>Source.MAX_BYTES then fail('source_invalid') end
    local map=Coordinates.build(raw,{format=format})
    local anchor=map and map:anchor(first.chapter_offset)
    local reverse=anchor and map:locate_point(anchor.text,anchor.point_offset)
    if not reverse or reverse.co~=first.chapter_offset then fail('target_unavailable') end
    return {book_id=id,chapter_uid=first.chapter_uid,chapter_offset=first.chapter_offset,percent=first.percent,
        raw_sha256=Crypto.sha256_hex(raw),raw_bytes=#raw,basis=Source.coordinate_basis(format),upload_verified=false}
end

local function transport(client,id,selected)
    local function current() if not M.matches(client.settings,selected) then fail('session_changed') end end
    local function request(url,body,maximum,json,referer)
        current()
        local chunks,bytes,exceeded={},0,false
        local ok,_,code,headers=pcall(client.request,client,{url=url,method=body and 'POST' or 'GET',
            body=body and client:json_encode(body),skip_cookie=true,persist_response_cookies=false,sensitive=true,
            diagnostic_api='cloud_source',timeout={8,15},headers={Cookie=Cookie.to_header(selected.web.cookies),
                Origin='https://weread.qq.com',Referer=referer or Protocol.reader_url(id),['Content-Type']='application/json;charset=UTF-8'},
            sink=function(chunk)
                if not chunk then return 1 end
                bytes=bytes+#chunk;if bytes>maximum then exceeded=true;return nil,'source_cloud_limit' end
                chunks[#chunks+1]=chunk;return 1
            end})
        current()
        if not ok or exceeded or code~=200 then fail('unavailable') end
        local raw=table.concat(chunks)
        if json then return client:decode_http_json(raw,{sensitive=true,api_name='cloud_source',code=code,headers=headers}) end
        return raw
    end
    return request,current
end

function M.fetch(client,id,selected)
    id=Access.book_id(id)
    selected=selected or M.capture(client.settings)
    if not id or not selected or not selected.web then fail('web_required') end
    local request,current=transport(client,id,selected)
    local url='https://weread.qq.com/web/book/getProgress?bookId='..Protocol.urlencode(id)
    local before=request(url,nil,65536,true)
    local first=position(before,id)
    local referer=Protocol.reader_url(id,first.chapter_uid)
    local html=request(referer,nil,4*1024*1024,false,referer)
    local encoded=html:match([[window%.__INITIAL_STATE__%s*=%s*(%{.-%})%s*;%s*%(function]])
    local decoded,initial=pcall(client.json_decode,client,encoded or '')
    local reader=decoded and type(initial)=='table' and initial.reader
    if type(reader)~='table' or type(reader.psvts)~='string' or #reader.psvts<1 or #reader.psvts>8192
        or reader.psvts:find('[^!-~]') then fail('reader_invalid') end
    check_reader(id,first,reader)
    local params=Protocol.make_content_params(id,first.chapter_uid,reader.psvts,{sc=1})
    local first_part=request('https://weread.qq.com/web/book/chapter/e_0',params,4*1024*1024,false,referer)
    local format,parts='web_xhtml',{first_part}
    if first_part:match('^%s*{') then
        require('weread.lib.source_currentness').txt_marker(client,first_part,id,first.chapter_uid)
        format,parts='web_txt',{}
        for _i,name in ipairs({'t_0','t_1'}) do parts[#parts+1]=request('https://weread.qq.com/web/book/chapter/'..name,params,4*1024*1024,false,referer) end
        parts[3]=''
    else
        for _i,name in ipairs({'e_1','e_3'}) do parts[#parts+1]=request('https://weread.qq.com/web/book/chapter/'..name,params,4*1024*1024,false,referer) end
    end
    local valid,raw=pcall(require('weread.lib.content').decode_content_shards,unpack(parts))
    if not valid then fail('source_invalid') end
    local after=request(url,nil,65536,true,referer)
    local target=M.project(id,before,reader,raw,after,format)
    current()
    return target
end

function M.remote(value)
    if type(value)~='table' or not Access.book_id(value.book_id) or not Access.book_id(value.chapter_uid)
        or not number(value.chapter_offset,Source.MAX_BYTES*8) or value.chapter_offset%1~=0
        or not number(value.percent,100) or type(value.raw_sha256)~='string' or #value.raw_sha256~=64
        or not value.raw_sha256:match('^[0-9a-f]+$') or not number(value.raw_bytes,Source.MAX_BYTES) or value.raw_bytes<1
        or value.raw_bytes%1~=0 or not Source.is_coordinate_basis(value.basis) or value.upload_verified~=false then return nil end
    local out={}
    for _,key in ipairs({'book_id','chapter_uid','chapter_offset','percent','raw_sha256','raw_bytes','basis','upload_verified'}) do out[key]=value[key] end
    out.book_id,out.chapter_uid=Access.book_id(value.book_id),Access.book_id(value.chapter_uid)
    return out
end

local function valid_path(value)
    return type(value)=='string' and value~='' and #value<=4096 and not value:find('[%z%c]')
end

function M.bind_file(file,remote,request_id,read_archive)
    remote=M.remote(remote)
    if not valid_path(file) or not remote then return {error='target_invalid'} end
    local Identity=require('weread.lib.book_file_identity')
    local Archive=require('weread.lib.source_archive')
    local ok,members=pcall(read_archive or Archive.read,file,{[Identity.PATH]=Identity.MAX_BYTES})
    if not ok or type(members)~='table' then return {error='source_changed'} end
    local identity=members and Identity.decode(members[Identity.PATH])
    if not identity or identity.book_id~=remote.book_id then return {error='source_changed'} end
    local bound=M.bind({file=file,identity=identity,book_id=remote.book_id,request_id=request_id},remote,read_archive)
    if bound.position then bound.file,bound.identity=file,identity end
    return bound
end

local function book(settings,id)
    if settings.get_book then return settings:get_book(id) end
    return settings:get('books',{})[id]
end
local function chapter(rows,uid)
    if type(rows)~='table' or #rows>100000 then return nil end
    local found
    for _,row in ipairs(rows) do
        if type(row)=='table' and Access.book_id(row.chapterUid)==uid then
            if found then return nil end
            local title=row.title
            if type(title)~='string' or #title>1024 or title:find('[%z%c]') then title='' end
            found={chapterUid=uid,title=title}
            for _,key in ipairs({'chapterIdx','wordCount','level'}) do if number(row[key],1e10) then found[key]=row[key] end end
        end
    end
    return found
end
function M.download_chapter(client,remote,selected)
    remote=M.remote(remote)
    if not remote or not selected or not selected.web then fail('target_invalid') end
    if not M.matches(client.settings,selected) then fail('session_changed') end
    local saved=book(client.settings,remote.book_id) or {book_id=remote.book_id}
    local Content=require('weread.lib.content')
    local rows=Content.load_catalog_cache(client,client.settings,saved)
    local target=chapter(rows,remote.chapter_uid)
    if not target then
        local request,current=transport(client,remote.book_id,selected)
        local response=request('https://weread.qq.com/web/book/chapterInfos',{bookIds={remote.book_id}},4*1024*1024,true,
            Protocol.reader_url(remote.book_id,remote.chapter_uid))
        target=chapter(Content.normalize_chapters(response,remote.book_id),remote.chapter_uid)
        current()
    end
    if not M.matches(client.settings,selected) then fail('session_changed') end
    return target
end

-- Inspect only the requested chapter and explicit full/legacy cache candidates.
function M.resolve(client,input,remote,selected,read_archive)
    remote=M.remote(remote)
    if type(input)~='table' or not valid_path(input.file) or not remote or remote.book_id~=input.book_id then return {error='target_invalid'} end
    local bound=M.bind(input,remote,read_archive)
    if bound.position then return bound end
    local saved=book(client.settings,input.book_id) or {}
    local visited={[input.file]=true}
    for _,candidate in ipairs({saved.cached_chapters and saved.cached_chapters[remote.chapter_uid] or false,
        saved.cached_full_book or false,saved.cached_file or false}) do
        if valid_path(candidate) and not visited[candidate] then
            visited[candidate]=true
            local result=M.bind_file(candidate,remote,input.request_id,read_archive)
            if result.position then result.remote=remote;return result end
        end
    end
    local target=M.download_chapter(client,remote,selected)
    return {error=bound.error or 'source_changed',remote=remote,chapter=target,request_id=input.request_id}
end

-- Worker-only archive binding. Re-open independently and verify the original
-- source plus rendered chapter before returning a bounded, local target.
function M.bind(input,remote,read_archive)
    local ok,result=pcall(function()
        if type(input)~='table' or type(input.identity)~='table' or type(remote)~='table'
            or remote.book_id~=input.book_id or not Access.book_id(remote.chapter_uid)
            or not Source.is_coordinate_basis(remote.basis) or remote.upload_verified~=false
            or not number(remote.chapter_offset,Source.MAX_BYTES*8) or remote.chapter_offset%1~=0 then return {error='target_invalid'} end
        local Archive=require('weread.lib.source_archive')
        local Identity=require('weread.lib.book_file_identity')
        local path=Source.meta_path(remote.chapter_uid)
        local members=(read_archive or Archive.read)(input.file,{[Identity.PATH]=Identity.MAX_BYTES,[path]=Source.MAX_META_BYTES})
        local identity=members and Identity.decode(members[Identity.PATH])
        local metadata=members and members[path]
        local record=Source.decode_metadata(metadata)
        if not identity or identity.file_id~=input.identity.file_id or identity.book_id~=input.book_id
            or not record or record.file_id~=identity.file_id or record.book_id~=input.book_id
            or record.chapter_uid~=remote.chapter_uid or record.raw_sha256~=remote.raw_sha256
            or record.raw_bytes~=remote.raw_bytes or Source.coordinate_basis(record.format)~=remote.basis then return {error='source_changed'} end
        local target={chapter_offset=remote.chapter_offset,basis=remote.basis,upload_verified=false}
        for _,key in ipairs({'book_id','chapter_uid','file_id','book_version','raw_sha256','render_path'}) do target[key]=record[key] end
        local prepared=require('weread.lib.source_position_worker').prepare_target({file=input.file,book_id=input.book_id,
            chapter_uid=record.chapter_uid,render_path=record.render_path,identity=input.identity,metadata=metadata,
            target=target,request_id=input.request_id},read_archive)
        if not prepared.position then return {error=prepared.error or 'target_unavailable'} end
        return {position=prepared.position,metadata=metadata,request_id=input.request_id,remote=M.remote(remote)}
    end)
    return ok and result or {error='target_unavailable'}
end
return M
