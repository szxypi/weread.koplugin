-- Native, owner-bound read-only replies to a book review.
local Source = require('weread.lib.native_book_reviews_source')
local Data = require('weread.lib.native_review_replies')
local Recovery = require('weread.lib.native_read_recovery')
local Reviews = require('weread.lib.book_reviews')
local UI = require('ui/uimanager')
local TextViewer = require('ui/widget/textviewer')
local _ = require('weread.lib.plugin_util').tr
local M = {}

function M.cancel(host)
    local owner = host._native_review_replies_owner
    host._native_review_replies_owner = nil
    if not owner then return end
    owner.closed = true
    if owner.worker then owner.worker:cancel() end
    if owner.context then Recovery.cancel(host, owner.context) end
    if owner.busy and host.busy_message == owner.busy then host:closeBusy() end
    local viewer = owner.viewer; owner.viewer = nil
    if viewer then UI:close(viewer) end
    local view = owner.view; owner.view = nil
    if view then UI:close(view) end
end

function M.open(host, parent, book, review, detail, parent_current, options)
    M.cancel(host)
    options = options or {}
    local review_type = options.review_type or 4
    local book_id, review_id = book.book_id or book.bookId, review.review_id
    if type(book_id) == 'number' and book_id >= 1 and book_id <= 9007199254740991 and book_id % 1 == 0 then
        book_id = string.format('%.0f', book_id)
    end
    if not require('weread.lib.native_book_reviews').book_id(book_id) or not Data.review_id(review_id)
        or review_type ~= 1 and review_type ~= 4
        or type(parent_current) ~= 'function' or not parent_current() or parent.detail ~= detail then return false end
    local owner = {parent = parent, detail = detail}
    host._native_review_replies_owner = owner
    local function current_view()
        return host._native_review_replies_owner == owner and not owner.closed and parent_current()
            and parent.detail == detail
    end
    local function current()
        return current_view() and (owner.context and owner.context.renewing
            and Recovery.current(host.settings, parent.selected, Source.capture)
            or Source.matches(host.settings, parent.selected))
    end
    local function finish()
        owner.context = nil
        if owner.busy and host.busy_message == owner.busy then host:closeBusy() end
        owner.busy = nil
    end
    local fetch
    local function render(page)
        local offset, focus_row
        if owner.view then
            local scroll = owner.view._review_scroll
            if scroll and scroll.getScrolledOffset then offset = scroll:getScrolledOffset() end
            focus_row = #owner.view.result.items + 2
            owner.replacing = true; UI:close(owner.view); owner.replacing = false
        end
        local view
        view = require('weread.ui.book_reviews_view').show({book_title = book.title,
            mode = 'latest', result = page, latest_only = true, scroll_offset = offset, focus_row = focus_row,
            title_text = review_type == 1 and 'Thought replies' or 'Review replies', tab_text = 'Replies', empty_text = 'No replies.',
            incomplete_text = 'Some replies may be unavailable.',
            limited_text = 'Reply limit reached; more replies may be available.'}, {
            on_select = function(item)
                if not current_view() or owner.context or owner.viewer then return end
                local author = item.author ~= '' and item.author or _('Anonymous')
                local date = Reviews.format_date(item.create_time)
                local lines = {author}
                if date ~= '' then lines[#lines + 1] = date end
                lines[#lines + 1] = ''; lines[#lines + 1] = item.content
                local viewer
                viewer = TextViewer:new{title = _('Reply'), text = table.concat(lines, '\n'),
                    text_type = 'general', auto_para_direction = true,
                    close_callback = function() if owner.viewer == viewer then owner.viewer = nil end end}
                owner.viewer = viewer; UI:show(viewer)
            end,
            on_load_more = function()
                if current_view() and not owner.context and not owner.viewer and page.has_more then
                    fetch(math.min(Data.MAX_ITEMS, page.limit + Data.PAGE_SIZE), page.ids)
                end
            end,
            on_close = function()
                if not owner.replacing and host._native_review_replies_owner == owner then M.cancel(host) end
            end,
        })
        owner.view = view
    end
    fetch = function(limit, previous)
        if not current_view() or owner.context then return end
        local context = {}; owner.context = context
        local function failed(changed)
            if owner.context ~= context then return end
            finish()
            host:showInfo(changed and _('Replies changed. Close and open them again.')
                or _('Could not load replies. Please try again.'))
            if not owner.view then M.cancel(host) end
        end
        host:showBusy(_('Loading replies...'), function() M.cancel(host) end)
        owner.busy = host.busy_message
        local launch
        local function complete(value)
            if owner.context ~= context then return end
            if not current() then if host._native_review_replies_owner == owner then M.cancel(host) end return end
            if type(value) == 'table' and value.native_expired then
                local recovering = Recovery.start(host, context, parent.selected, {
                    capture = Source.capture, is_current = current_view,
                    stale = function() if host._native_review_replies_owner == owner then M.cancel(host) end end,
                    complete = function(success, renewed)
                        parent.selected = renewed
                        if success then launch() else failed() end
                    end,
                })
                if recovering then return end
            end
            if type(value) ~= 'table' or value.ok ~= true or type(value.page) ~= 'table' then
                failed(type(value) == 'table' and value.changed); return
            end
            finish(); render(value.page)
        end
        local scheduled = host:runOnlineTask(_(review_type == 1 and 'Thought replies' or 'Review replies'), function()
            if not current() then if host._native_review_replies_owner == owner then M.cancel(host) end return end
            local ok, worker = pcall(function()
                return owner.worker or require('weread.lib.memory_worker'):new{scheduler = UI, codec = host.client,
                    max_bytes = 4 * 1024 * 1024}
            end)
            if not ok or not worker then failed(); return end
            owner.worker = worker
            launch = function()
                local started_ok, started = pcall(worker.start, worker, function()
                    local valid, result = pcall(Source.fetch_replies, host.client, book_id, review_id, limit,
                        previous, parent.selected, host.native_renewal ~= nil and not context.recovery_attempted, review_type)
                    return valid and {ok = true, page = result}
                        or {ok = false, native_expired = result == 'native_reviews/native_expired',
                            changed = result == 'review_replies/changed'}
                end, complete)
                if not started_ok or not started then failed() end
            end
            launch()
        end)
        if scheduled == false and host._native_review_replies_owner == owner then M.cancel(host) end
    end
    fetch(Data.PAGE_SIZE)
    return true
end
return M
