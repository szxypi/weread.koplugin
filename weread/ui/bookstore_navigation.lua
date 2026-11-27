local UIManager = require('ui/uimanager')
local M = {}
local MAX_PARENTS = 4

function M.position(view)
    return { anchor = (view.page - 1) * view.page_size + 1, focus = view:getFocusedBookId() }
end

local function history(host, state)
    local trail = host._bookstore_history
    if state and trail and trail.state == state and state.account == host.library_db:accountKey() then
        return trail.parents
    end
end

function M.show(host, state, origin, continuation)
    local prior = host.discovery_state
    local parents = history(host, prior)
    if prior and origin and host.shelf_view == origin and not origin._shelf_closed
        and origin._bookstore_state == prior and prior.account == state.account then
        prior._browse_position = M.position(origin)
        parents = parents or {}
        parents[#parents + 1] = prior
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
    host:showBookstore()
end

function M.back(host, state)
    local parents = history(host, state)
    if not parents or host.discovery_state ~= state then return false end
    host:cancelDiscoveryRequest()
    local prior = table.remove(parents)
    -- Saving the related list can replace the persisted bookstore position.
    prior._browse_saved = nil
    host._bookstore_history = #parents > 0 and { state = prior, parents = parents } or nil
    host.discovery_state = prior
    host:showBookstore()
    return true
end

return M
