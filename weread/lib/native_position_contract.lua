-- Source and complete point/counter bindings for a single native operation.
local P=require('weread.lib.native_position_protocol')
local Hash=require('weread.lib.thought_edit_contract')
local Crypto=require('weread.lib.crypto')
local State=require('weread.lib.native_cloud_state')
local M={}
function M.account_key(vid)
    return type(vid)=='string' and P.id(vid) and Crypto.sha256_hex('weread-library:'..vid):sub(1,20) or nil
end
local fields={book_id=true,before=true,desired=true,counts=true,version=true,shelf_sha256=true,source_sha256=true,file_id=true,basis=true}
local point_fields={book_id=true,chapter_uid=true,chapter_idx=true,chapter_offset=true,raw_percent=true,summary=true}
function M.valid(value)
    if type(value)~='table' or value.basis~='raw_txt_utf16' or type(value.file_id)~='string' or #value.file_id==0 or #value.file_id>256
        or value.file_id:find('[%z%c]') or not Hash.hash(value.shelf_sha256) or not Hash.hash(value.source_sha256)
        or not P.integer(value.version,0,2147483647) or type(value.book_id)~='string' or P.id(value.book_id)~=value.book_id then return false end
    local count=0;for key in pairs(value) do if not fields[key] then return false end;count=count+1 end;if count~=9 then return false end
    local ok=pcall(function()
        assert(State.valid(value.before) and value.before.book_id==value.book_id)
        assert(not State.none(value.before) or State.zero(value.counts))
        for _i,point in ipairs({value.desired}) do
            P.point(point);assert(point.book_id==value.book_id)
            local n=0;for key in pairs(point) do assert(point_fields[key]);n=n+1 end;assert(n==6)
        end
        P.counts(value.counts);local n=0;for key in pairs(value.counts) do assert(key=='readingTime' or key=='recordReadingTime' or key=='ttsTime');n=n+1 end;assert(n==3)
    end)
    return ok
end
function M.hash(value)
    assert(M.valid(value),'native_position/metadata')
    return Hash.digest({State.none(value.before) and 'native-position-initial-binding-v1' or 'native-position-binding-v1',value.book_id,value.basis,value.file_id,value.source_sha256,value.shelf_sha256,
        value.version,State.hash(value.before),P.point_hash(value.desired),value.counts.readingTime,value.counts.recordReadingTime,value.counts.ttsTime})
end
function M.same(first,second)
    return M.valid(first) and M.valid(second) and M.hash(first)==M.hash(second)
end
return M
