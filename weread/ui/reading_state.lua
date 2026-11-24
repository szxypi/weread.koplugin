-- The shelf-status menu owns this on-demand, read-only background check.
local UI=require('ui/uimanager')
local Access=require('weread.lib.native_read_access')
local Data=require('weread.lib.reading_state')
local Crypto=require('weread.lib.crypto')
local Cache=require('weread.lib.reading_state_cache')
local Recovery=require('weread.lib.native_read_recovery')
local Util=require('weread.lib.plugin_util')
local _,T=Util.tr,Util.T
local M={}

function M.cancel(host)
    local ctx=host._reading_state_ui
    host._reading_state_ui=nil
    if not ctx then return end
    if ctx.worker then ctx.worker:cancel() end
    Recovery.cancel(host,ctx)
    if ctx.busy and host.busy_message==ctx.busy then host:closeBusy() end
end

function M.open(host,id,menu)
    if not Data.id(id) or host._shelf_state_menu~=menu or not host.client or not host.library_db then return false end
    M.cancel(host)
    if host._reading_state_change_ui then
        host:showInfo(_('Wait for the current started-reading change to finish.'));return false
    end
    local account=host.library_db:accountKey()
    local cache=Cache:new(host.library_db,account)
    local previous=cache:read(id)
    if not host:isNetworkOnline() then
        if previous then
            local ok,date=pcall(os.date,'%Y-%m-%d %H:%M',previous.checked_at)
            if not ok or type(date)~='string' then date=_('Time unavailable') end
            local text=previous.started=='missing' and _('Saved on %1: WeRead did not provide a started-reading status. This saved status may be out of date.')
                or previous.started and _('Saved on %1: this book was marked as started. This saved status may be out of date.')
                or _('Saved on %1: this book was not marked as started. This saved status may be out of date.')
            host:showInfo(T(text,date))
            return true
        end
        host:showOffline(_('Shelf status'));return false
    end
    local selected=Access.capture(host.settings)
    if not selected or selected.renewal_pending or not account
        or Crypto.sha256_hex('weread-library:'..selected.scope.vid):sub(1,20)~=account then
        host:showInfo(_('Authorize or renew E-Ink login in settings, then try again.'));return false
    end
    local function capture(settings,store)
        local native=Access.capture(settings,store)
        if not native then return nil end
        return {native=native,base_revision=native.scope.vid..'\0'..tostring(native.scope.epoch)}
    end
    selected={native=selected,base_revision=selected.scope.vid..'\0'..tostring(selected.scope.epoch)}
    local ctx={menu=menu,account=account,selected=selected,epoch=host.discovery_epoch or 0,
        session=host._reader_session_gen,document=host.ui and host.ui.document,parent=host._book_detail_view}
    host._reading_state_ui=ctx
    local function current_view()
        return host._reading_state_ui==ctx and host._shelf_state_menu==menu
            and host.library_db:accountKey()==account and (host.discovery_epoch or 0)==ctx.epoch
            and host._reader_session_gen==ctx.session and (host.ui and host.ui.document)==ctx.document
            and host._book_detail_view==ctx.parent
    end
    local function current()
        if not current_view() then return false end
        if ctx.renewing then return Recovery.current(host.settings,selected,capture) end
        return Access.matches(host.settings,selected.native)
    end
    host:showBusy(_('Checking started-reading status…\nTap or press a key to cancel.'),function()
        if host._reading_state_ui==ctx then M.cancel(host) end
    end)
    ctx.busy=host.busy_message
    local ok,worker=pcall(function() return require('weread.lib.memory_worker'):new{
        scheduler=UI,codec=host.client,timeout=30} end)
    if not ok or not worker then M.cancel(host);host:showInfo(_('Could not check started-reading status.'));return false end
    ctx.worker=worker
    local launch
    launch=function()
        local attempt={};ctx.attempt=attempt
        local started_ok,started=pcall(worker.start,worker,function()
            return Data.read(host.client,host.settings,selected.native,id,
                {recover_auth=host.native_renewal~=nil and not ctx.recovery_attempted})
        end,function(result)
            if ctx.attempt~=attempt then return end
            ctx.attempt=nil
            local active=current()
            if not active then if host._reading_state_ui==ctx then M.cancel(host) end;return end
            if type(result)=='table' and result.kind=='native_expired' then
                local recovering=Recovery.start(host,ctx,selected,{capture=capture,is_current=current_view,
                    stale=function() if host._reading_state_ui==ctx then M.cancel(host) end end,
                    complete=function(success,renewed)
                        selected=renewed;ctx.selected=renewed
                        if success then launch() else M.cancel(host);host:showInfo(_('Authorize or renew E-Ink login in settings, then try again.')) end
                    end})
                if recovering then return end
            end
            M.cancel(host)
            if type(result)=='table' and result.kind=='known' and type(result.started)=='boolean' then
                pcall(cache.write,cache,id,result.started,previous)
                host:showInfo(_(result.started and 'WeRead records this book as started.'
                    or 'WeRead has not marked this book as started. Its saved position and finished status may be different.'))
            elseif type(result)=='table' and result.kind=='missing' then
                pcall(cache.write,cache,id,'missing',previous)
                host:showInfo(_('WeRead did not provide a started-reading status for this book.'))
            elseif type(result)=='table' and (result.kind=='login' or result.kind=='native_expired') then
                host:showInfo(_('Authorize or renew E-Ink login in settings, then try again.'))
            elseif type(result)~='table' or result.kind~='stale' then
                host:showInfo(_('Could not check started-reading status.'))
            end
        end)
        if not started_ok or not started then
            local active=current();if host._reading_state_ui==ctx then M.cancel(host) end
            if active then host:showInfo(_('Could not check started-reading status.')) end
            return false
        end
        return true
    end
    return launch()
end
return M
