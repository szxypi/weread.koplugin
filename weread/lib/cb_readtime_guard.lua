-- Pure, ephemeral preflight for imported-book time-only payload construction.
-- This does not grant dispatch, establish source ownership, or verify a transfer.
local Access=require('weread.lib.read_access')
local Point=require('weread.lib.readtime_point')
local M={}
function M.observe(native,web,book)
    if type(book)~='string' or Access.display_book_id(book)~=book or book:sub(1,3)~='CB_' then return nil end
    return Point.shared_summary(native,web,book)
end
return M
