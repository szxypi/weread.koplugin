-- Tencent's shelf contract assigns reading completion to finishReading.
-- `finished` is independent metadata; missing/invalid values stay unknown.
local M={FIELDS={pinned='isTop',private='secret',finished='finishReading'}}
function M.flag(row,key)
    local value;if type(row)=='table' then value=row[key] end
    if value==nil then return {reason='missing'} end
    if value==true or value==1 then return {value=true} end
    if value==false or value==0 then return {value=false} end
    return {reason='invalid'}
end
function M.project(row)
    return {pinned=M.flag(row,'isTop'),private=M.flag(row,'secret'),finished=M.flag(row,'finishReading')}
end
-- Older local snapshots used exact "0"/"1" strings. Retain display support;
-- new protocol projections above do not coerce arbitrary strings or metadata.
function M.display(row,name)
    local key=M.FIELDS[name]
    if not key then return nil end
    local value;if type(row)=='table' then value=row[key] end
    if value=='0' then return false end
    if value=='1' then return true end
    return M.flag(row,key).value
end
-- Stable display partition. Never edit the cloud snapshot or guess missing
-- flags from folder membership, reading time or the server's row position.
function M.pinned_first(books)
    local pinned,rest={},{}
    for _,book in ipairs(books or {}) do
        local target=M.display(book,'pinned')==true and pinned or rest
        target[#target+1]=book
    end
    if #pinned==0 then return books end
    for _,book in ipairs(rest) do pinned[#pinned+1]=book end
    return pinned
end
return M
