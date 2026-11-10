-- Confirm an owned cache snapshot, then remove content cooperatively under leases.
local Model=require('weread.lib.book_cache_cleanup')
local Store=require('weread.lib.book_store')
local Content=require('weread.lib.content')
local UIManager=require('ui/uimanager')
local Util=require('weread.lib.plugin_util')
local _,T=Util.tr,Util.T
local M={}
local function size(bytes)
    if bytes<1024 then return string.format('%d B',bytes) end
    if bytes<1024*1024 then return string.format('%.1f KB',bytes/1024) end
    return string.format('%.1f MB',bytes/1024/1024)
end
local function scope(host)
    local reader=package.loaded['apps/reader/readerui']
    local instance=reader and reader.instance
    return {account=host.library_db and host.library_db:accountKey() or false,
        epoch=host.discovery_epoch or 0,session=host._reader_session_gen or false,
        menu=host.cache_menu or false,detail=host._book_detail_view or false,
        document=host.ui and host.ui.document or false,
        reader=instance and instance.document or false,cache=host.settings.cache_dir or false}
end
local function active(host,root,id)
    local now=scope(host)
    for _i,doc in ipairs({now.document,now.reader}) do
        local path=doc and doc.file
        if type(path)=='string' and path:sub(1,#root+1)==root..'/' then return true end
    end
    local downloader=host.downloader
    if downloader then
        for _i,job in ipairs({downloader._active_job or false,downloader._pending_start or false,
            downloader._scheduled_start and downloader._scheduled_start.pending or false}) do
            local book=job and job.book
            if book and tostring(book.book_id or book.bookId)==tostring(id) then return true end
        end
    end
    return false
end
function M.current(host,job)
    local now=scope(host)
    for key,value in pairs(job.owner) do if now[key]~=value then return false end end
    if job.auth and not host.settings:auth_scope_matches(job.auth) then return false end
    local books=host.settings:get('books',{})
    for _i,item in ipairs(job.items) do
        local book=books[item.id]
        if not book or Content.book_resolved_dir(host.settings,item.id,book)~=item.root or active(host,item.root,item.id) then return false end
    end
    return true
end
function M.prepare(host,ids)
    local job={owner=scope(host),items={},index=1,files=0,bytes=0}
    if host.settings.get_auth_scope then job.auth=host.settings:get_auth_scope() end
    local books=host.settings:get('books',{});local seen={}
    for _i,id in ipairs(ids) do
        local book=books[id]
        if not book then return nil,'changed' end
        local root=Content.book_resolved_dir(host.settings,id,book):gsub('/+$','')
        if seen[root] or active(host,root,id) then return nil,'busy' end;seen[root]=true
        local info=require('libs/libkoreader-lfs').symlinkattributes(root)
        if info then
            local ok,plan=pcall(Model.scan,root,id)
            if not ok then return nil,'unavailable' end
            job.items[#job.items+1]={id=id,root=root,book=book,preview=plan}
            job.bytes=job.bytes+plan.bytes;job.files=job.files+plan.files
        end
    end
    return job
end
local function release(job)
    for _i,item in ipairs(job.items) do if item.lease then item.lease:release();item.lease=nil end end
end
function M.begin(host,job)
    if not M.current(host,job) then return false,'changed' end
    for _i,item in ipairs(job.items) do
        local called,lease,plan=pcall(Model.acquire,item.root,item.id)
        if not called or not lease then release(job);return false,'busy' end
        item.lease=lease
        if not Model.same_plan(item.preview,plan) then release(job);return false,'changed' end
        item.deletion={plan=plan,lease=lease,files=0,bytes=0}
    end
    return true
end
local function remove_collection(host,job,item)
    local path=item.book.cached_full_book or item.book.cached_file
    if not path or Util.file_exists(path) then return end
    local ok=pcall(function()
        local collection=require('readcollection');local name=host.settings.collection_name or 'weread'
        if not collection.coll then collection:_read() end
        collection:removeItem(path,name,#job.items>1)
        if #job.items>1 then job.collection_dirty=true end
    end)
    if not ok then job.failed=true end
end
local function finalize(host,job,item,complete)
    if not item or item.finalized or not item.deletion then return true end
    item.finalized=true
    local ok=true
    if item.deletion.files>0 then
        local lfs=require('libs/libkoreader-lfs')
        local now=lfs.symlinkattributes(item.root);local before=item.deletion.plan.owner
        if item.lease and item.lease:owns() and now and now.dev==before.dev and now.ino==before.ino then
            local called,patched=pcall(Store.clear_downloads,host.settings,item.id,{cache_dir=item.root},item.deletion.plan.metadata)
            ok=called and patched==true
            remove_collection(host,job,item)
        else ok=false end
    end
    if complete then
        local called,cleared=pcall(host.clearBookAnnotationData,host,item.id,item.book)
        ok=called and cleared==true and ok
    end
    if not ok then job.failed=true end
    return ok
end
function M.stop(host,job)
    -- Never rewrite reading_state.json, including after cancellation or an error.
    finalize(host,job,job.items[job.index],false)
    release(job)
    if job.collection_dirty then
        local ok=pcall(function()
            require('readcollection'):write({[host.settings.collection_name or 'weread']=true})
        end)
        if not ok then job.failed=true end
        job.collection_dirty=nil
    end
end
function M.step(host,job)
    if not M.current(host,job) then return false,'changed' end
    local item=job.items[job.index];if not item then return true,'done' end
    local good,ok,reason=pcall(Model.step,item.deletion,32)
    if not good or not ok then return false,'stopped' end
    if reason=='done' then
        if not finalize(host,job,item,true) then return false,'stopped' end
        job.index=job.index+1
    end
    return true,job.index>#job.items and 'done' or 'continue'
end
function M.run(host,ids)
    local job,reason=M.prepare(host,ids);if not job then return false,reason end
    local ok;ok,reason=M.begin(host,job)
    while ok and reason~='done' do ok,reason=M.step(host,job) end
    M.stop(host,job)
    host:refreshShelfCacheIndicators()
    return ok and not job.failed,reason
end
local function failure(host)
    host:showInfo(_('Could not clear the cache. Close the book and wait for downloads or recovery to finish, then reopen cache management. Reading records are kept.'))
end
local function end_ui(host,job,ok)
    if host.book_cache_cleanup_job~=job then return end
    host.book_cache_cleanup_job=nil
    M.stop(host,job)
    if host.busy_message==job.busy then host:closeBusy() end
    host:refreshShelfCacheIndicators()
    if not M.current(host,job) then return end
    if ok and not job.failed then
        if job.on_cleared then job.on_cleared();host:showTransientInfo(_('Cache cleared'))
        else host:refreshCacheManagement(_('Cache cleared')) end
    else
        host:showInfo(_('Cache cleanup stopped. Some files may have been removed. Reading positions, pending sync records, and local notes are kept.'))
    end
end
function M.cancel(host)
    local job=host.book_cache_cleanup_job
    if not job then return end
    host.book_cache_cleanup_job=nil
    if job.dialog then UIManager:close(job.dialog);job.dialog=nil end
    M.stop(host,job)
    if host.busy_message==job.busy then host:closeBusy() end
end
function M.show(host,ids,title,on_cleared)
    if host.book_cache_cleanup_job then return false end
    local ok,job=pcall(M.prepare,host,ids)
    if not ok or not job then failure(host);return false end
    job.on_cleared=on_cleared;host.book_cache_cleanup_job=job
    local text=title and T(_('Clear cache for "%1"?'),title) or _('Clear selected caches?')
    text=text..'\n\n'..T(_('%1 downloaded files (%2) and cached cloud annotations will be removed.\nReading positions, pending sync records, and local notes are kept.'),
        job.files,size(job.bytes))
    local dialog
    dialog=require('ui/widget/confirmbox'):new{text=text,ok_text=_('Clear'),keep_dialog_open=true,
        cancel_callback=function() if host.book_cache_cleanup_job==job then M.cancel(host) end end,
        ok_callback=function()
            if host.book_cache_cleanup_job~=job then return end
            job.dialog=nil;UIManager:close(dialog)
            local started=M.begin(host,job)
            if not started then host.book_cache_cleanup_job=nil;M.stop(host,job);failure(host);return end
            host:showBusy(_('Clearing cache…\nTap or press a key to stop.'),function() end_ui(host,job,false) end)
            job.busy=host.busy_message
            local function step()
                if host.book_cache_cleanup_job~=job then return end
                local good,more,reason=pcall(M.step,host,job)
                if not good or not more then end_ui(host,job,false)
                elseif reason=='done' then end_ui(host,job,true)
                else UIManager:scheduleIn(.1,step) end
            end
            UIManager:scheduleIn(.1,step)
        end}
    job.dialog=dialog
    local on_close=dialog.onCloseWidget
    dialog.onCloseWidget=function(instance,...)
        if host.book_cache_cleanup_job==job and job.dialog==instance then M.cancel(host) end
        if on_close then return on_close(instance,...) end
    end
    UIManager:show(dialog)
    return true
end
return M
