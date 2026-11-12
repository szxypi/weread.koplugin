-- Fresh cloud state is evidence of the current point, never an old POST ACK.
local P=require('weread.lib.native_position_protocol')
local Hash=require('weread.lib.thought_edit_contract')
local M={}
local function exact(value,fields)
    if type(value)~='table' then return false end
    local n=0;for key in pairs(value) do if not fields[key] then return false end;n=n+1 end
    local size=0;for _key in pairs(fields) do size=size+1 end;return n==size
end
function M.valid(value)
    if not exact(value,{point=true,counts=true,version=true,shelf_sha256=true})
        or not exact(value.point,{book_id=true,chapter_uid=true,chapter_idx=true,chapter_offset=true,raw_percent=true,summary=true})
        or not exact(value.counts,{readingTime=true,recordReadingTime=true,ttsTime=true})
        or not P.integer(value.version,0,2147483647) or not Hash.hash(value.shelf_sha256) then return false end
    return pcall(function() P.point(value.point);P.counts(value.counts) end)
end
function M.hash(value)
    assert(M.valid(value),'native_position/observation')
    return Hash.digest({'native-position-observation-v1',P.point_hash(value.point),value.version,value.shelf_sha256,
        value.counts.readingTime,value.counts.recordReadingTime,value.counts.ttsTime})
end
function M.same(a,b) return M.valid(a) and M.valid(b) and M.hash(a)==M.hash(b) end
return M
