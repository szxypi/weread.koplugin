local ShelfSnapshot = require('weread.lib.shelf_snapshot')
local M = { KEY = 'home_browse_v1' }

function M.normalize(value)
    local anchor = type(value) == 'table' and value.anchor
    if type(anchor) ~= 'number' or anchor < 1 or anchor > ShelfSnapshot.MAX_BOOKS or anchor % 1 ~= 0 then
        return nil
    end
    return {
        anchor = anchor,
        book_id = ShelfSnapshot.persisted_identity(value.book_id),
        focus = ShelfSnapshot.persisted_identity(value.focus),
    }
end

function M.same(a, b)
    return a and b and a.anchor == b.anchor and a.book_id == b.book_id and a.focus == b.focus
end

return M
