-- Resolve the selected cached reader thought in a worker before opening replies.
local Source = require('weread.lib.native_book_reviews_source')
local Target = require('weread.lib.thought_reply_target')
local UI = require('ui/uimanager')
local _ = require('weread.lib.plugin_util').tr
local M = {}
function M.cancel(host)
    local owner = host._thought_reply_owner
    host._thought_reply_owner = nil
    if not owner then return end
    owner.closed = true
    if owner.worker then owner.worker:cancel() end
    local replies = package.loaded['weread.ui.native_review_replies']
    if replies and host._native_review_replies_owner and host._native_review_replies_owner.parent == owner.parent then
        replies.cancel(host)
    end
    if owner.busy and host.busy_message == owner.busy then host:closeBusy() end
end
function M.cancelForPopup(host, popup)
    local owner = host._thought_reply_owner
    if owner and owner.popup == popup then M.cancel(host) end
end
function M.open(host, info, shown, item, popup)
    M.cancel(host)
    if type(info) ~= 'table' or type(shown) ~= 'table' or type(popup) ~= 'table' then return false end
    local index
    for i, value in ipairs(shown) do if value == item then index = i; break end end
    if not index or not UI:isWidgetShown(popup) or popup.items ~= shown then return false end
    local snapshot = {}
    for i, value in ipairs(shown) do
        if type(value) ~= 'table' then return false end
        snapshot[i] = {item = value, abstract = value.abstract, author = value.author,
            content = value.content, likes_count = value.likes_count}
    end
    local function unchanged()
        if #shown ~= #snapshot then return false end
        for i, saved in ipairs(snapshot) do
            local value = shown[i]
            if value ~= saved.item or value.abstract ~= saved.abstract or value.author ~= saved.author
                or value.content ~= saved.content or value.likes_count ~= saved.likes_count then return false end
        end
        return true
    end
    local selected = Source.capture(host.settings)
    if not selected or not selected.native then
        if host.native_authorization then host.native_authorization:showMenu()
        else host:showInfo(_('Thought replies need E-Ink authorization.')) end
        return false
    end
    local document = host.ui and host.ui.document
    local account = host.library_db and host.library_db:accountKey()
    if not document or not account then return false end
    local context = host._annotation_context
    local store = context and context.store or require('weread.lib.annotation_store'):new(host.settings)
    local owner = {popup = popup, document = document, account = account, context = context,
        session = host._reader_session_gen, epoch = host.discovery_epoch or 0, selected = selected}
    host._thought_reply_owner = owner
    local function current_view()
        return host._thought_reply_owner == owner and not owner.closed and host.ui and host.ui.document == document
            and host._reader_session_gen == owner.session and (host.discovery_epoch or 0) == owner.epoch
            and host.library_db and host.library_db:accountKey() == account and host._annotation_context == context
            and UI:isWidgetShown(popup) and popup.items == shown and unchanged()
    end
    local function current()
        return current_view() and Source.matches(host.settings, owner.parent and owner.parent.selected or selected)
    end
    local function finish()
        if owner.busy and host.busy_message == owner.busy then host:closeBusy() end
        owner.busy = nil
    end
    host:showBusy(_('Checking the saved thought...'), function() M.cancel(host) end)
    owner.busy = host.busy_message
    local function complete(value)
        if not current() then if host._thought_reply_owner == owner then M.cancel(host) end return end
        finish()
        if type(value) ~= 'table' or type(value.review_id) ~= 'string' then
            M.cancel(host); host:showInfo(_('Could not match this thought. Refresh the chapter and try again.')); return
        end
        local parent = {selected = selected, detail = popup}
        owner.parent = parent
        local opened = require('weread.ui.native_review_replies').open(host, parent,
            {book_id = info.book_id, title = info.book_title}, {review_id = value.review_id}, popup,
            current_view, {review_type = 1})
        if not opened then M.cancel(host); host:showInfo(_('Could not open thought replies.')) end
    end
    local scheduled = host:runOnlineTask(_('Thought replies'), function()
        if not current() then if host._thought_reply_owner == owner then M.cancel(host) end return end
        local ok, worker = pcall(function()
            return require('weread.lib.memory_worker'):new{scheduler = UI, codec = host.client, max_bytes = 65536}
        end)
        if not ok or not worker then complete(nil); return end
        owner.worker = worker
        local started_ok, started = pcall(worker.start, worker, function()
            local valid, value = pcall(function()
                local source = store:get(info.book_id, 'source', info.chapter_uid)
                return Target.resolve(source, info.book_id, info.chapter_uid, info.range, shown, index)
            end)
            return valid and {review_id = value} or {error = 'unavailable'}
        end, complete)
        if not started_ok or not started then complete(nil) end
    end)
    if scheduled == false and host._thought_reply_owner == owner then M.cancel(host) end
    return scheduled ~= false
end
return M
