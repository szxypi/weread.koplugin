-- Read-only preparation for a native chapter upload. The result is not a
-- dispatch grant; the UI must recheck it before using the position service.
local Access=require('weread.lib.native_read_access')
local Currentness=require('weread.lib.source_currentness')
local Auth=require('weread.lib.native_authorization')
local Position=require('weread.lib.native_direct_position')
local State=require('weread.lib.native_cloud_state')
local P=require('weread.lib.native_position_protocol')
local Remote=require('weread.lib.remote_progress')
local Shelf=require('weread.lib.shelf_flag_change_contract')
local Protocol=require('weread.lib.protocol')
local M={}

local function web_matches(raw,before)
    if State.none(before) then
        local empty=State.from(raw,before.book_id)
        return empty~=nil
    end
    local p,why,provided=Remote.project(raw,before.book_id,'web')
    local node=Remote.node(raw,before.book_id)
    local summary_matches=node and (State.missing_summary(before) and node.summary==nil and node.chapterTitle==nil
        or not State.missing_summary(before) and node.summary==before.summary)
    return summary_matches and not why and p~=nil and provided.chapter_uid and provided.chapter_idx and provided.chapter_offset
        and tostring(p.chapter_uid)==before.chapter_uid and p.chapter_idx==before.chapter_idx
        and p.chapter_offset==before.chapter_offset and p.raw_percent==before.raw_percent
end

function M.prepare(client,settings,entry,file,context,native,web,current)
    local function active()
        local ok,value=pcall(current)
        return ok and value==true and Access.matches(settings,native) and Currentness.matches(settings,web)
    end
    if type(current)~='function' or type(entry)~='table' or P.id(entry.book_id)~=entry.book_id
        or type(native)~='table' or type(native.scope)~='table' or type(native.credentials)~='table'
        or native.scope.vid~=native.credentials.vid or not active() then return nil,'invalid' end
    local auth=Auth:new(client,{expected_vid=native.scope.vid,is_current=active})
    local ok,result=pcall(function()
        local base='https://i.weread.qq.com'
        local encoded=Protocol.urlencode(entry.book_id)
        local function snapshot()
            return State.snapshot(auth:_request('position_progress',base..'/book/getProgress?bookId='..encoded,nil,native.credentials),entry.book_id,
                {allow_missing_summary=true})
        end
        local info=auth:_request('position_metadata',base..'/book/info?bookId='..encoded,nil,native.credentials)
        if P.id(info.bookId)~=entry.book_id then return {error='source_changed'} end
        local version
        for _,key in ipairs({'bookVersion','version'}) do if info[key]~=nil then
            if not P.integer(info[key],0,2147483647) or version~=nil and version~=info[key] then return {error='source_changed'} end
            version=info[key]
        end end
        if version~=entry.book_version then return {error='source_changed'} end
        local before=snapshot()
        if State.none(before.position) and not State.initial_counts(before.counts) then return {error='baseline_unavailable'} end
        local shelf=Shelf.state_hash(auth:read_shelf(native.credentials))
        local progress_checks=0
        local position,why,_,summary=Position.prepare(client,settings,entry,file,context,native,web,active,nil,{
            prepare_summary=true,verify_progress=function(raw)
                progress_checks=progress_checks+1
                return web_matches(raw,before.position)
            end,
        })
        if not position then return {error=why or 'unavailable'} end
        if position.basis=='raw_txt_utf16' and (State.missing_summary(before.position)
            or State.none(before.position) and not State.zero(before.counts)) then return {error='baseline_unavailable'} end
        local after=snapshot()
        local shelf_after=Shelf.state_hash(auth:read_shelf(native.credentials))
        if progress_checks~=2 or not State.equal(before.position,after.position)
            or not P.same_counts(before.counts,after.counts) or shelf~=shelf_after or not active() then
            return {error='cloud_changed'}
        end
        local desired=P.point{book_id=entry.book_id,chapter_uid=entry.chapter_uid,chapter_idx=entry.chapter_idx,
            chapter_offset=position.chapter_offset,raw_percent=before.position.raw_percent,summary=summary}
        return {position=position,before=before.position,desired=desired,counts=before.counts,version=version,
            shelf_sha256=shelf,source_sha256=entry.source_sha256,file_id=entry.file_id,basis=position.basis,
            dispatch_authorized=false}
    end)
    auth:cancel()
    if not ok then
        if not active() then return nil,'session_changed' end
        if result=='native_auth/position_progress/http_401' or result=='native_auth/position_metadata/http_401'
            or result=='native_auth/shelf/http_401' then return nil,'auth_expired' end
        if result=='native_auth/position_progress/http_429' or result=='native_auth/position_metadata/http_429'
            or result=='native_auth/shelf/http_429' then return nil,'rate_limited' end
        if result=='native_position/response' or result=='native_position/point' then return nil,'baseline_unavailable' end
        return nil,'unavailable'
    end
    if result.error then return nil,result.error end
    return result
end
return M
