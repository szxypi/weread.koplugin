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

function M.project(id,before,reader,raw,after)
    id=Access.book_id(id)
    if not id then fail('invalid_book') end
    local first,last=position(before,id),position(after,id)
    if not same(first,last) then fail('target_changed') end
    check_reader(id,first,reader)
    if type(raw)~='string' or #raw<1 or #raw>Source.MAX_BYTES then fail('source_invalid') end
    local map=Coordinates.build(raw)
    local anchor=map and map:anchor(first.chapter_offset)
    local reverse=anchor and map:locate_point(anchor.text,anchor.point_offset)
    if not reverse or reverse.co~=first.chapter_offset then fail('target_unavailable') end
    return {book_id=id,chapter_uid=first.chapter_uid,chapter_offset=first.chapter_offset,percent=first.percent,
        raw_sha256=Crypto.sha256_hex(raw),raw_bytes=#raw,basis='filtered_xhtml_utf16',upload_verified=false}
end

function M.fetch(client,id,selected)
    id=Access.book_id(id)
    selected=selected or M.capture(client.settings)
    if not id or not selected or not selected.web then fail('web_required') end
    local referer=Protocol.reader_url(id)
    local function current() if not M.matches(client.settings,selected) then fail('session_changed') end end
    local function request(url,body,maximum,json)
        current()
        local chunks,bytes,exceeded={},0,false
        local ok,_,code,headers=pcall(client.request,client,{url=url,method=body and 'POST' or 'GET',
            body=body and client:json_encode(body),skip_cookie=true,persist_response_cookies=false,sensitive=true,
            diagnostic_api='cloud_source',timeout={8,15},headers={Cookie=Cookie.to_header(selected.web.cookies),
                Origin='https://weread.qq.com',Referer=referer,['Content-Type']='application/json;charset=UTF-8'},
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
    local url='https://weread.qq.com/web/book/getProgress?bookId='..Protocol.urlencode(id)
    local before=request(url,nil,65536,true)
    local first=position(before,id)
    referer=Protocol.reader_url(id,first.chapter_uid)
    local html=request(Protocol.reader_url(id,first.chapter_uid),nil,4*1024*1024)
    local encoded=html:match([[window%.__INITIAL_STATE__%s*=%s*(%{.-%})%s*;%s*%(function]])
    local decoded,initial=pcall(client.json_decode,client,encoded or '')
    local reader=decoded and type(initial)=='table' and initial.reader
    if type(reader)~='table' or type(reader.psvts)~='string' or #reader.psvts<1 or #reader.psvts>8192
        or reader.psvts:find('[^!-~]') then fail('reader_invalid') end
    check_reader(id,first,reader)
    local params=Protocol.make_content_params(id,first.chapter_uid,reader.psvts,{sc=1})
    local parts={}
    for _,name in ipairs({'e_0','e_1','e_3'}) do
        parts[#parts+1]=request('https://weread.qq.com/web/book/chapter/'..name,params,4*1024*1024)
    end
    local valid,raw=pcall(require('weread.lib.content').decode_content_shards,unpack(parts))
    if not valid then fail('source_invalid') end
    local after=request(url,nil,65536,true)
    local target=M.project(id,before,reader,raw,after)
    current()
    return target
end

-- Worker-only archive binding. Re-open independently and verify the original
-- source plus rendered chapter before returning a bounded, local target.
function M.bind(input,remote,read_archive)
    local ok,result=pcall(function()
        if type(input)~='table' or type(input.identity)~='table' or type(remote)~='table'
            or remote.book_id~=input.book_id or not Access.book_id(remote.chapter_uid)
            or remote.basis~='filtered_xhtml_utf16' or remote.upload_verified~=false
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
            or record.raw_bytes~=remote.raw_bytes or record.format~='web_xhtml' then return {error='source_changed'} end
        local target={chapter_offset=remote.chapter_offset,basis='filtered_xhtml_utf16',upload_verified=false}
        for _,key in ipairs({'book_id','chapter_uid','file_id','book_version','raw_sha256','render_path'}) do target[key]=record[key] end
        local prepared=require('weread.lib.source_position_worker').prepare_target({file=input.file,book_id=input.book_id,
            chapter_uid=record.chapter_uid,render_path=record.render_path,identity=input.identity,metadata=metadata,
            target=target,request_id=input.request_id},read_archive)
        if not prepared.position then return {error=prepared.error or 'target_unavailable'} end
        return {position=prepared.position,metadata=metadata,request_id=input.request_id}
    end)
    return ok and result or {error='target_unavailable'}
end
return M
