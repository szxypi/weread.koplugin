-- User-requested, cancellable refresh of the complete shelf display cache.
local Data=require('weread.lib.shelf_progress')
local Identity=require('weread.lib.shelf_snapshot')
local Popup=require('weread.ui.shelf_popup')
local UI=require('ui/uimanager')
local Util=require('weread.lib.plugin_util')
local _,T=Util.tr,Util.T
local M={BATCH_SIZE=5,PAUSE_SECONDS=1}

local function current(host,job)
    return host.shelf_progress_all_context==job and job.origin.is_current()
        and host.library_db==job.db and job.db:accountKey()==job.account
        and (host.discovery_epoch or 0)==job.epoch and host._reader_session_gen==job.session
        and (host.ui and host.ui.document)==job.document
        and (not job.document or job.document.file==job.file)
        and host.settings.cache_dir==job.cache and host.settings.data_dir==job.data_dir and job.db.data_dir==job.db_dir
        and host.settings:get('api_key','')==job.api_key
        and (not job.scope or host.settings:auth_scope_matches(job.scope))
end

function M.cancel(host,already_closed)
    local job=host.shelf_progress_all_context;host.shelf_progress_all_context=nil
    if not job then return end
    if job.scheduled and UI.unschedule then UI:unschedule(job.scheduled) end
    if job.request and host.shelf_progress_all_worker then host.shelf_progress_all_worker:cancel(job.request,'cancelled') end
    if job.web_request then require('weread.ui.web_renewal').cancel(host,job.web_request) end
    if not already_closed then
        if job.dialog and Popup.current(job.origin.owner,job.dialog) then Popup.close(job.origin.owner)
        elseif job.dialog then UI:close(job.dialog) end
    end
    if host.busy_message==job.dialog then host.busy_message=nil end
end

local function valid_prefix(values,batch)
    if type(values)~='table' or #values>#batch then return false end
    local count=0
    for key in pairs(values) do
        if type(key)~='number' or key%1~=0 or key<1 or key>#values then return false end
        count=count+1
    end
    if count~=#values then return false end
    for index,value in ipairs(values) do
        if type(value)~='table' or value.book_id~=batch[index] or type(value.fetched_at)~='number'
            or value.fetched_at~=value.fetched_at or value.fetched_at<1 or value.fetched_at>253402300799
            or value.source~='web' and value.source~='gateway' then return false end
        if value.unavailable==true then
            if value.percent~=nil or value.exact_percent~=nil then return false end
        elseif type(value.percent)~='number' or value.percent~=value.percent or value.percent%1~=0
            or value.percent<0 or value.percent>100 or value.unavailable~=nil then return false end
        if value.exact_percent~=nil and (type(value.exact_percent)~='number' or value.exact_percent~=value.exact_percent
            or value.exact_percent<0 or value.exact_percent>100 or math.floor(value.exact_percent)~=value.percent) then return false end
    end
    return true
end

function M.start(host,origin,on_done)
    if not origin or not origin.owner or not origin.is_current() or host.shelf_progress_all_context then return false end
    if not host:isNetworkOnline() then host:showInfo(_('Connect to Wi-Fi to update bookshelf progress.'));return false end
    local db=host.library_db;local account=db and db:accountKey()
    local access=Data.selection(host.settings)
    if not account or not access then host:showInfo(_('Sign in to update bookshelf progress.'));return false end
    local shelf=host.shelf_regular
    if type(shelf)~='table' or #shelf>Identity.MAX_BOOKS then
        host:showInfo(_('Could not start the progress update.'));return false
    end
    local count=0
    for key in pairs(shelf) do
        if type(key)~='number' or key%1~=0 or key<1 or key>#shelf then
            host:showInfo(_('Could not start the progress update.'));return false
        end
        count=count+1
    end
    if count~=#shelf then host:showInfo(_('Could not start the progress update.'));return false end
    local ids,seen,skipped={}, {},0
    for _,book in ipairs(shelf) do
        local id=Identity.persisted_id(book)
        if id and Data.supports(id,access) and not seen[id] then ids[#ids+1]=id;seen[id]=true
        else skipped=skipped+1 end
    end
    if #ids==0 then host:showInfo(_('No books are available for progress update.'));return false end
    local document=host.ui and host.ui.document
    local job={origin=origin,db=db,account=account,access=access,ids=ids,done=0,skipped=skipped,
        epoch=host.discovery_epoch or 0,session=host._reader_session_gen,document=document,file=document and document.file,
        cache=host.settings.cache_dir,data_dir=host.settings.data_dir,db_dir=db.data_dir,api_key=host.settings:get('api_key',''),
        scope=host.settings.get_auth_scope and host.settings:get_auth_scope()}
    if host.cancelShelfProgress then host:cancelShelfProgress() end
    host:closeBusy()
    if not origin.is_current() then return false end
    host.shelf_progress_all_context=job
    local function finish(outcome)
        if not current(host,job) then M.cancel(host);return end
        local done,total,missing=job.done,#job.ids,job.skipped
        if outcome=='failed' and Data.matches(host.settings,job.access) then
            host.shelf_progress_retry_at=os.time()+30
            host.shelf_progress_retry_revision=job.access.revision
        end
        M.cancel(host)
        if origin.is_current() and on_done then on_done({skip_progress_fetch_once=true}) end
        local text=outcome=='cancelled' and _('Progress update cancelled: %1/%2 books saved; %3 skipped.')
            or outcome=='failed' and _('Progress update stopped: %1/%2 books saved; %3 skipped.')
            or _('Progress updated: %1/%2 books saved; %3 skipped.')
        host:showTransientInfo(T(text,tostring(done),tostring(total),tostring(missing)),4)
    end
    local function cancel() if host.shelf_progress_all_context==job then finish('cancelled') end end
    local shown,dialog=pcall(function() return require('weread.ui.download_dialog'):new{
        title=T(_('Updating bookshelf progress: %1/%2'),'0',tostring(#ids)),
        description=_('Progress is saved in batches. You can cancel at any time.'),progress_max=#ids,
        buttons={{{text=_('Cancel'),callback=cancel}}},
    } end)
    if not shown or not dialog then M.cancel(host);host:showInfo(_('Could not start the progress update.'));return false end
    job.dialog=dialog;host.busy_message=dialog
    local old_close=dialog.onCloseWidget
    dialog.onCloseWidget=function(widget,...)
        if host.shelf_progress_all_context==job then M.cancel(host,true) end
        if old_close then return old_close(widget,...) end
    end
    if not Popup.show(origin.owner,dialog,function(widget) widget:show() end) then M.cancel(host);return false end
    if not host.shelf_progress_all_worker then
        local ok,worker=pcall(function() return require('weread.lib.background_worker'):new{
            temp_dir=host.settings.data_dir..'/workers',timeout=45} end)
        if ok then host.shelf_progress_all_worker=worker end
    end
    local worker=host.shelf_progress_all_worker
    if not worker or not worker:available() then M.cancel(host);host:showInfo(_('Could not start the progress update.'));return false end
    local launch
    local function later()
        job.scheduled=function()
            job.scheduled=nil
            if current(host,job) then launch() elseif host.shelf_progress_all_context==job then M.cancel(host) end
        end
        UI:scheduleIn(M.PAUSE_SECONDS,job.scheduled)
    end
    launch=function()
        if not current(host,job) then M.cancel(host);return end
        if not host:isNetworkOnline() or not Data.matches(host.settings,job.access) then finish('failed');return end
        local batch={}
        for i=job.done+1,math.min(#job.ids,job.done+M.BATCH_SIZE) do batch[#batch+1]=job.ids[i] end
        local batch_access=job.access;local delivered=false
        local ok,started,request=pcall(worker.start,worker,{
            kind='shelf_progress_all',queue=true,
            task=function(ctx)
                local paced={checkCancelled=ctx.checkCancelled,emit=function(state)
                    if state.current and state.current>1 then ctx.sleep(0.25) end
                    ctx.emit(state)
                end}
                return Data.fetch(host.client,batch,paced,batch_access,{web_only=job.web_only})
            end,
            on_progress=function(state)
                if current(host,job) and type(state)=='table' and type(state.current)=='number'
                    and state.current%1==0 and state.current>=1 and state.current<=#batch then
                    local completed=job.done+state.current-1
                    dialog:reportProgress(completed)
                end
            end,
            on_done=function(result)
                if delivered then return end;delivered=true
                if not current(host,job) then if host.shelf_progress_all_context==job then M.cancel(host) end;return end
                job.request=nil
                if not Data.matches(host.settings,job.access) or type(result)~='table' or not result.ok
                    or type(result.value)~='table' or result.value.stale then finish('failed');return end
                local value=result.value;local values=value.snapshots
                if not valid_prefix(values,batch) or not value.failed and #values~=#batch then finish('failed');return end
                if #values>0 then
                    local saved,committed=pcall(job.db.putShelfProgress,job.db,values)
                    if not saved or committed~=true then finish('failed');return end
                end
                job.done=job.done+#values
                dialog:reportProgress(job.done,T(_('Updating bookshelf progress: %1/%2'),tostring(job.done),tostring(#ids)))
                if value.web_expired and not job.renewed then
                    if value.next_index~=#values+1 or value.next_index>#batch then finish('failed');return end
                    job.renewed=true
                    local Renewal=require('weread.ui.web_renewal')
                    local delivered_renewal=false
                    local called_renewal,started_renewal,renewal_request=pcall(Renewal.run,host,{is_current=function() return current(host,job) end},function(success)
                        delivered_renewal=true
                        if not current(host,job) then return end
                        job.web_request=nil
                        local fresh=success and Data.selection(host.settings)
                        if not fresh or not fresh.web then finish('failed');return end
                        job.access=fresh;job.web_only=true;later()
                    end)
                    if current(host,job) and called_renewal and started_renewal and not delivered_renewal then job.web_request=renewal_request
                    elseif current(host,job) and not delivered_renewal and (not called_renewal or not started_renewal) then finish('failed') end
                    return
                end
                if value.failed then finish('failed') elseif job.done==#ids then finish('complete') else later() end
            end,
        })
        if ok and started then
            if not delivered and current(host,job) then
                if request then job.request=request else pcall(worker.cancel,worker,nil,'invalid_request');finish('failed') end
            end
        elseif not delivered then finish('failed') end
    end
    launch();return true
end
return M
