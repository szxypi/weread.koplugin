-- Cancellable bookstore requests. Network/parsing runs in a memory worker.
local Source=require("weread.lib.discovery_source")
local Recovery=require("weread.lib.native_read_recovery")
local Cache=require("weread.ui.discovery_cache")
local NetworkLink=require("weread.lib.network_link")
local UIManager=require("ui/uimanager")
local _=require("weread.lib.plugin_util").tr
local M={}

local function is_visible_batch(state,query,cursor)
    local expected_source=query.public_only and 'public' or query.source_kind
    return state and state.cursor==cursor and state.kind==query.kind
        and state.keyword==query.keyword and state.book_id==query.book_id
        and state.category_id==query.category_id and state.rank==query.rank
        and (query.kind~='search' or expected_source and state.source_kind==expected_source
            or not expected_source and state.source_kind~='public')
end

function M.cancel(host)
    local context=host.discovery_request_context
    host.discovery_request_context=nil
    if not context then return end
    host.discovery_loading=nil
    if host.discovery_worker then host.discovery_worker:cancel() end
    Recovery.cancel(host,context)
    if context.busy and host.busy_message==context.busy then host:closeBusy() end
end

function M.load(host,kind,keyword,cursor,previous,refresh,context)
    if host.discovery_loading then return end
    context=context or {}
    if context.account and context~=host.discovery_state then return end
    cursor=refresh and 0 or cursor or 0
    local source_state=host.discovery_state
    local refreshing_visible=refresh and context==source_state
    local binding=not refresh and (cursor>0 or previous) and (context.source_kind and context or source_state) or nil
    local public_search=kind=='search' and (context.public_search==true or context.source_kind=='public')
    local query={kind=kind,keyword=keyword,book_id=context.book_id,book_title=context.book_title,
        category_id=context.category_id,category_title=context.category_title,rank=context.rank,public_only=public_search,
        source_kind=kind=='search' and binding and binding.source_kind or nil}
    local function offline()
        if refreshing_visible then
            host:showInfo(_("Connect to Wi-Fi to refresh. The current list is still available."));return false
        end
        if Cache.open(host,query,cursor) then return true end
        host:showInfo(_("No saved books for this batch. Connect to Wi-Fi and refresh the list."));return false
    end
    if context.cached and not refresh or not NetworkLink.available(host) then return offline() end
    local selected,reason
    if kind~="category" and not public_search then
        selected,reason=Source.capture(host.settings)
        if not selected then
            if kind=='search' and cursor==0 and not context.source_kind
                and (reason=='native_required' or reason=='login_required' and not host.library_db:accountKey()) then
                public_search=true
            elseif reason=="login_required" and host.qr_login then
                host:showTransientInfo(_("Please scan the QR code to log in first."),2)
                UIManager:scheduleIn(0.2,function() host.qr_login:start() end)
            elseif host.native_authorization then host.native_authorization:showMenu()
            else host:showInfo(_("The bookstore needs E-Ink authorization or an official API key.")) end
            if not public_search then return end
        end
    end
    local book_id,book_title=context.book_id,context.book_title
    local session_id=not refresh and context.session_id or nil
    if kind=="similar" and (not book_id or book_id=="") then return end
    if kind=="similar" and cursor>0 and (not session_id or session_id=="") then
        host:showInfo(_("Similar recommendations changed. Open similar books again."));return
    end
    local account=host.library_db:accountKey()
    local epoch=host.discovery_epoch or 0
    local request={kind=kind,keyword=keyword,cursor=cursor,book_id=book_id,session_id=session_id,
        category_id=context.category_id,rank=context.rank,
        source_kind=public_search and 'public' or binding and binding.source_kind,
        source_revision=public_search and 'public' or binding and binding.source_revision}
    if request.source_revision and kind~="category" and not public_search and request.source_revision~=selected.revision then
        host:showInfo(_("Bookstore access changed. Refresh or reopen the list."));return
    end
    local operation={account=account,epoch=epoch}
    local auth_scope=host.settings.get_auth_scope and host.settings:get_auth_scope()
    local auth_epoch=host.settings.get and host.settings:get('auth_epoch',0)
    host.discovery_request_context=operation
    host.discovery_loading=true
    local function current_view()
        if host.discovery_request_context~=operation or account~=host.library_db:accountKey()
            or epoch~=(host.discovery_epoch or 0) then return false end
        if public_search and host.settings.get_auth_scope then
            local now=host.settings:get_auth_scope()
            if auth_scope then return now and now.vid==auth_scope.vid and now.epoch==auth_scope.epoch
                and host.settings:auth_scope_matches(auth_scope) end
            return not now and (not host.settings.get or host.settings:get('auth_epoch',0)==auth_epoch)
        end
        return true
    end
    local function current()
        return current_view() and (kind=="category" or public_search or (operation.renewing and Recovery.current(host.settings,selected,Source.capture)
            or Source.matches(host.settings,selected)))
    end
    local launch
    local function fallback_public()
        if kind~='search' or request.cursor~=0 or request.source_kind or selected.api_key then return false end
        public_search=true
        request.source_kind,request.source_revision='public','public'
        launch(false)
        return true
    end
    local function complete(value)
        if not current() then
            if host.discovery_request_context==operation then M.cancel(host) end
            return
        end
        if type(value)=="table" and value.native_expired then
            local recovering=Recovery.start(host,operation,selected,{capture=Source.capture,is_current=current_view,
                stale=function() if host.discovery_request_context==operation then M.cancel(host) end end,complete=function(success,renewed)
                    selected=renewed
                    if success then
                        if request.source_kind=="native" then request.source_revision=renewed.revision end
                        launch(false)
                    elseif request.cursor==0 and not request.source_kind and renewed.api_key then launch(true)
                    elseif not fallback_public() then complete(nil) end
                end})
            if recovering then return end
            if fallback_public() then return end
        end
        host.discovery_request_context=nil;host.discovery_loading=nil
        if operation.busy and host.busy_message==operation.busy then host:closeBusy() end
        if type(value)~="table" or value.ok~=true or type(value.page)~="table" then
            local limited=type(value)=="table" and value.rate_limited==true
            local message=limited and _("Bookstore requests are limited. Please try again later.")
                or _("Bookstore request failed. Cached books are still available.")
            local use_cached=not refreshing_visible
                and (not source_state or not limited and not is_visible_batch(source_state,query,cursor))
            if use_cached and Cache.open(host,query,cursor) and host.showTransientInfo then
                host:showTransientInfo(message,3)
            else
                host:showInfo(message)
            end
            return
        end
        local result=value.page
        if kind=="similar" then
            if session_id and session_id~="" and result.session_id~=session_id then
                host:showInfo(_("Similar recommendations changed. Open similar books again."));return
            end
            if result.session_id=="" then result.has_more=false end
        end
        local history={}
        if not refresh and source_state and source_state.kind==kind and source_state.keyword==keyword
            and (kind~="similar" or (source_state.book_id==book_id and source_state.session_id==session_id))
            and (kind~="category" or (source_state.category_id==context.category_id and source_state.rank==context.rank)) then
            for i,item in ipairs(source_state.history) do history[i]=item end
            if previous then table.remove(history)
            elseif cursor~=0 then history[#history+1]=source_state.cursor
            else history={} end
        end
        if #history>100 then table.remove(history,1) end
        result.kind,result.keyword,result.cursor=kind,keyword,cursor
        result.book_id,result.book_title=book_id,book_title
        if kind=="category" then result.category_id,result.category_title,result.rank=context.category_id,context.category_title,context.rank end
        result.history,result.account,result.loaded_at=history,account,os.time()
        Cache.save(host,result,source_state,not refresh and (cursor>0 or previous))
        host.discovery_state=result
        if host._book_detail_view then
            local detail=host._book_detail_view;host._book_detail_view=nil;UIManager:close(detail)
        end
        host:showBookstore()
    end
    if host.showBusy then
        host:showBusy(_("Loading books..."),function() M.cancel(host) end)
        operation.busy=host.busy_message
    end
    local started=host:runOnlineTask(_("Bookstore"),function()
        if not current() then if host.discovery_request_context==operation then M.cancel(host) end return end
        local ready,worker=pcall(function()
            return host.discovery_worker or require("weread.lib.memory_worker"):new{scheduler=UIManager,codec=host.client,max_bytes=512*1024}
        end)
        if not ready then complete(nil);return end
        host.discovery_worker=worker
        launch=function(skip_native)
            local ok,running=pcall(worker.start,worker,function()
                if not current() then return {ok=false} end
                local valid,page=pcall(Source.fetch,host.client,request,selected,{
                    recover_auth=host.native_renewal~=nil and not operation.recovery_attempted,skip_native=skip_native,
                })
                return valid and {ok=true,page=page} or {ok=false,native_expired=page=="discovery/native_expired",
                    rate_limited=page=="discovery/rate_limited"}
            end,complete)
            if not ok or not running then complete(nil) end
        end
        launch(false)
    end,nil,{link_only=true,silent_offline=true})
    if started==false and host.discovery_request_context==operation then
        M.cancel(host)
        return offline()
    end
end

return M
