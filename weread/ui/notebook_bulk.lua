-- Explicit, cancellable account-local caching of notebook marks and thoughts.
local Marks=require('weread.lib.my_cloud_marks')
local Thoughts=require('weread.lib.my_cloud_thoughts')
local Store=require('weread.lib.my_cloud_marks_store')
local Recovery=require('weread.lib.native_read_recovery')
local Popup=require('weread.ui.shelf_popup')
local UI=require('ui/uimanager')
local util=require('weread.lib.plugin_util')
local _,T=util.tr,util.T
local M={PAUSE=0.5}

function M.cancel(host,owner,closed)
    local job=owner and owner.bulk_context
    if not job then return end
    owner.bulk_context=nil
    if job.next_task then UI:unschedule(job.next_task) end
    if job.worker then job.worker:cancel() end
    Recovery.cancel(host,job)
    if not closed then
        if Popup.current(owner.menu,job.dialog) then Popup.close(owner.menu)
        elseif job.dialog then UI:close(job.dialog) end
    end
    if host.busy_message==job.dialog then host.busy_message=nil end
end

function M.start(host,owner,is_current)
    if not is_current(host,owner) or owner.bulk_context or owner.context or not owner.value then return false end
    if not host:isNetworkOnline() then host:showOffline(_('My notebooks'));return false end
    local access=Marks.capture(host.settings)
    if not access then host:showInfo(_('Authorize or renew E-Ink login in settings, then try again.'));return false end
    local ids,seen,skipped={}, {},0
    for _,book in ipairs(owner.value.books or {}) do
        local id=type(book)=='table' and Marks.display_id(book.bookId)
        if id and not seen[id] and #ids<Store.MAX_BOOKS then ids[#ids+1]=id;seen[id]=true
        else skipped=skipped+1 end
    end
    if #ids==0 then host:showInfo(_('No notebooks are available to save.'));return false end
    local job={account=owner.account,db=host.library_db,value=owner.value,access=access,ids=ids,skipped=skipped,done=0,
        data_dir=host.settings.data_dir,cache_dir=host.settings.cache_dir}
    owner.bulk_context=job
    local function valid()
        return owner.bulk_context==job and is_current(host,owner) and host.library_db==job.db
            and job.db:accountKey()==job.account and owner.value==job.value
            and host.settings.data_dir==job.data_dir and host.settings.cache_dir==job.cache_dir
            and (job.renewing and Recovery.current(host.settings,job.access,Marks.capture)
                or not job.renewing and Marks.matches(host.settings,job.access))
    end
    local function finish(outcome)
        if not valid() then M.cancel(host,owner);return end
        local done,total,skipped_count=job.done,#job.ids*2,job.skipped
        M.cancel(host,owner)
        local text=outcome=='cancelled' and _('Saving notes cancelled: %1/%2 sets saved; %3 books skipped.')
            or outcome=='failed' and _('Saving notes stopped: %1/%2 sets saved; %3 books skipped. Previous saved notes are kept.')
            or _('Notes saved: %1/%2 sets saved; %3 books skipped.')
        if is_current(host,owner) then host:showTransientInfo(T(text,tostring(done),tostring(total),tostring(skipped_count)),4) end
    end
    local shown,dialog=pcall(function() return require('weread.ui.download_dialog'):new{
        title=T(_('Saving cloud notes: %1/%2 sets'),'0',tostring(#ids*2)),
        description=_('Each book has marks and thoughts. Up to 64 books; saved sets are kept if you cancel.'),progress_max=#ids*2,
        buttons={{{text=_('Cancel'),callback=function() finish('cancelled') end}}},
    } end)
    if not shown or not dialog then M.cancel(host,owner);host:showInfo(_('Could not start saving cloud notes.'));return false end
    job.dialog=dialog;host.busy_message=dialog
    local close=dialog.onCloseWidget
    dialog.onCloseWidget=function(widget,...)
        if owner.bulk_context==job then M.cancel(host,owner,true) end
        if close then return close(widget,...) end
    end
    if not Popup.show(owner.menu,dialog,function(widget) widget:show() end) then M.cancel(host,owner);return false end
    local created,worker=pcall(function() return require('weread.lib.memory_worker'):new{
        scheduler=UI,codec=host.client,max_bytes=Store.MAX_PAYLOAD+65536} end)
    if not created or not worker then M.cancel(host,owner);host:showInfo(_('Could not start saving cloud notes.'));return false end
    job.worker=worker
    local launch
    local function later()
        job.next_task=function()
            job.next_task=nil
            if valid() then launch() elseif owner.bulk_context==job then M.cancel(host,owner) end
        end
        UI:scheduleIn(M.PAUSE,job.next_task)
    end
    launch=function()
        if not valid() or not host:isNetworkOnline() then finish('failed');return end
        local id=ids[math.floor(job.done/2)+1]
        local thoughts=job.done%2==1
        local data=thoughts and Thoughts or Marks
        local delivered=false
        local started,ok=pcall(worker.start,worker,function()
            local success,value=pcall(data.fetch,host.client,id,job.access,
                {recover_auth=host.native_renewal~=nil and not job.recovery_attempted})
            return success and {ok=true,value=value} or {native_expired=value==(data.EXPIRED or 'my_marks/native_expired')}
        end,function(result)
            if delivered then return end;delivered=true
            if not valid() then if owner.bulk_context==job then M.cancel(host,owner) end;return end
            if type(result)=='table' and result.native_expired then
                local recovering=Recovery.start(host,job,job.access,{capture=Marks.capture,
                    is_current=function() return is_current(host,owner) and owner.bulk_context==job end,
                    stale=function() if owner.bulk_context==job then M.cancel(host,owner) end end,
                    complete=function(success,renewed)
                        job.access=renewed
                        if success then later() else finish('failed') end
                    end})
                if recovering then return end
            end
            if type(result)~='table' or result.ok~=true then finish('failed');return end
            local verified,value=pcall(data.validate,host.client,result.value,id)
            if not verified then finish('failed');return end
            local saved,success=pcall(function()
                return Store:new(job.db,host.client,thoughts and 'thoughts' or nil):write(value,{preserve_existing=true})
            end)
            if not valid() then if owner.bulk_context==job then M.cancel(host,owner) end;return end
            if not saved or not success then finish('failed');return end
            local display=not thoughts and package.loaded['weread.ui.personal_marks']
            if display and type(display.changed)=='function' then pcall(display.changed,host,value) end
            job.done=job.done+1;dialog:reportProgress(job.done)
            dialog:setTitle(T(_('Saving cloud notes: %1/%2 sets'),tostring(job.done),tostring(#ids*2)))
            if job.done==#ids*2 then finish('complete') else later() end
        end)
        if (not started or not ok) and not delivered then finish('failed') end
    end
    launch();return true
end
return M
