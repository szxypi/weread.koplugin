-- Owner-bound Skill review list. HTTPS and response projection stay in a worker.
local Source = require('weread.lib.gateway_book_reviews_source')
local UI = require('ui/uimanager')
local _ = require('weread.lib.plugin_util').tr
local M = {}

local function stop(host, owner)
    local context = owner.context; owner.context = nil
    if not context then return end
    if owner.worker then owner.worker:cancel() end
    if context.busy and host.busy_message == context.busy then host:closeBusy() end
end
function M.cancel(host)
    local owner = host._gateway_reviews_owner
    host._gateway_reviews_owner = nil
    if not owner then return end
    owner.closed = true
    local replies = package.loaded['weread.ui.native_review_replies']
    if replies and host._native_review_replies_owner and host._native_review_replies_owner.parent == owner then
        replies.cancel(host)
    end
    stop(host, owner)
    local detail = owner.detail; owner.detail = nil
    if detail then UI:close(detail) end
    local view = owner.view; owner.view = nil
    if view then UI:close(view) end
end

function M.open(host, book, selected)
    M.cancel(host)
    local id = book.book_id or book.bookId
    if type(id) == 'number' and id >= 1 and id <= 9007199254740991 and id % 1 == 0 then id = string.format('%.0f', id) end
    if type(id) ~= 'string' or id == '' or #id > 256 or id:find('[%z%c]') or not selected or not selected.api_key then return false end
    local owner = {account = host.library_db:accountKey(), parent = host._book_detail_view,
        epoch = host.discovery_epoch or 0, session = host._reader_session_gen,
        document = host.ui and host.ui.document, selected = selected, cache = {}}
    if (not owner.account and not selected.key_only) or not owner.parent then return false end
    host._gateway_reviews_owner = owner
    local function current_view()
        return host._gateway_reviews_owner == owner and not owner.closed
            and host.library_db:accountKey() == owner.account and host._book_detail_view == owner.parent
            and (host.discovery_epoch or 0) == owner.epoch and host._reader_session_gen == owner.session
            and (host.ui and host.ui.document) == owner.document
    end
    local function current() return current_view() and Source.matches(host.settings, owner.selected) end
    local load
    local function render(mode, result, old_view, more)
        local offset, focus_row
        if old_view and more then
            local scroll = old_view._review_scroll
            if scroll and scroll.getScrolledOffset then offset = scroll:getScrolledOffset() end
            focus_row = #old_view.result.items + 2
        end
        if old_view then owner.replacing = true; UI:close(old_view); owner.replacing = false end
        local view
        view = require('weread.ui.book_reviews_view').show({book_title = book.title, mode = mode,
            result = result, scroll_offset = offset, focus_row = focus_row}, {
            on_switch = function(next_mode) if current_view() and not owner.detail then load(next_mode, view, false) end end,
            on_select = function(review, selected_mode)
                if not current_view() or owner.context or owner.detail then return end
                local can_reply = (owner.selected.native or owner.account) and require('weread.lib.native_book_reviews').book_id(id)
                    and require('weread.lib.native_review_replies').review_id(review.review_id)
                local detail
                detail = host:showBookReviewDetail(book, review, selected_mode, {
                    on_replies = can_reply and function()
                        if current_view() and owner.detail == detail then
                            require('weread.ui.native_review_replies').open(host, owner, book, review, detail, current_view)
                        end
                    end or nil,
                    on_close = function()
                        if owner.detail == detail then
                            local replies = package.loaded['weread.ui.native_review_replies']
                            if replies and host._native_review_replies_owner and host._native_review_replies_owner.parent == owner then
                                replies.cancel(host)
                            end
                            owner.detail = nil
                        end
                    end,
                })
                owner.detail = detail
            end,
            on_load_more = function() if current_view() and not owner.detail then load(mode, view, true) end end,
            on_close = function()
                if not owner.replacing and host._gateway_reviews_owner == owner then M.cancel(host) end
            end,
        })
        owner.view = view
    end
    load = function(mode, old_view, more)
        if not current() then
            if host._gateway_reviews_owner == owner then M.cancel(host) end
            return
        end
        if owner.context or old_view and old_view ~= owner.view then return end
        local previous = more and owner.cache[mode] or nil
        if more and (not previous or not previous.has_more) then return end
        if not more and owner.cache[mode] then render(mode, owner.cache[mode], old_view, false); return end
        local context = {}; owner.context = context
        local function failed()
            if owner.context ~= context then return end
            stop(host, owner)
            host:showInfo(_('Could not load book reviews. Please try again.'))
            if not owner.view then M.cancel(host) end
        end
        host:showBusy(_('Loading book reviews...'), function()
            if host._gateway_reviews_owner == owner then
                stop(host, owner)
                if not owner.view then M.cancel(host) end
            end
        end)
        context.busy = host.busy_message
        local function complete(value)
            if owner.context ~= context then return end
            if not current() then if host._gateway_reviews_owner == owner then M.cancel(host) end return end
            if type(value) ~= 'table' or value.ok ~= true or type(value.page) ~= 'table' then failed(); return end
            stop(host, owner); owner.cache[mode] = value.page
            render(mode, value.page, old_view, more)
        end
        local scheduled = host:runOnlineTask(_('Book reviews'), function()
            if not current() then if host._gateway_reviews_owner == owner then M.cancel(host) end return end
            local ok, worker = pcall(function()
                return owner.worker or require('weread.lib.memory_worker'):new{scheduler = UI, codec = host.client,
                    max_bytes = 4 * 1024 * 1024}
            end)
            if not ok or not worker then failed(); return end
            owner.worker = worker
            local started_ok, started = pcall(worker.start, worker, function()
                local valid, page = pcall(Source.fetch, host.client, id, mode, previous, owner.selected)
                return valid and {ok = true, page = page} or {ok = false}
            end, complete)
            if not started_ok or not started then failed() end
        end)
        if scheduled == false and owner.context == context then
            stop(host, owner)
            if not owner.view then M.cancel(host) end
        end
    end
    load('recommended')
    return true
end
return M
