-- Explicit native single-chapter translation request; network runs in a worker.
local UI=require('ui/uimanager')
local Native=require('weread.lib.native_read_access')
local Web=require('weread.lib.read_access')
local WorkerSettings=require('weread.lib.worker_settings')
local _=require('weread.lib.plugin_util').tr
local M={}
local function stat(path) return require('libs/libkoreader-lfs').symlinkattributes(path) end
local function same(a,b)
    return a and b and a.mode=='file' and b.mode=='file' and a.ino==b.ino and a.dev==b.dev
        and a.size==b.size and a.modification==b.modification
end
function M.cancel(host)
    local job=host.translation_generation_job;host.translation_generation_job=nil
    if not job then return end
    if host.translation_generation_worker then host.translation_generation_worker:cancel() end
    if job.busy and host.busy_message==job.busy then host:closeBusy() end
end
function M.view_changed(host)
    local job=host.translation_generation_job
    if job and not require('weread.ui.translation_fetch').is_current(host,job.owner) then M.cancel(host) end
end
function M.start(host)
    M.cancel(host)
    host:closeWeReadUI()
    if not host:isNetworkOnline() then host:showOffline(_('Request official translation for this chapter (experimental)'));return false end
    if not host:requireLogin(true,false) then return false end
    local Fetch=require('weread.ui.translation_fetch')
    local captured,owner=pcall(Fetch.capture_owner,host)
    if not captured or not owner or not Fetch.is_current(host,owner) then
        host:showInfo(_('Could not request this chapter’s translation. Check the login, membership, chapter access and network, then try again.'));return false
    end
    local native_ok,selected=pcall(Native.capture,host.settings)
    local web_ok,web=pcall(Web.capture,host.settings)
    if not native_ok or not selected or selected.renewal_pending then
        host:showInfo(_('Authorize or renew E-Ink login in settings, then try again.'));return false
    end
    if not web_ok or not web or not web.web then
        host:showInfo(_('Could not request this chapter’s translation. Check the login, membership, chapter access and network, then try again.'));return false
    end
    if host.downloader and (host.downloader._active_job or host.downloader._pending_start or host.downloader._scheduled_start) then
        host:showInfo(_('The reader is busy. Please try again shortly.'));return false
    end
    local input={book_id=owner.book_id,chapter_uid=owner.source.chapter_uid,path=owner.file,
        metadata=owner.source.metadata,file_id=owner.source.identity.file_id}
    local opened,journal=pcall(function() return require('weread.lib.translation_generation_journal'):new(host.library_db,host.client,owner.scope) end)
    if not opened or not journal then
        host:showInfo(_('Could not request this chapter’s translation. Check the login, membership, chapter access and network, then try again.'));return false
    end
    local job={owner=owner,started=os.time()};host.translation_generation_job=job
    host:showBusy(_('Checking this chapter and requesting its official translation…\nTap or press a key to cancel.'),
        function() if host.translation_generation_job==job then M.cancel(host) end end)
    job.busy=host.busy_message
    if not host.translation_generation_worker then
        local made,worker=pcall(function() return require('weread.lib.memory_worker'):new{scheduler=UI,codec=host.client,timeout=600} end)
        if not made then M.cancel(host);host:showInfo(_('Could not request this chapter’s translation. Check the login, membership, chapter access and network, then try again.'));return false end
        host.translation_generation_worker=worker
    end
    host.translation_generation_worker.timeout=600
    local launched,started=pcall(host.translation_generation_worker.start,host.translation_generation_worker,function()
        local capture=WorkerSettings.capture(host.settings)
        -- The child opens its own archive. Never use the inherited reader DOM.
        local function current_file()
            return same(owner.stat,stat(owner.file)) and host.settings:auth_scope_matches(owner.scope)
                and WorkerSettings.fingerprint(host.settings)==owner.auth
        end
        local value=require('weread.lib.translation_generation_task').run(host.client,host.settings,selected,web,input,journal,
            {is_current=current_file})
        value.auth=capture();return value
    end,function(result)
        if host.translation_generation_job~=job then return end
        local age=os.time()-job.started
        if not Fetch.is_current(host,owner) or age<0 or age>600 then M.cancel(host);return end
        if type(result)=='table' and result.auth and not WorkerSettings.merge(host.settings,owner.auth,result.auth) then
            M.cancel(host);host:showInfo(_('The translation request could not be confirmed. Check for an existing translation later; the request will not be sent again automatically.'));return
        end
        owner.auth=WorkerSettings.fingerprint(host.settings)
        local kind=type(result)=='table' and result.kind
        M.cancel(host)
        if kind=='available' then Fetch.start(host)
        elseif kind=='pending' then host:showInfo(_('The official translation is still being prepared. Try downloading the existing translation later.'))
        elseif kind=='stopped' then host:showInfo(_('The official translation is not available for this chapter. The original book is kept.'))
        elseif kind=='unavailable' then host:showInfo(_('Could not request this chapter’s translation. Check the login, membership, chapter access and network, then try again.'))
        else host:showInfo(_('The translation request could not be confirmed. Check for an existing translation later; the request will not be sent again automatically.')) end
    end)
    if not launched or not started then
        M.cancel(host);host:showInfo(_('Could not request this chapter’s translation. Check the login, membership, chapter access and network, then try again.'));return false
    end
    return true
end
return M
