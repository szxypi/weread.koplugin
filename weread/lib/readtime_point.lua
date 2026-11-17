-- Time-only observation preserves optional-field presence. It cannot construct
-- a position upload or fill a missing summary with a guessed/empty value.
local C=require('weread.lib.readtime_transfer_contract')
local P=require('weread.lib.native_position_protocol')
local Remote=require('weread.lib.remote_progress')
local M={CONTRACT='historical-time-point-presence-v1'}
local function optional(node,key)
    local value=node[key]
    if value==nil then return {present=false} end
    assert(type(value)=='string' and #value<=16384 and not value:find('%z'),'readtime_point/text')
    return {present=true,value=value}
end
function M.project(raw,book,kind)
    assert(kind=='native' or kind=='web','readtime_point/kind')
    local point,reason,provided=Remote.project(raw,book,kind);local node=Remote.node(raw,book)
    assert(not reason and point and node and provided.chapter_uid and provided.chapter_idx and provided.chapter_offset
        and P.id(point.chapter_uid),'readtime_point/position')
    return {contract=M.CONTRACT,book_id=book,chapter_uid=P.id(point.chapter_uid),chapter_idx=point.chapter_idx,
        chapter_offset=point.chapter_offset,raw_percent=point.raw_percent,
        summary=optional(node,'summary'),chapter_title=optional(node,'chapterTitle')}
end
function M.hash(raw,book,kind) return C.digest(M.project(raw,book,kind)) end
return M
