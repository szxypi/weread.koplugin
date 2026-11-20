-- Async display metadata; the parent alone persists sanitized fields and UI.
local Access = require("weread.lib.read_access")
local Metadata = require("weread.lib.book_metadata")
local Recovery = require("weread.lib.native_read_recovery")
local ShelfSnapshot = require("weread.lib.shelf_snapshot")
local UIManager = require("ui/uimanager")
local PluginUtil = require("weread.lib.plugin_util")
local _ = PluginUtil.tr
local M = {}

local function close_busy(host, context)
    if context.busy and host.busy_message == context.busy then host:closeBusy() end
end
local function resume_shelf(host, context)
    local popup=package.loaded['weread.ui.shelf_popup']
    if popup and popup.resumeMetadata then popup.resumeMetadata(host,context) end
end

function M.cancel(host)
    local context = host.book_metadata_context
    if not context then return end
    host.book_metadata_context = nil
    if host.book_metadata_worker then host.book_metadata_worker:cancel() end
    Recovery.cancel(host, context)
    if context.web_request then require('weread.ui.web_renewal').cancel(host, context.web_request) end
    close_busy(host, context)
    resume_shelf(host, context)
end

function M.refresh(host, book, old_view, options)
    options = options or {}
    if old_view and host._book_detail_view ~= old_view then return false end
    M.cancel(host)
    local id = Access.display_book_id(ShelfSnapshot.persisted_id(book))
    local access = Metadata.capture(host.settings)
    if not id then return false end
    local known,initial,initial_error=pcall(function()
        return Access.cached_book_for_update(host.settings:get('books',{}),id)
    end)
    if not known or initial_error then
        host:showInfo(_("Saved book information does not match. Check the local cache before opening."))
        return false
    end
    if not host:isNetworkOnline() then
        if options.automatic then host:showBookMenu(book) else host:showOffline(_("Book info")) end
        return false
    end
    local guest=not access and not (host.library_db and host.library_db:accountKey()) and Access.book_id(id)~=nil
    if not access and not guest then
        if options.automatic then
            host:showBookMenu(book)
            if not (host.library_db and host.library_db:accountKey()) then return false end
        end
        host:showTransientInfo(_("Please scan the QR code to log in first."), 2)
        UIManager:scheduleIn(0.2, function() host.qr_login:start() end)
        return false
    end
    local context = { epoch = host.discovery_epoch or 0,auth_epoch=guest and host.settings:get('auth_epoch',0),
        had_saved_record = initial~=nil,
        account = host.library_db and host.library_db:accountKey(), view = old_view }
    host.book_metadata_context = context
    local Page=require('weread.ui.page_scope')
    local page_current=Page.capture(host,host.shelf_view)
    local function current_view()
        return host.book_metadata_context == context and (host.discovery_epoch or 0) == context.epoch
            and page_current()
            and Access.display_book_id(ShelfSnapshot.persisted_id(book)) == id
            and (not host.library_db or host.library_db:accountKey() == context.account)
            and (not old_view or host._book_detail_view == old_view)
            and (not guest or host.settings:get('auth_epoch',0)==context.auth_epoch
                and (not host.settings.get_auth_scope or not host.settings:get_auth_scope()))
    end
    local function current()
        if not current_view() then return false end
        if guest then return true end
        if context.web_renewing then return context.web_current() end
        if context.renewing then return Recovery.current(host.settings, access, Metadata.capture) end
        return Metadata.matches(host.settings, access)
    end
    -- Called synchronously around an applied shelf snapshot. Only a request
    -- that was current before the update may adopt the new shelf references.
    context.begin_shelf_update=function()
        if not current_view() or not host.shelf_view then return end
        local owner=host.shelf_view
        local stable=Page.capture(host,owner,nil,{allow_shelf_snapshot_change=true})
        return function()
            if host.book_metadata_context~=context or not stable() then return end
            page_current=Page.capture(host,owner)
            context.shelf_snapshot_owner=owner
        end
    end
    local function show_details(value)
        host:showBookMenu(value)
        local owner=context.shelf_snapshot_owner
        if owner and host.shelf_view==owner and not owner._shelf_closed and host._book_detail_view then
            owner._shelf_snapshot_detail=host._book_detail_view
            owner._shelf_snapshot_current=Page.capture(host,owner)
        end
    end
    local function finish()
        host.book_metadata_context = nil
        close_busy(host, context)
        resume_shelf(host, context)
    end
    local function failed()
        if options.automatic then show_details(book) end
        host:showTransientInfo(_("Book information could not be updated. Showing cached details."), 3)
    end
    host:showBusy(_("Loading book info..."), function() M.cancel(host) end)
    context.busy = host.busy_message
    if not host.book_metadata_worker then
        local ok, worker = pcall(function()
            return require("weread.lib.memory_worker"):new{ scheduler = UIManager, codec = host.client, max_bytes = 256 * 1024 }
        end)
        if ok then host.book_metadata_worker = worker else finish(); failed(); return false end
    end
    local launch
    local function recover_web()
        if context.web_attempted or not current() then finish(); failed(); return end
        local Auth = require('weread.lib.web_authorization')
        local captured, original = pcall(Auth.capture, host.settings)
        if not captured or type(original) ~= 'table' or type(original.scope) ~= 'table' or type(original.revision) ~= 'string'
            or not Metadata.matches(host.settings, access) then finish(); failed(); return end
        local native_fingerprint = access.native and access.native.fingerprint
        local api_key = host.settings:get('api_key', '')
        context.web_attempted, context.web_renewing = true, true
        context.web_current = function()
            if not current_view() or not host.settings:auth_scope_matches(original.scope)
                or host.settings:get('api_key', '') ~= api_key or not host:isNetworkOnline() then return false end
            local ok, fresh = pcall(Metadata.capture, host.settings, access.native and access.native.store)
            return ok and fresh ~= nil and (fresh.native and fresh.native.fingerprint) == native_fingerprint
        end
        local Renewal = require('weread.ui.web_renewal')
        local delivered = false
        local called, started, request = pcall(Renewal.run, host, {
            is_current = context.web_current, expected_revision = original.revision,
        }, function(success, receipt)
            delivered = true
            if host.book_metadata_context ~= context then return end
            context.web_request = nil
            if not context.web_current() or receipt == 'session_changed' then M.cancel(host); return end
            if not success then finish(); failed(); return end
            local verified, fresh = pcall(Auth.capture, host.settings)
            if not verified or type(receipt) ~= 'table' or type(receipt.revision) ~= 'string'
                or #receipt.revision ~= 64 or not receipt.revision:match('^[0-9a-f]+$')
                or type(fresh) ~= 'table' or fresh.revision ~= receipt.revision or type(fresh.scope) ~= 'table'
                or fresh.scope.vid ~= original.scope.vid or fresh.scope.epoch ~= original.scope.epoch then
                M.cancel(host); return
            end
            access = Metadata.capture(host.settings, access.native and access.native.store)
            if not access or not access.display or not access.display.web then M.cancel(host); return end
            context.web_renewing = nil
            launch(true, true)
        end)
        if host.book_metadata_context == context then
            if called and started then if not delivered then context.web_request = request end else finish(); failed() end
        elseif called and started and request then Renewal.cancel(host, request) end
    end
    local function complete(result)
        if not current() then
            if host.book_metadata_context == context then M.cancel(host) end
            return
        end
        if not guest and type(result) == "table" and result.native_expired then
            local recovering = Recovery.start(host, context, access, { capture = Metadata.capture,
                is_current = current_view, stale = function()
                    if host.book_metadata_context == context then M.cancel(host) end
                end,
                complete = function(success, renewed)
                    access = renewed
                    if success or renewed.display then launch(not success)
                    else finish(); failed() end
                end })
            if recovering then return end
        end
        if not guest and type(result) == 'table' and result.web_expired then recover_web(); return end
        finish()
        local valid, metadata = pcall(Metadata.normalize, type(result) == "table" and result.metadata, id)
        local source_ok=type(result)=='table' and (guest and result.source=='public'
            or not guest and (result.source=='gateway' or result.source=='web' or result.source=='native'))
        if not valid or not source_ok then failed(); return end
        -- Re-read after the network task: reading and downloads may have
        -- changed local state while the metadata request was outstanding.
        local committed, latest = pcall(function()
            local books = host.settings:get("books", {})
            local original,conflict,legacy_key=Access.cached_book_for_update(books,id)
            if conflict then error('book_metadata/identity_conflict',0) end
            if context.had_saved_record and not original then error('book_metadata/record_removed',0) end
            -- Never mutate a stale in-memory record before identity validation
            -- or while a storage failure may still reject this refresh.
            local saved={};for key,value in pairs(original or {}) do saved[key]=value end
            for key, value in pairs(metadata) do saved[key] = value end
            saved.book_id, saved._library_account_key = id, context.account
            saved.detail_updated_at, saved.detail_source = os.time(), result.source
            if not guest and host.library_db and not host.library_db:putBook(saved) then error("metadata_save_failed", 0) end
            if legacy_key then books[legacy_key]=nil end
            books[id] = saved
            host.settings:set("books", books)
            host.settings:flush()
            return saved
        end)
        if not committed then
            if latest=='book_metadata/identity_conflict' then
                host:showInfo(_("Saved book information does not match. Check the local cache before opening."))
            elseif latest=='book_metadata/record_removed' then
                host:showInfo(_("Saved book information changed while refreshing. Reopen the book and try again."))
            else
                if guest and options.automatic then show_details(book) end
                host:showInfo(_("Could not save book information. Check storage and try again."))
            end
            return
        end
        if old_view then UIManager:close(old_view) end
        show_details(latest)
        host:showTransientInfo(_("Book information updated."), 2)
    end
    launch = function(skip_native, web_only)
        local ok, started = pcall(host.book_metadata_worker.start, host.book_metadata_worker, function()
            local valid,result
            if guest then valid,result=pcall(Metadata.fetch_public,host.client,id)
            else valid,result=pcall(Metadata.fetch,host.client,id,access,{
                recover_auth=host.native_renewal~=nil and not context.recovery_attempted,skip_native=skip_native,
                recover_web=true,web_only=web_only,
            }) end
            return valid and result or { native_expired = result == "book_metadata/native_expired",
                web_expired = result == 'book_metadata/web_expired' }
        end, complete)
        if not ok or not started then
            if host.book_metadata_context == context then M.cancel(host); failed() end
            return false
        end
        return true
    end
    return launch()
end

return M
