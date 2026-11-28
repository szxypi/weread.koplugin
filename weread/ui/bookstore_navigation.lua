local UIManager = require('ui/uimanager')
local ShelfSnapshot = require('weread.lib.shelf_snapshot')
local M = {}
local MAX_PARENTS = 4

function M.position(view)
    local anchor = (view.page - 1) * view.page_size + 1
    return { anchor = anchor, book_id = view.books and ShelfSnapshot.persisted_id(view.books[anchor]),
        focus = view.getFocusedBookId and view:getFocusedBookId() }
end

local function history(host, state)
    local trail = host._bookstore_history
    if state and trail and trail.state == state and state.account == host.library_db:accountKey() then
        return trail.parents
    end
end

local function return_target(host, state, prior, origin)
    if not origin or host.shelf_view ~= origin or origin._shelf_closed then return nil end
    if prior and prior.account ~= state.account then prior = nil end
    if prior and origin._bookstore_state == prior then
        prior._browse_position = M.position(origin)
        return { state = prior }
    elseif origin._discovery_tab == 'home' and origin._browse_account == state.account then
        local position = M.position(origin)
        position.account = state.account
        position.book_id = state.book_id or position.book_id
        return { state = prior, home = position }
    elseif origin._shelf_return_position then
        local position = origin._shelf_return_position()
        if position and position.account == state.account then
            return { state = prior, shelf = position }
        end
    end
end

function M.show(host, state, origin, continuation, batch_direction)
    local prior = host.discovery_state
    local parents = history(host, prior)
    local target = return_target(host, state, prior, origin)
    if target then
        parents = parents or {}
        parents[#parents + 1] = target
        if #parents > MAX_PARENTS then table.remove(parents, 1) end
    elseif not continuation or continuation ~= prior then
        parents = nil
    end
    host._bookstore_history = parents and { state = state, parents = parents } or nil
    host.discovery_state = state
    if host._book_detail_view then
        local detail = host._book_detail_view
        host._book_detail_view = nil
        UIManager:close(detail)
    end
    host:showBookstore(batch_direction)
end

function M.back(host, state)
    local parents = history(host, state)
    if not parents or host.discovery_state ~= state then return false end
    host:cancelDiscoveryRequest()
    local target = table.remove(parents)
    local prior = target.state
    -- Saving the related list can replace the persisted bookstore position.
    if prior then prior._browse_saved = nil end
    host._bookstore_history = prior and #parents > 0 and { state = prior, parents = parents } or nil
    host.discovery_state = prior
    if target.home then
        host._home_browse_position = target.home
        host:showHome()
    elseif target.shelf then
        host:showBookshelf(false, target.shelf)
    else
        host:showBookstore()
    end
    return true
end

return M
