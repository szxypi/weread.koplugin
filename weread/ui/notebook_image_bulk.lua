-- Explicitly cache images from saved personal thoughts without evicting
-- earlier images. Each bounded worker handles one book or one image.
local Marks=require('weread.lib.my_cloud_marks')
local Thoughts=require('weread.lib.my_cloud_thoughts')
local Notes=require('weread.lib.my_cloud_marks_store')
local Attachment=require('weread.lib.thought_attachments')
local Contract=require('weread.lib.thought_edit_contract')
local Popup=require('weread.ui.shelf_popup')
local UI=require('ui/uimanager')
local Util=require('weread.lib.plugin_util')
local _,T=Util.tr,Util.T
local M={PAUSE=0.25}

function M.cancel(host,owner,closed)
    local job=owner and owner.image_bulk_context
    if not job then return end
    owner.image_bulk_context=nil
    if job.gate then job.gate:close();job.gate=nil end
    if job.next_task then UI:unschedule(job.next_task) end
    if job.worker then job.worker:cancel() end
    if not closed then
        if Popup.current(owner.menu,job.dialog) then Popup.close(owner.menu)
        elseif job.dialog then UI:close(job.dialog) end
    end
    if host.busy_message==job.dialog then host.busy_message=nil end
end

function M.start(host,owner,is_current)
    if not is_current(host,owner) or owner.image_bulk_context or owner.bulk_context or owner.context or not owner.value then return false end
    if not host:isNetworkOnline() then host:showOffline(_('My notebooks'));return false end
    local ids,seen,skipped={}, {},0
    for _,book in ipairs(owner.value.books or {}) do
        local id=type(book)=='table' and Marks.display_id(book.bookId)
        if id and not seen[id] and #ids<Notes.MAX_BOOKS then ids[#ids+1]=id;seen[id]=true
        else skipped=skipped+1 end
    end
    if #ids==0 then host:showInfo(_('No notebooks are available to save.'));return false end
    local job={account=owner.account,db=host.library_db,value=owner.value,ids=ids,index=1,done=0,
        saved=0,cached=0,missing=0,partial=0,unverified=0,skipped=skipped,data_dir=host.settings.data_dir,cache_dir=host.settings.cache_dir}
    local guarded,gate=pcall(function() return require('weread.lib.native_position_guard'):new() end)
    if not guarded or not gate then host:showInfo(_('Could not start saving thought images.'));return false end
    job.gate=gate
    owner.image_bulk_context=job
    local function valid()
        return owner.image_bulk_context==job and is_current(host,owner) and host.library_db==job.db
            and job.gate and job.gate:valid() and job.db:accountKey()==job.account and owner.value==job.value
            and host.settings.data_dir==job.data_dir and host.settings.cache_dir==job.cache_dir
    end
    local function finish(outcome)
        if not valid() then M.cancel(host,owner);return end
        local text=outcome=='cancelled' and _('Image save cancelled: %1 downloaded, %2 already saved; %3 note sets missing; %4 thoughts have unsupported attachments; %5 thoughts could not be verified; %6 books skipped.')
            or outcome=='failed' and _('Image save stopped: %1 downloaded, %2 already saved; %3 note sets missing; %4 thoughts have unsupported attachments; %5 thoughts could not be verified; %6 books skipped. Earlier images are kept.')
            or _('Images saved: %1 downloaded, %2 already saved; %3 note sets missing; %4 thoughts have unsupported attachments; %5 thoughts could not be verified; %6 books skipped.')
        local saved,cached,missing,partial,unverified,skipped_count=job.saved,job.cached,job.missing,job.partial,job.unverified,job.skipped
        M.cancel(host,owner)
        if is_current(host,owner) then
            local message=T(text,tostring(saved),tostring(cached),tostring(missing),tostring(partial),tostring(unverified),tostring(skipped_count))
            if outcome=='failed' or missing>0 or partial>0 or unverified>0 or skipped_count>0 then host:showInfo(message)
            else host:showTransientInfo(message,5) end
        end
    end
    local shown,dialog=pcall(function() return require('weread.ui.download_dialog'):new{
        title=T(_('Saving thought images: %1/%2 books'),'0',tostring(#ids)),progress_max=#ids,
        description=_('Images from saved thoughts are downloaded without account credentials. Saved images are kept if you cancel or storage is full.'),
        buttons={{{text=_('Cancel'),callback=function() finish('cancelled') end}}},
    } end)
    if not shown or not dialog then M.cancel(host,owner);host:showInfo(_('Could not start saving thought images.'));return false end
    job.dialog=dialog;host.busy_message=dialog
    local close=dialog.onCloseWidget
    dialog.onCloseWidget=function(widget,...)
        if owner.image_bulk_context==job then M.cancel(host,owner,true) end
        if close then return close(widget,...) end
    end
    if not Popup.show(owner.menu,dialog,function(widget) widget:show() end) then M.cancel(host,owner);return false end
    local ok,worker=pcall(function() return require('weread.lib.memory_worker'):new{
        scheduler=UI,codec=host.client,max_bytes=Notes.MAX_PAYLOAD+65536,timeout=90} end)
    if not ok or not worker then M.cancel(host,owner);host:showInfo(_('Could not start saving thought images.'));return false end
    job.worker=worker
    local launch
    local function later()
        job.next_task=function()
            job.next_task=nil
            if valid() then launch() elseif owner.image_bulk_context==job then M.cancel(host,owner) end
        end
        UI:scheduleIn(M.PAUSE,job.next_task)
    end
    local function complete_book()
        job.snapshot=nil;job.row_index=nil;job.url_index=nil;job.urls=nil
        job.done=job.done+1;job.index=job.index+1
        dialog:reportProgress(job.done,T(_('Saving thought images: %1/%2 books'),tostring(job.done),tostring(#ids)))
        if job.index>#ids then finish('complete') else later() end
    end
    launch=function()
        if not valid() or not host:isNetworkOnline() then finish('failed');return end
        local id=ids[job.index]
        if not job.snapshot then
            local delivered=false
            local called,started=pcall(worker.start,worker,function()
                local store=Notes:new(job.db,host.client,'thoughts')
                local available=store:valid_ids({id})
                if not available then return {error='cache'} end
                if not available[id] then return {missing=true} end
                local value=store:read(id)
                return value and {snapshot=value} or {error='cache'}
            end,function(result)
                if delivered then return end;delivered=true
                if not valid() then if owner.image_bulk_context==job then M.cancel(host,owner) end;return end
                if type(result)=='table' and result.missing==true then job.missing=job.missing+1;complete_book();return end
                local verified,value=pcall(Thoughts.validate,host.client,type(result)=='table' and result.snapshot,id)
                if not verified then finish('failed');return end
                job.snapshot=value;job.row_index=1;job.url_index=1;later()
            end)
            if (not called or not started) and not delivered then finish('failed') end
            return
        end
        while job.row_index<=#job.snapshot.reviews do
            local row=job.snapshot.reviews[job.row_index]
            if not job.urls then
                job.urls=Attachment.decode(row.attachment_urls or '')
                if not job.urls then finish('failed');return end
                if row.attachment_state=='partial' then job.partial=job.partial+1 end
                if row.attachment_state and not Contract.hash(row.attachment_digest) then
                    job.unverified=job.unverified+1;job.urls={}
                end
            end
            local url=job.urls[job.url_index]
            if url then
                local reference=Contract.row_hash(row);job.url_index=job.url_index+1
                local delivered=false
                local called,started=pcall(worker.start,worker,function()
                    local store=Notes:new(job.db,host.client,'thoughts')
                    local function referenced()
                        if not valid() then return false end
                        local latest=store:read(id)
                        for _,item in ipairs(latest and latest.reviews or {}) do
                            if item.reviewId==row.reviewId and Contract.row_hash(item)==reference then return true end
                        end
                        return false
                    end
                    if not referenced() then return {error='changed'} end
                    local status,why=require('weread.lib.thought_image').prefetch(host.client,job.db,job.account,id,row.reviewId,url,
                        valid,referenced)
                    return status and {status=status} or {error=why}
                end,function(result)
                    if delivered then return end;delivered=true
                    if not valid() then if owner.image_bulk_context==job then M.cancel(host,owner) end;return end
                    if type(result)~='table' or result.status~='saved' and result.status~='cached' then finish('failed');return end
                    if result.status=='saved' then job.saved=job.saved+1 else job.cached=job.cached+1 end
                    later()
                end)
                if (not called or not started) and not delivered then finish('failed') end
                return
            end
            job.row_index=job.row_index+1;job.url_index=1;job.urls=nil
        end
        complete_book()
    end
    launch();return true
end

function M.clear(host,owner,is_current)
    if not is_current(host,owner) or owner.image_bulk_context or owner.bulk_context or owner.context then return false end
    local confirm
    confirm=require('ui/widget/confirmbox'):new{
        text=_('Clear saved thought and review images on this device? They will need to be downloaded again for offline viewing.'),
        ok_text=_('Clear images'),cancel_text=_('Cancel'),
        ok_callback=function()
            if not is_current(host,owner) or not Popup.current(owner.menu,confirm) then return end
            Popup.close(owner.menu)
            local job={account=owner.account,db=host.library_db};owner.image_bulk_context=job
            local guarded,gate=pcall(function() return require('weread.lib.native_position_guard'):new() end)
            if not guarded or not gate then owner.image_bulk_context=nil;host:showInfo(_('Could not clear saved images.'));return end
            job.gate=gate
            local function current()
                return owner.image_bulk_context==job and is_current(host,owner)
                    and job.gate and job.gate:valid() and host.library_db==job.db and job.db:accountKey()==job.account
            end
            host:showBusy(_('Clearing saved images…'),function() M.cancel(host,owner) end);job.dialog=host.busy_message
            local ok,worker=pcall(function() return require('weread.lib.memory_worker'):new{
                scheduler=UI,codec=host.client,max_bytes=65536,timeout=30} end)
            if not ok or not worker then M.cancel(host,owner);host:showInfo(_('Could not clear saved images.'));return end
            job.worker=worker
            local delivered=false
            local called,started=pcall(worker.start,worker,function()
                local count=require('weread.lib.thought_image_store'):new(job.db):clear(job.account,
                    function() return job.gate:valid() end)
                return count~=nil and {count=count} or {error='storage'}
            end,function(result)
                if delivered then return end;delivered=true
                if not current() then if owner.image_bulk_context==job then M.cancel(host,owner) end;return end
                local count=type(result)=='table' and result.count
                M.cancel(host,owner)
                if type(count)~='number' or count<0 or count%1~=0 or count>2147483647 then
                    host:showInfo(_('Could not clear saved images.'));return
                end
                if is_current(host,owner) then host:showTransientInfo(T(_('Cleared %1 saved images.'),tostring(count)),4) end
            end)
            if (not called or not started) and not delivered then M.cancel(host,owner);host:showInfo(_('Could not clear saved images.')) end
        end,
    }
    return Popup.show(owner.menu,confirm)
end
return M
