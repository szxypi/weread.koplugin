-- Detailed statistics use cancellable memory workers and scoped SQLite cache.
local Source=require("weread.lib.statistics_source")
local Data=require("weread.lib.statistics_data")
local Stats=require("weread.lib.read_stats")
local Recovery=require("weread.lib.native_read_recovery")
local UIManager=require("ui/uimanager")
local _=require("weread.lib.plugin_util").tr
local M={}

function M.cancel(host)
    local context=host.statistics_request
    host.statistics_request=nil
    if not context then return end
    if host.statistics_worker then host.statistics_worker:cancel() end
    Recovery.cancel(host,context)
    if host._stats_busy_generation==context.generation then host._stats_busy_generation=nil end
    if context.busy and host.busy_message==context.busy then host:closeBusy() end
end

function M.access_needed(host,reason)
    if reason=="login_required" and host.qr_login then
        host:showTransientInfo(_("Please scan the QR code to log in first."),2)
        UIManager:scheduleIn(0.2,function() host.qr_login:start() end)
    elseif reason=="login_required" then host:requireLogin(true,false)
    elseif host.native_authorization then host.native_authorization:showMenu()
    else host:showInfo(_("Reading statistics need E-Ink authorization or an official API key.")) end
end

function M.load(host,mode,base_time,old_view)
    mode=mode or "monthly";base_time=base_time or 0
    if not Data.mode(mode) or not Data.base(base_time) then return false end
    if old_view and old_view~=host._read_stats_view then return false end
    old_view=old_view or host._read_stats_view
    M.cancel(host)
    local access,reason=Source.capture(host.settings)
    if reason=="login_required" then M.access_needed(host,reason);return false end
    local account=host.library_db and host.library_db:accountKey()
    local epoch=host.discovery_epoch or 0
    local canonical=mode=="overall" and 0 or Stats.period_start(mode,base_time>0 and base_time or os.time())
    local cache_key="reading-statistics:"..mode..":"..string.format("%.0f",canonical)
    local function show(raw,source,cached,fetched_at)
        local clean=Data.project(raw,mode,base_time)
        local data=Stats.prepare(clean,mode,base_time)
        data.source_kind,data.cached,data.fetched_at=source,cached,fetched_at
        if old_view then host._read_stats_view=nil;UIManager:close(old_view) end
        local view
        view=require("weread.ui.read_stats_view").show(data,{
            on_prev=function() host:loadReadStats(mode,data.prev_base_time,view) end,
            on_next=function() host:loadReadStats(mode,data.next_base_time,view) end,
            on_switch=function(next_mode) host:loadReadStats(next_mode,nil,view) end,
            on_close=function()
                if host._read_stats_view==view then
                    host._read_stats_view=nil;M.cancel(host)
                    host._stats_generation=(host._stats_generation or 0)+1
                    if host._profile_view and host.showProfile then host:showProfile() end
                end
            end,
        })
        host._read_stats_view=view
        return clean
    end
    local function cached()
        if not account or not host.library_db.getProfileState then return false end
        local record=host.library_db:getProfileState(cache_key)
        if type(record)~="table" or type(record.raw)~="table" then return false end
        return pcall(show,record.raw,record.source_kind,true,record.fetched_at)
    end
    if host.isNetworkOnline and not host:isNetworkOnline() then
        if cached() then return true end
        host:showOffline(_("Reading statistics"));return false
    end
    if not access then M.access_needed(host,reason);return false end
    host._stats_generation=(host._stats_generation or 0)+1
    local context={generation=host._stats_generation}
    host.statistics_request=context
    host._stats_busy_generation=context.generation
    host:showBusy(_("Loading reading statistics..."),function() M.cancel(host) end)
    context.busy=host.busy_message
    local function current_view()
        return host.statistics_request==context and epoch==(host.discovery_epoch or 0)
            and (not host.library_db or host.library_db:accountKey()==account)
            and (not old_view or host._read_stats_view==old_view)
    end
    local function current()
        return current_view() and (context.renewing and Recovery.current(host.settings,access,Source.capture)
            or Source.matches(host.settings,access))
    end
    local function done()
        host.statistics_request=nil
        if host._stats_busy_generation==context.generation then host._stats_busy_generation=nil end
        if context.busy and host.busy_message==context.busy then host:closeBusy() end
    end
    local function failed()
        done()
        if not cached() then host:showInfo(_("Could not refresh reading statistics. Your cached data is kept.")) end
    end
    local launch
    local function complete(result)
        if not current() then if host.statistics_request==context then M.cancel(host) end return end
        if type(result)=="table" and result.native_expired then
            local recovering=Recovery.start(host,context,access,{capture=Source.capture,is_current=current_view,
                stale=function() if host.statistics_request==context then M.cancel(host) end end,
                complete=function(success,renewed)
                    access=renewed
                    if success or renewed.api_key then launch(not success) else failed() end
                end})
            if recovering then return end
        end
        if type(result)~="table" or result.ok~=true or type(result.raw)~="table" then failed();return end
        local valid,clean=pcall(Data.project,result.raw,mode,base_time)
        if not valid then failed();return end
        done()
        local fetched_at=os.time()
        local saved=true
        if account and host.library_db.putProfileState then
            local ok,value=pcall(host.library_db.putProfileState,host.library_db,cache_key,{raw=clean,fetched_at=fetched_at,source_kind=result.source_kind})
            saved=ok and value
        end
        show(clean,result.source_kind,false,fetched_at)
        if not saved then host:showInfo(_("Statistics loaded but could not be saved for offline use. Check storage.")) end
    end
    local started=host:runOnlineTask(_("Reading statistics"),function()
        if not current() then if host.statistics_request==context then M.cancel(host) end return end
        if not host.statistics_worker then
            local ok,worker=pcall(function()
                return require("weread.lib.memory_worker"):new{scheduler=UIManager,codec=host.client,max_bytes=4*1024*1024}
            end)
            if not ok then failed();return end
            host.statistics_worker=worker
        end
        launch=function(skip_native)
            local ok,running=pcall(host.statistics_worker.start,host.statistics_worker,function()
                local valid,raw=pcall(host.client.get_read_stats,host.client,mode,base_time,access,{
                    recover_auth=host.native_renewal~=nil and not context.recovery_attempted,skip_native=skip_native,
                })
                return valid and {ok=true,raw=raw,source_kind=raw._stats_source}
                    or {ok=false,native_expired=raw=="statistics/native_expired"}
            end,complete)
            if not ok or not running then failed() end
        end
        launch(false)
    end)
    if started==false and host.statistics_request==context then M.cancel(host) end
    return started~=false
end

return M
