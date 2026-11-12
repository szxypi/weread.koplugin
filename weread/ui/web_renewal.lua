-- Shared native renewal UI. Retry saving reuses the receipt, never the POST.
local Renewal=require('weread.lib.web_renewal')
local UIManager=require('ui/uimanager')
local _=require('weread.lib.plugin_util').tr
local M={}
function M.service(host)
    if not host.web_renewal then host.web_renewal=Renewal:new{settings=host.settings,client=host.client,scheduler=UIManager} end
    return host.web_renewal
end
function M.error_text(reason)
    if reason=='renewal_unconfirmed' then return _('The last login renewal is unconfirmed. Please sign in again before renewing.') end
    if reason=='verification_unconfirmed' then return _('A renewal response was saved, but login verification is incomplete. Try again to verify it without another renewal request.') end
    if reason=='unavailable' then return _('Could not read the saved renewal state. Check storage, or clear login data and sign in again. Cached books are kept.') end
    return _('Login renewal could not finish. Check login, network and storage, then try again.')
end
local function close_dialog(request)
    local dialog=request.dialog;request.dialog=nil;if dialog then UIManager:close(dialog) end
end
function M.cancel(host,expected)
    local request=host._web_renewal_request
    if not request or expected and expected~=request then return end
    host._web_renewal_request=nil
    close_dialog(request)
    local service=host.web_renewal
    if service then
        local job=request.job or service.job and service.job.is_current==request.guard and service.job
        if job then service:cancel(job) end
    end
    if request.busy and host.busy_message==request.busy then host:closeBusy() end
end
function M.clear_for_logout(host)
    M.cancel(host)
    if host.settings:get_auth_scope() then return false end
    -- The explicit logout has already invalidated every old epoch. Unlink only
    -- the bounded owned receipt, allowing a damaged record to be repaired.
    local path=host.settings.data_dir..'/web-renewal.json'
    local mode=require('libs/libkoreader-lfs').symlinkattributes(path,'mode')
    return not mode or mode~='directory' and os.remove(path)==true
end
function M.run(host,options,callback)
    if host._web_renewal_request then return false,'busy' end
    local service=M.service(host)
    local request={};host._web_renewal_request=request
    request.guard=function()
        if host._web_renewal_request~=request then return false end
        if not options.is_current then return true end
        local ok,current=pcall(options.is_current);return ok and current==true
    end
    local function finish(ok,reason)
        if host._web_renewal_request~=request then return end
        local current=request.guard()
        M.cancel(host,request)
        if current then callback(ok,reason) else callback(false,'session_changed') end
    end
    local attempt
    attempt=function()
        if not request.guard() then finish(false,'session_changed');return end
        close_dialog(request)
        local called,started,job=pcall(service.start,service,{is_current=request.guard},function(ok,reason)
            if not request.guard() then finish(false,'session_changed');return end
            if not ok and reason=='save_failed' then
                local dialog
                dialog=require('ui/widget/confirmbox'):new{keep_dialog_open=true,
                    text=_('Could not save the renewed login. Retry saving without another renewal request?'),
                    ok_text=_('Retry'),cancel_text=_('Cancel'),
                    ok_callback=function() if request.dialog==dialog then attempt() end end,
                    cancel_callback=function() if request.dialog==dialog then finish(false,'save_failed') end end}
                request.dialog=dialog;UIManager:show(dialog)
            else finish(ok,reason) end
        end)
        if host._web_renewal_request==request then
            if called and started then request.job=job
            else finish(false,called and job or 'renewal_unconfirmed') end
        end
    end
    if options.busy then
        host:showBusy(_('Renewing WeRead login…\nTap or press a key to cancel.'),function() M.cancel(host,request) end)
        request.busy=host.busy_message
    end
    attempt()
    return true,request
end
function M.manual(host)
    if not host:requireLogin(true,false) then return false end
    if not host:isNetworkConnected() then host:showOffline(_('Renew cookie'));return false end
    host:closeWeReadUI()
    local account=host.library_db and host.library_db:accountKey()
    local epoch=host.discovery_epoch or 0
    local document=host.ui and host.ui.document
    local file=document and document.file
    local session=host._reader_session_gen
    return M.run(host,{busy=true,is_current=function()
        return account==(host.library_db and host.library_db:accountKey()) and epoch==(host.discovery_epoch or 0)
            and document==(host.ui and host.ui.document) and file==(host.ui and host.ui.document and host.ui.document.file)
            and session==host._reader_session_gen
    end},function(ok,reason)
        if reason=='session_changed' then return end
        if ok then host:refreshLoginMenu();host:showInfo(_('WeRead cookie renewed.'))
        else host:showInfo(M.error_text(reason)) end
    end)
end
return M
