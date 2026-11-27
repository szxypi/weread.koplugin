-- Read-only channel for native cloud progress. A reported offset may be used
-- only when its explicit summary uniquely starts at that offset in the saved
-- source. This proof is independent of Web authorization and upload authority.
local Access=require('weread.lib.native_read_access')
local Auth=require('weread.lib.native_authorization')
local Cache=require('weread.lib.native_direct_cache')
local Coordinates=require('weread.lib.source_coordinates')
local Crypto=require('weread.lib.crypto')
local Dom=require('weread.lib.source_dom')
local P=require('weread.lib.native_position_protocol')
local Remote=require('weread.lib.remote_progress')
local M={}

function M.hint(raw,id)
    local point,_,provided=Remote.project(raw,id,'native')
    local uid=point and P.id(point.chapter_uid)
    if not uid then return end
    local chapter={uid=uid,idx=provided.chapter_idx and point.chapter_idx or nil}
    if not provided.chapter_offset or not P.integer(point.chapter_offset,1,Coordinates.MAX_BYTES*8)
        or not P.summary(point.summary) then return chapter end
    local node=Remote.node(raw,id)
    if not node or node.summary~=point.summary then return chapter end
    local quote=Dom.normalize(node.summary)
    if not quote then return chapter end
    local _,length=quote:gsub('[^\128-\191]','')
    if length<12 then return chapter end
    chapter.target={book_id=id,chapter_uid=uid,chapter_idx=chapter.idx,chapter_offset=point.chapter_offset,
        stamp=Crypto.sha256_hex('native-cloud-resume-v1\0'..quote)}
    return chapter,quote
end

function M.valid_target(wanted)
    return type(wanted)=='table' and type(wanted.book_id)=='string' and P.id(wanted.book_id)==wanted.book_id
        and type(wanted.chapter_uid)=='string' and P.id(wanted.chapter_uid)==wanted.chapter_uid
        and (wanted.chapter_idx==nil or P.integer(wanted.chapter_idx,0,1000000))
        and P.integer(wanted.chapter_offset,1,Coordinates.MAX_BYTES*8)
        and type(wanted.stamp)=='string' and #wanted.stamp==64 and wanted.stamp:match('^[a-f0-9]+$')~=nil
end

function M.same_target(left,right)
    return M.valid_target(left) and M.valid_target(right) and left.book_id==right.book_id
        and left.chapter_uid==right.chapter_uid and left.chapter_idx==right.chapter_idx
        and left.chapter_offset==right.chapter_offset and left.stamp==right.stamp
end

function M.matches_entry(entry,wanted)
    return type(entry)=='table' and entry.book_id==wanted.book_id and entry.chapter_uid==wanted.chapter_uid
        and (entry.chapter_idx==nil or wanted.chapter_idx==nil or entry.chapter_idx==wanted.chapter_idx)
end

local function verify_entry(settings,entry,file,native,current,wanted)
    local active=Access.guard(settings,current,native)
    if not active or not active() or not M.valid_target(wanted) or not M.matches_entry(entry,wanted) then
        return nil
    end
    local pinned=Cache.identify(settings,native.scope.vid,file,active)
    if not M.matches_entry(pinned,wanted) or pinned.file_id~=entry.file_id or pinned.book_version~=entry.book_version
        or pinned.source_sha256~=entry.source_sha256 or pinned.catalog_sha256~=entry.catalog_sha256 then
        return nil
    end
    return pinned,active
end

local function read_target(client,native,active,wanted)
    local auth=Auth:new(client,{expected_vid=native.scope.vid,is_current=active})
    local ok,progress=pcall(auth._request,auth,'direct_progress',
        'https://i.weread.qq.com/book/getProgress?bookId='..wanted.book_id,nil,native.credentials,{2,3})
    auth:cancel()
    if not ok then return nil,'unavailable' end
    local hint,quote=M.hint(progress,wanted.book_id)
    if not hint or not M.same_target(hint.target,wanted) then return nil,'cloud_changed' end
    return quote
end

function M.prepare_destination(client,settings,entry,file,native,current,wanted)
    local pinned,active=verify_entry(settings,entry,file,native,current,wanted)
    if not pinned then return nil,'unavailable' end
    local quote,reason=read_target(client,native,active,wanted)
    if not quote then return nil,reason end
    local raw=Cache.read_raw_source(file,pinned)
    local map=raw and Coordinates.build(raw,{format='web_xhtml',allow_multiple_bodies=true})
    if not map then return nil,'unavailable' end
    local point=map:locate_point(quote,0)
    if not point or point.co~=wanted.chapter_offset or not active() then return nil,'unavailable' end
    return {target=wanted,anchor={co=point.co,basis=point.basis,point_unit='unicode_scalars',text=quote,point_offset=0}}
end

-- The live reader has already matched the original quote. Recheck the pinned
-- EPUB and fresh cloud target immediately before following that same anchor.
function M.recheck_destination(client,settings,entry,file,native,current,wanted)
    local pinned,active=verify_entry(settings,entry,file,native,current,wanted)
    if not pinned then return nil,'unavailable' end
    local quote,reason=read_target(client,native,active,wanted)
    if not quote then return nil,reason end
    if not active() then return nil,'unavailable' end
    return {target=wanted}
end

return M
