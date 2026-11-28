-- Readback contract for one E-Ink start-status change. No network or writes.
-- Both ordinary and CB_ books have independently observed mark/restore trials.
local State=require('weread.lib.reading_state')
local Shelf=require('weread.lib.shelf_flag_change_contract')
local Base=require('weread.lib.finish_change_contract')
local Remote=require('weread.lib.remote_progress')
local Hash=require('weread.lib.thought_edit_contract')
local M={id=State.id}
local function fail(reason) error('reading_state_change/'..reason,0) end
local function integer(value)
    return type(value)=='number' and value==value and value>=0 and value<=9007199254740991 and value%1==0
end

function M.request(id,desired)
    if not M.id(id) or type(desired)~='boolean' then fail('target') end
    return {auto=0,bookId=id,finishInfo=0,isCancel=desired and 0 or 1,status=2}
end

function M.shelf_hash(source,id)
    if type(source)~='table' or type(source.archive)~='table' then fail('shelf') end
    local rows=Base.flags(source)
    if not rows[id] then fail('membership') end
    for _,row in pairs(rows) do
        for _,flag in pairs(row) do if flag.reason=='invalid' then fail('shelf') end end
    end
    return Shelf.state_hash(source)
end

function M.position_hash(raw,id)
    local value,reason,provided=Remote.project(raw,id,'native')
    if reason or not value or not provided or not provided.chapter_uid or not provided.chapter_offset then fail('position') end
    local uid=value.chapter_uid
    if type(uid)=='number' then
        if not integer(uid) then fail('position') end
        uid=string.format('%.0f',uid)
    end
    if type(uid)~='string' or #uid>20 or not uid:match('^%d+$') or (#uid>1 and uid:sub(1,1)=='0') then fail('position') end
    if uid=='0' and (value.chapter_idx~=0 or value.chapter_offset~=0 or value.raw_percent~=0 or value.summary~='') then
        fail('position')
    end
    local book=type(raw)=='table' and raw.book
    if type(book)~='table' then fail('position') end
    for _,key in ipairs({'readingTime','recordReadingTime','ttsTime'}) do if not integer(book[key]) then fail('counters') end end
    return Hash.digest({'reading-state-position-v1',uid,
        provided.chapter_idx and '1' or '0',value.chapter_idx,
        provided.chapter_offset and '1' or '0',value.chapter_offset,
        string.format('%.17g',value.raw_percent),provided.summary and '1' or '0',value.summary,
        book.readingTime,book.recordReadingTime,book.ttsTime})
end

local function start(raw,id,owner)
    local value,reason=State.project(raw,id,owner)
    if reason or type(value)~='boolean' then fail('status') end
    local stamp=raw.book.startReadingTime
    if not integer(stamp) or (value and stamp==0) or (not value and stamp~=0) then fail('status') end
    return value,Hash.digest({'reading-state-start-v1',stamp})
end

function M.make(source,raw,id,owner,desired)
    local body=M.request(id,desired)
    local before,start_hash=start(raw,id,owner)
    return {metadata={book_id=id,before=before,desired=desired,shelf_hash=M.shelf_hash(source,id),
        position_hash=M.position_hash(raw,id),start_hash=start_hash,request_hash=Hash.body_hash(body)},body=body}
end

function M.valid_metadata(value)
    if type(value)~='table' or not M.id(value.book_id) or type(value.before)~='boolean' or type(value.desired)~='boolean' then return false end
    local allowed={book_id=true,before=true,desired=true,shelf_hash=true,position_hash=true,start_hash=true,request_hash=true}
    for key in pairs(value) do if not allowed[key] then return false end end
    for _,key in ipairs({'shelf_hash','position_hash','start_hash','request_hash'}) do if not Hash.hash(value[key]) then return false end end
    return value.request_hash==Hash.body_hash(M.request(value.book_id,value.desired))
end

local function check(source,raw,metadata,owner,desired)
    if not M.valid_metadata(metadata) then fail('metadata') end
    local current,start_hash=start(raw,metadata.book_id,owner)
    if current==metadata.before and start_hash~=metadata.start_hash then return false end
    return current==desired and M.shelf_hash(source,metadata.book_id)==metadata.shelf_hash
        and M.position_hash(raw,metadata.book_id)==metadata.position_hash
end
function M.check(source,raw,metadata,owner) return check(source,raw,metadata,owner,metadata.desired) end
function M.unchanged(source,raw,metadata,owner) return check(source,raw,metadata,owner,metadata.before) end
function M.same(left,right)
    if not M.valid_metadata(left) or not M.valid_metadata(right) then return false end
    for key,value in pairs(left) do if right[key]~=value then return false end end
    return true
end
return M
