-- Read and bind a native cloud position to the currently open native chapter.
-- This operation only reads; it never authorizes or dispatches progress writes.
local Access=require('weread.lib.native_read_access')
local Auth=require('weread.lib.native_authorization')
local Currentness=require('weread.lib.source_currentness')
local State=require('weread.lib.native_cloud_state')
local Remote=require('weread.lib.remote_progress')
local P=require('weread.lib.native_position_protocol')
local Position=require('weread.lib.native_direct_position')
local Protocol=require('weread.lib.protocol')
local Crypto=require('weread.lib.crypto')
local M={}
local function read_snapshot(raw,book_id)
    local node=Remote.node(raw,book_id)
    if not node then return nil end
    local counts=P.counts(node)
    local empty=State.from(raw,book_id)
    if empty then return {position=empty,counts=counts,none=true} end
    local point,reason,provided=Remote.project(raw,book_id,'native')
    if reason or not point or not provided.chapter_uid or not provided.chapter_idx or not provided.chapter_offset then return nil end
    local uid=P.id(point.chapter_uid)
    if not uid or not P.integer(point.chapter_idx,0,1000000) or not P.integer(point.chapter_offset,0,2147483647) then return nil end
    return {position={book_id=book_id,chapter_uid=uid,chapter_idx=point.chapter_idx,chapter_offset=point.chapter_offset,
        raw_percent=point.raw_percent,summary=point.summary,summary_present=provided.summary},counts=counts,none=false}
end
local function same(first,last)
    if not first or not last or first.none~=last.none or not P.same_counts(first.counts,last.counts) then return false end
    if first.none then return State.equal(first.position,last.position) end
    for _,key in ipairs({'book_id','chapter_uid','chapter_idx','chapter_offset','raw_percent','summary','summary_present'}) do
        if first.position[key]~=last.position[key] then return false end
    end
    return true
end
local function target(snapshot)
    if not snapshot or snapshot.none then return nil end
    local point,counts=snapshot.position,snapshot.counts
    local values={'native-direct-cloud-v1',point.book_id,point.chapter_uid,tostring(point.chapter_idx),
        tostring(point.chapter_offset),string.format('%.17g',point.raw_percent),point.summary_present and '1' or '0',
        point.summary,tostring(counts.readingTime),tostring(counts.recordReadingTime),tostring(counts.ttsTime)}
    return {book_id=point.book_id,chapter_uid=point.chapter_uid,chapter_idx=point.chapter_idx,
        chapter_offset=point.chapter_offset,stamp=Crypto.sha256_hex(table.concat(values,'\0'))}
end
function M.valid_target(value)
    if type(value)~='table' or P.id(value.book_id)~=value.book_id or P.id(value.chapter_uid)~=value.chapter_uid
        or not P.integer(value.chapter_idx,0,1000000) or not P.integer(value.chapter_offset,0,2147483647)
        or type(value.stamp)~='string' or #value.stamp~=64 or not value.stamp:match('^[a-f0-9]+$') then return false end
    local count=0
    for key in pairs(value) do
        if key~='book_id' and key~='chapter_uid' and key~='chapter_idx' and key~='chapter_offset' and key~='stamp' then return false end
        count=count+1
    end
    return count==5
end
function M.same_target(first,last)
    if not M.valid_target(first) or not M.valid_target(last) then return false end
    for _,key in ipairs({'book_id','chapter_uid','chapter_idx','chapter_offset','stamp'}) do
        if first[key]~=last[key] then return false end
    end
    return true
end
function M.prepare(client,settings,entry,file,context,native,web,current)
    local function active()
        local ok,valid=pcall(current)
        return ok and valid==true and Access.matches(settings,native) and Currentness.matches(settings,web)
    end
    if type(current)~='function' or type(entry)~='table' or P.id(entry.book_id)~=entry.book_id
        or type(native)~='table' or type(native.scope)~='table' or type(native.credentials)~='table'
        or native.scope.vid~=native.credentials.vid or not active() then
        return nil,'invalid'
    end
    local auth=Auth:new(client,{expected_vid=native.scope.vid,is_current=active})
    local ok,value=pcall(function()
        local url='https://i.weread.qq.com/book/getProgress?bookId='..Protocol.urlencode(entry.book_id)
        local function snapshot()
            local raw=auth:_request('direct_progress',url,nil,native.credentials)
            return assert(read_snapshot(raw,entry.book_id))
        end
        local before=snapshot();local cloud=before.position
        local same_chapter=not before.none and cloud.chapter_uid==entry.chapter_uid
        if same_chapter and cloud.chapter_idx~=entry.chapter_idx then return {error='cloud_changed'} end
        local point,why,anchor=Position.prepare(client,settings,entry,file,context,native,web,active,
            same_chapter and cloud.chapter_offset or nil)
        if not point then return {error=why or 'unavailable'} end
        local after=snapshot()
        if not same(before,after) or not active() then return {error='cloud_changed'} end
        if before.none then return {position=point,relation='no_chapter'} end
        local selected=target(before)
        if not same_chapter then return {position=point,relation='other_chapter',target=selected} end
        if cloud.chapter_offset==point.chapter_offset then return {position=point,relation='same',target=selected} end
        if not anchor then return {position=point,relation='target_unavailable',target=selected} end
        return {position=point,relation='different',anchor=anchor,cloud_offset=cloud.chapter_offset,target=selected}
    end)
    auth:cancel()
    if not ok then
        if not active() then return nil,'session_changed' end
        if value=='native_auth/direct_progress/http_401' then return nil,'auth_expired' end
        if value=='native_auth/direct_progress/http_429' then return nil,'rate_limited' end
        return nil,'unavailable'
    end
    if value.error then return nil,value.error end
    return value
end
function M.prepare_destination(client,settings,entry,file,native,web,current,wanted)
    local function active()
        local ok,value=pcall(current)
        return ok and value==true and Access.matches(settings,native) and Currentness.matches(settings,web)
    end
    if type(current)~='function' or not M.valid_target(wanted) or type(entry)~='table'
        or entry.book_id~=wanted.book_id or entry.chapter_uid~=wanted.chapter_uid
        or entry.chapter_idx~=wanted.chapter_idx or type(native)~='table' or type(native.scope)~='table'
        or type(native.credentials)~='table' or native.credentials.vid~=native.scope.vid or not active() then return nil,'invalid' end
    local auth=Auth:new(client,{expected_vid=native.scope.vid,is_current=active})
    local ok,value=pcall(function()
        local url='https://i.weread.qq.com/book/getProgress?bookId='..Protocol.urlencode(entry.book_id)
        local function snapshot()
            return assert(read_snapshot(auth:_request('direct_progress',url,nil,native.credentials),entry.book_id))
        end
        local before=snapshot()
        if not M.same_target(wanted,target(before)) then return {error='cloud_changed'} end
        local anchor,why=Position.prepare_target(client,settings,entry,file,native,web,active,wanted.chapter_offset)
        if not anchor then return {error=why or 'target_unavailable'} end
        local after=snapshot()
        if not same(before,after) or not M.same_target(wanted,target(after)) or not active() then return {error='cloud_changed'} end
        return {anchor=anchor,target=wanted}
    end)
    auth:cancel()
    if not ok then
        if not active() then return nil,'session_changed' end
        if value=='native_auth/direct_progress/http_401' then return nil,'auth_expired' end
        if value=='native_auth/direct_progress/http_429' then return nil,'rate_limited' end
        return nil,'unavailable'
    end
    if value.error then return nil,value.error end
    return value
end
return M
