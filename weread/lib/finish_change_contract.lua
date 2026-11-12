-- Single-operation completion planning. Python first checked actual snapshots
-- in both directions. Pure model: no HTTP, ACK inference or write authority.
local Flags=require('weread.lib.shelf_flags')
local Hash=require('weread.lib.thought_edit_contract')
local Remote=require('weread.lib.remote_progress')
local M={}
local function fail(reason) error('finish_change/'..reason,0) end
function M.id(value) return type(value)=='string' and #value<=20 and value:match('^[1-9]%d*$')~=nil end
local function array(value)
    if type(value)~='table' then return false end
    for key in pairs(value) do if type(key)~='number' or key%1~=0 or key<1 or key>#value then return false end end
    return true
end
function M.flags(source)
    if type(source)~='table' or not array(source.books) or #source.books>5000 then fail('shelf') end
    for _i,key in ipairs({'errcode','errCode'}) do if source[key]~=nil and source[key]~=0 then fail('shelf') end end
    if source.succ~=nil and source.succ~=true and source.succ~=1 then fail('shelf') end
    local result={}
    for _i,row in ipairs(source.books) do
        local id=type(row)=='table' and row.bookId
        if type(id)=='number' and id>=1 and id%1==0 and id<=9007199254740991 then id=string.format('%.0f',id) end
        if type(id)~='string' or #id>128 or not id:match('^[A-Za-z0-9][A-Za-z0-9_-]*$') or result[id] then fail('shelf') end
        result[id]=Flags.project(row)
    end
    return result
end
function M.flags_hash(value)
    local keys={};for id in pairs(value) do keys[#keys+1]=id end;table.sort(keys)
    local parts={'finish-flags-v1',#keys}
    for _i,id in ipairs(keys) do
        parts[#parts+1]=id
        for _j,name in ipairs({'pinned','private','finished'}) do
            local flag=value[id][name]
            parts[#parts+1]=flag.value==true and '1' or flag.value==false and '0' or flag.reason=='missing' and 'm' or 'i'
        end
    end
    return Hash.digest(parts)
end
function M.point(progress,id)
    local value,reason=Remote.project(progress,id,'native')
    if reason or not value or not value.has_chapter_offset or value.chapter_uid==nil then fail('position') end
    local uid=tostring(value.chapter_uid);if not M.id(uid) then fail('position') end
    return {chapter_uid=uid,chapter_idx=value.chapter_idx,chapter_offset=value.chapter_offset,percent=value.raw_percent}
end
function M.position_hash(value)
    return Hash.digest({'finish-position-v1',value.chapter_uid,value.chapter_idx,value.chapter_offset,string.format('%.17g',value.percent)})
end
function M.request(id,desired)
    if not M.id(id) or type(desired)~='boolean' then fail('target') end
    return {bookId=id,auto=0,finishInfo=0,isCancel=desired and 0 or 1,status=4}
end
function M.make(source,progress,id,desired)
    local body=M.request(id,desired);local snapshot=M.flags(source);local row=snapshot[id]
    local before=row and row.finished.value
    if type(before)~='boolean' then fail('unknown') end
    for _i,flags in pairs(snapshot) do for _j,flag in pairs(flags) do if flag.reason=='invalid' then fail('invalid_flag') end end end
    local point=M.point(progress,id)
    local before_hash=M.flags_hash(snapshot)
    row.finished={value=desired}
    return {metadata={book_id=id,before=before,desired=desired,before_hash=before_hash,after_hash=M.flags_hash(snapshot),
        position_hash=M.position_hash(point),request_hash=Hash.body_hash(body)},body=body}
end
function M.check(source,progress,metadata)
    if not M.valid_metadata(metadata) then fail('metadata') end
    return M.flags_hash(M.flags(source))==metadata.after_hash and M.position_hash(M.point(progress,metadata.book_id))==metadata.position_hash
end
function M.valid_metadata(value)
    if type(value)~='table' or not M.id(value.book_id) or type(value.before)~='boolean' or type(value.desired)~='boolean' then return false end
    local fields={book_id=true,before=true,desired=true,before_hash=true,after_hash=true,position_hash=true,request_hash=true}
    for key in pairs(value) do if not fields[key] then return false end end
    for _i,key in ipairs({'before_hash','after_hash','position_hash','request_hash'}) do if not Hash.hash(value[key]) then return false end end
    return value.request_hash==Hash.body_hash(M.request(value.book_id,value.desired))
end
function M.same(left,right)
    if not M.valid_metadata(left) or not M.valid_metadata(right) then return false end
    for key,value in pairs(left) do if right[key]~=value then return false end end
    return true
end
return M
