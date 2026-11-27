-- Preview and clear unused isolated E-Ink chapters in a cancellable worker.
local UIManager=require('ui/uimanager')
local Util=require('weread.lib.plugin_util')
local _,T=Util.tr,Util.T
local Cache=require('weread.lib.native_direct_cache')
local Model=require('weread.lib.native_direct_cleanup')
local M={}

local function size(bytes)
    if bytes<1024 then return string.format('%d B',bytes) end
    if bytes<1024*1024 then return string.format('%.1f KB',bytes/1024) end
    return string.format('%.1f MB',bytes/1024/1024)
end
local function safe_journals(host,account)
    if not host.library_db or not host.client or not host.offline_time or not host.offline_time.store
        or not host.readtime_coverage then return false end
    local ok,position,time=pcall(function()
        local position=require('weread.lib.native_position_store'):new(host.library_db,host.client):read()
        local time=require('weread.lib.readtime_transfer_store'):new{coverage=host.readtime_coverage,
            ledger=host.offline_time.store,codec=host.client}:read(account)
        return position,time
    end)
    return ok and position and position.phase=='idle' and time and not time.record or false
end
local function active_document(host,root)
    local reader=package.loaded['apps/reader/readerui']
    local instance=reader and reader.instance
    for _,doc in ipairs({host.ui and host.ui.document or false,instance and instance.document or false}) do
        local path=doc and doc.file
        if type(path)=='string' and path:sub(1,#root+1)==root..'/' then return true end
    end
    return false
end
function M.cancel(host)
    local ctx=host._native_cleanup;if not ctx then return end
    host._native_cleanup=nil
    if ctx.watch then UIManager:unschedule(ctx.watch);ctx.watch=nil end
    if host._native_cleanup_worker then host._native_cleanup_worker:cancel() end
    local dialog=ctx.dialog;ctx.dialog=nil;if dialog then UIManager:close(dialog) end
    if ctx.busy and host.busy_message==ctx.busy then host:closeBusy() end
    if ctx.mutating then
        local function owner_current()
            return not host._weread_suspended and host.library_db and host.library_db:accountKey()==ctx.account
                and host.settings:auth_scope_matches(ctx.scope)
        end
        if owner_current() then pcall(Cache.repair_presence,host.settings,ctx.scope.vid,ctx.id,owner_current) end
    end
end

function M.start(host,book,view)
    if host._native_cleanup or host._native_direct_reading or host._native_home_resume
        or host._book_detail_view~=view then return false end
    local id=require('weread.lib.native_position_protocol').id(book.book_id or book.bookId)
    local scope=host.settings:get_auth_scope()
    local account=host.library_db and host.library_db:accountKey()
    local root=id and scope and Cache.book_directory(host.settings,scope.vid,id)
    if not root or not account or account~=require('weread.lib.native_position_contract').account_key(scope.vid)
        or not host.settings:auth_scope_matches(scope) or active_document(host,root) then
        host:showInfo(_('Could not inspect E-Ink cache. Close the book and try again.'));return false
    end
    local ctx={view=view,scope=scope,account=account,root=root,book=book,id=id,
        session=host._reader_session_gen,epoch=host.discovery_epoch or 0,document=host.ui and host.ui.document}
    host._native_cleanup=ctx
    local function owner_current()
        return not host._weread_suspended and not host._native_direct_reading
            and not host._native_home_resume
            and host._book_detail_view==view and host._reader_session_gen==ctx.session
            and (host.discovery_epoch or 0)==ctx.epoch and (host.ui and host.ui.document)==ctx.document
            and host.library_db:accountKey()==account and host.settings:auth_scope_matches(scope)
            and not active_document(host,root)
    end
    local function current() return host._native_cleanup==ctx and owner_current() end
    ctx.watch=function()
        if host._native_cleanup~=ctx then return end
        if not current() then M.cancel(host);return end
        UIManager:scheduleIn(.2,ctx.watch)
    end
    UIManager:scheduleIn(.2,ctx.watch)
    local function refresh()
        if not owner_current() then return end
        Cache.repair_presence(host.settings,scope.vid,id,owner_current)
        if host.refreshShelfCacheIndicators then host:refreshShelfCacheIndicators() end
    end
    local function fail(message)
        if host._native_cleanup~=ctx then return end
        local show=current();M.cancel(host);if show then refresh() end
        if show then host:showInfo(_(message or 'Could not inspect E-Ink cache. Close the book and try again.')) end
    end
    local function busy(label)
        host:showBusy(_(label),function()
            if host._native_cleanup~=ctx then return end
            local show=current();M.cancel(host);if show then refresh() end
            if show then host:showInfo(_('E-Ink cleanup stopped. Some chapters may have been cleared; reading records are kept.')) end
        end)
        ctx.busy=host.busy_message
    end
    local function close_busy()
        if ctx.busy and host.busy_message==ctx.busy then host:closeBusy() end
        ctx.busy=nil
    end
    if not host._native_cleanup_worker then
        local ok,worker=pcall(function() return require('weread.lib.memory_worker'):new{
            scheduler=UIManager,codec=host.client,max_bytes=8*1024*1024,timeout=300} end)
        if not ok then fail();return false end
        host._native_cleanup_worker=worker
    end
    local function with_lease(callback)
        local lease=Cache.acquire(host.settings,scope.vid,id)
        if not lease then return {error='busy'} end
        local ok,result=pcall(callback,lease)
        lease:release()
        return ok and result or {error='storage'}
    end
    local function start_cleanup(preview)
        if not current() then M.cancel(host);return end
        ctx.mutating=true
        busy('Clearing unused E-Ink chapters…\nTap or press a key to stop.')
        local started=host._native_cleanup_worker:start(function()
            return with_lease(function(lease)
                if not current() or not safe_journals(host,account) then return {error='changed'} end
                local plan=Model.scan(host.settings,scope.vid,id,account,host.client,current,lease)
                if not plan or not Model.same_plan(preview,plan) then return {error='changed'} end
                for index=1,#plan.items do
                    if not current() or not safe_journals(host,account) then return {error='stopped'} end
                    local ok=Model.step(host.settings,host.client,plan,lease,index,current)
                    if not ok then return {error='stopped'} end
                end
                Cache.repair_presence(host.settings,scope.vid,id,current)
                return {done=true,count=#plan.items}
            end)
        end,function(result)
            if not current() then M.cancel(host);return end
            if not result or not result.done then
                fail('E-Ink cleanup stopped. Some chapters may have been cleared; reading records are kept.');return
            end
            close_busy();M.cancel(host)
            if host.refreshShelfCacheIndicators then host:refreshShelfCacheIndicators() end
            UIManager:close(view)
            local latest=host.settings.get_book and host.settings:get_book(id)
                or host.settings:get('books',{})[id] or book
            host:showBookMenu(latest)
            host:showInfo(T(_('Cleared %1 unused E-Ink chapters.'),tostring(result.count)))
        end)
        if not started then fail() end
    end
    busy('Checking saved E-Ink chapters…')
    local started=host._native_cleanup_worker:start(function()
        return with_lease(function(lease)
            if not current() or not safe_journals(host,account) then return {error='busy'} end
            local plan=Model.scan(host.settings,scope.vid,id,account,host.client,current,lease)
            return plan and {plan=plan} or {error='storage'}
        end)
    end,function(result)
        if not current() then M.cancel(host);return end
        close_busy()
        local plan=result and result.plan
        if not plan then fail();return end
        if #plan.items==0 then
            M.cancel(host)
            host:showInfo(T(_('No unused E-Ink chapters can be cleared. %1 protected or unverified copies were kept.'),tostring(plan.protected)))
            return
        end
        local dialog
        dialog=require('ui/widget/confirmbox'):new{
            text=T(_('Clear %1 unused E-Ink chapters (%2)?\n%3 protected or unverified copies will be kept. Reading records and cloud data are not changed.'),
                tostring(#plan.items),size(plan.bytes),tostring(plan.protected)),
            ok_text=_('Clear'),keep_dialog_open=true,
            cancel_callback=function() if host._native_cleanup==ctx then M.cancel(host) end end,
            ok_callback=function()
                if not current() then M.cancel(host);return end
                ctx.dialog=nil;UIManager:close(dialog);start_cleanup(plan)
            end,
        }
        ctx.dialog=dialog
        local closed=dialog.onCloseWidget
        dialog.onCloseWidget=function(widget,...)
            if host._native_cleanup==ctx and ctx.dialog==widget then ctx.dialog=nil;M.cancel(host) end
            if closed then return closed(widget,...) end
        end
        UIManager:show(dialog)
    end)
    if not started then fail();return false end
    return true
end
return M
