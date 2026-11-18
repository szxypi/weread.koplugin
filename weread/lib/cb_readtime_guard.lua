-- Pure, ephemeral preflight for imported-book time-only payload construction.
-- This does not grant dispatch, establish source ownership, or verify a transfer.
local Access=require('weread.lib.read_access')
local Point=require('weread.lib.readtime_point')
local Position=require('weread.lib.native_position_protocol')
local Contract=require('weread.lib.readtime_transfer_contract')
local M={}
function M.observe(native,web,book)
    if type(book)~='string' or Access.display_book_id(book)~=book or book:sub(1,3)~='CB_' then return nil end
    local ok,result=pcall(function()
        local a,b=Point.project(native,book,'native'),Point.project(web,book,'web')
        for _i,key in ipairs({'chapter_uid','chapter_idx','chapter_offset','raw_percent'}) do
            assert(a[key]==b[key],'cb_readtime/position')
        end
        assert(a.summary.present and b.summary.present and Position.summary(a.summary.value)
            and a.summary.value==b.summary.value,'cb_readtime/summary')
        return {summary=a.summary.value,native_hash=Contract.digest(a),web_hash=Contract.digest(b)}
    end)
    if ok then return result end
end
return M
