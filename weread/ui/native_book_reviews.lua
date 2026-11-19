-- Cancellable, owner-bound latest reviews displayed by KOReader widgets.
local Source = require('weread.lib.native_book_reviews_source')
local Data = require('weread.lib.native_book_reviews')
local Recovery = require('weread.lib.native_read_recovery')
local Cache = require('weread.lib.native_book_reviews_cache')
local UI = require('ui/uimanager')
local Util = require('weread.lib.plugin_util')
local _,T = Util.tr,Util.T
local M = {}

function M.cancel(host)
    local owner = host._native_reviews_owner
    host._native_reviews_owner = nil
    if not owner then return end
    owner.closed = true
    local replies = package.loaded['weread.ui.native_review_replies']
    if replies then replies.cancel(host) end
    if owner.worker then owner.worker:cancel() end
    if owner.context then Recovery.cancel(host, owner.context) end
    if owner.busy and host.busy_message == owner.busy then host:closeBusy() end
    local detail = owner.detail; owner.detail = nil
    if detail then UI:close(detail) end
    local view = owner.view; owner.view = nil
    if view then UI:close(view) end
end

function M.open(host, book, selected)
    local id = book.book_id or book.bookId
    if not Data.book_id(id) then
        host:showInfo(_('Book reviews are unavailable for this book.'))
        return false
    end
    M.cancel(host)
    local owner = { account = host.library_db:accountKey(), parent = host._book_detail_view,
        epoch = host.discovery_epoch or 0, session = host._reader_session_gen,
        document = host.ui and host.ui.document, selected = selected,
        auth_epoch = type(host.settings.get)=='function' and host.settings:get('auth_epoch',0) or nil,
        auth_scope = type(host.settings.get_auth_scope)=='function' and host.settings:get_auth_scope() or nil }
    if not owner.account or not owner.parent then
        if not owner.account then host:showInfo(_('Sign in to view saved book reviews.')) end
        return false
    end
    host._native_reviews_owner = owner
    local function current_view()
        return host._native_reviews_owner == owner and not owner.closed
            and host.library_db:accountKey() == owner.account and host._book_detail_view == owner.parent
            and (host.discovery_epoch or 0) == owner.epoch and host._reader_session_gen == owner.session
            and (host.ui and host.ui.document) == owner.document
            and (owner.auth_epoch==nil or host.settings:get('auth_epoch',0)==owner.auth_epoch)
            and (type(host.settings.get_auth_scope)~='function'
                or owner.auth_scope and host.settings:auth_scope_matches(owner.auth_scope)
                or not owner.auth_scope and not host.settings:get_auth_scope())
    end
    local function current()
        return current_view() and (owner.context and owner.context.renewing
            and Recovery.current(host.settings, owner.selected, Source.capture)
            or Source.matches(host.settings, owner.selected))
    end
    local function finish()
        owner.context = nil
        if owner.busy and host.busy_message == owner.busy then host:closeBusy() end
        owner.busy = nil
    end
    local fetch,show_cached
    local function render(page,from_cache)
        local saved_time
        if from_cache then
            local ok,value=pcall(os.date,'%Y-%m-%d %H:%M',page.saved_at)
            saved_time=ok and type(value)=='string' and value or _('Time unavailable')
        end
        local offset, focus_row
        if owner.view then
            local scroll = owner.view._review_scroll
            if scroll and scroll.getScrolledOffset then offset = scroll:getScrolledOffset() end
            focus_row = #owner.view.result.items + 2
            owner.replacing = true
            UI:close(owner.view)
            owner.replacing = false
        end
        local view
        view = require('weread.ui.book_reviews_view').show({ book_title = book.title,
            mode = 'latest', result = page, latest_only = true, scroll_offset = offset, focus_row = focus_row,
            tab_text = from_cache and 'Saved latest reviews' or nil,
            incomplete_text = from_cache and T(_('Saved %1; reviews may be incomplete.'),saved_time) or nil }, {
            on_select = function(review)
                if not current_view() or owner.context or owner.detail then return end
                local detail
                detail = host:showBookReviewDetail(book, review, 'latest', {
                    on_replies = function()
                        if current_view() and owner.detail == detail then
                            require('weread.ui.native_review_replies').open(host, owner, book, review, detail, current_view)
                        end
                    end,
                    on_close = function()
                        if owner.detail == detail then
                            local replies = package.loaded['weread.ui.native_review_replies']
                            if replies then replies.cancel(host) end
                            owner.detail = nil
                        end
                    end,
                })
                owner.detail = detail
            end,
            on_load_more = function()
                if current_view() and not owner.context and page.has_more then
                    fetch(math.min(Data.MAX_ITEMS, page.limit + Data.PAGE_SIZE), page.ids)
                end
            end,
            on_close = function()
                if not owner.replacing and host._native_reviews_owner == owner then M.cancel(host) end
            end,
        })
        owner.view = view
    end
    show_cached = function(message)
        if not current_view() or owner.context then return end
        local context={};owner.context=context
        host:showBusy(_('Loading saved book reviews...'),function() M.cancel(host) end)
        owner.busy=host.busy_message
        local ok,worker=pcall(function()
            return owner.worker or require('weread.lib.memory_worker'):new{scheduler=UI,codec=host.client,
                max_bytes=4*1024*1024}
        end)
        if not ok or not worker then
            finish();M.cancel(host);host:showInfo(message or _('No saved book reviews. Connect and try again.'));return
        end
        owner.worker=worker
        local started_ok,started=pcall(worker.start,worker,function()
            return Cache:new(host.library_db,host.client,owner.account):read(id)
        end,function(page)
            if owner.context~=context then return end
            if not current_view() then if host._native_reviews_owner==owner then M.cancel(host) end;return end
            finish()
            local valid,normalized=pcall(Cache.validate,host.client,page,id)
            if not valid then
                M.cancel(host);host:showInfo(message or _('No saved book reviews. Connect and try again.'));return
            end
            normalized.has_more=false;normalized.limited=false;render(normalized,true)
        end)
        if not started_ok or not started then
            finish();M.cancel(host);host:showInfo(message or _('No saved book reviews. Connect and try again.'))
        end
    end
    fetch = function(limit, previous)
        if not current_view() or owner.context then return end
        local context = {}; owner.context = context
        local function failed(changed)
            if owner.context ~= context then return end
            finish()
            local message=changed and _('Book reviews changed. Close and open them again.')
                or _('Could not load book reviews. Please try again.')
            if not owner.view and not changed then show_cached(message) else host:showInfo(message) end
        end
        host:showBusy(_('Loading book reviews...'), function() M.cancel(host) end)
        owner.busy = host.busy_message
        local launch
        local function complete(value)
            if owner.context ~= context then return end
            if not current() then if host._native_reviews_owner == owner then M.cancel(host) end return end
            if type(value) == 'table' and value.native_expired then
                local recovering = Recovery.start(host, context, owner.selected, {
                    capture = Source.capture, is_current = current_view,
                    stale = function() if host._native_reviews_owner == owner then M.cancel(host) end end,
                    complete = function(success, renewed)
                        owner.selected = renewed
                        if success then launch() else failed() end
                    end,
                })
                if recovering then return end
            end
            if type(value) ~= 'table' or value.ok ~= true or type(value.page) ~= 'table' then
                failed(type(value) == 'table' and value.changed); return
            end
            finish(); render(value.page)
            if value.cache_saved==false and type(host.showTransientInfo)=='function' then
                host:showTransientInfo(_('Could not save book reviews for offline use.'),3)
            end
        end
        local scheduled = host:runOnlineTask(_('Book reviews'), function()
            if not current() then if host._native_reviews_owner == owner then M.cancel(host) end return end
            local ok, worker = pcall(function()
                return owner.worker or require('weread.lib.memory_worker'):new{scheduler = UI, codec = host.client,
                    max_bytes = 4 * 1024 * 1024}
            end)
            if not ok or not worker then failed(); return end
            owner.worker = worker
            launch = function()
                local started_ok, started = pcall(worker.start, worker, function()
                    local valid, result = pcall(Source.fetch, host.client, id, limit, previous, owner.selected,
                        host.native_renewal ~= nil and not context.recovery_attempted)
                    local saved
                    if valid then
                        local cache_ok,cache_result=pcall(function()
                            return Cache:new(host.library_db,host.client,owner.account):write(id,result,os.time())
                        end)
                        saved=cache_ok and cache_result==true
                    end
                    return valid and {ok = true, page = result, cache_saved = saved}
                        or {ok = false, native_expired = result == 'native_reviews/native_expired',
                            changed = result == 'native_reviews/changed'}
                end, complete)
                if not started_ok or not started then failed() end
            end
            launch()
        end,nil,{silent_offline=true})
        if scheduled == false and host._native_reviews_owner == owner then finish();show_cached() end
    end
    if not selected or not selected.native or type(host.isNetworkOnline)=='function' and not host:isNetworkOnline() then
        show_cached()
    else
        fetch(Data.PAGE_SIZE)
    end
    return true
end
return M
