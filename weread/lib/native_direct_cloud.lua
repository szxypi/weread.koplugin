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
        if not same_chapter then return {position=point,relation='other_chapter'} end
        if cloud.chapter_offset==point.chapter_offset then return {position=point,relation='same'} end
        if not anchor then return {position=point,relation='target_unavailable'} end
        return {position=point,relation='different',anchor=anchor,cloud_offset=cloud.chapter_offset}
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
