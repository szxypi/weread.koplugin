-- Detached, one-shot native chapter upload. Only a bounded viewport snapshot
-- crosses the close boundary; the background worker never accesses ReaderUI.
local UI=require('ui/uimanager')
local Context=require('weread.lib.source_context')
local Identity=require('weread.lib.book_file_identity')
local Access=require('weread.lib.native_read_access')
local Currentness=require('weread.lib.source_currentness')
local Contract=require('weread.lib.native_position_contract')
local P=require('weread.lib.native_position_protocol')
local State=require('weread.lib.native_cloud_state')
local _=require('weread.lib.plugin_util').tr
local M={};local active={}
local function copy(value)
    if type(value)~='table' then return value end
    local out={};for key,item in pairs(value) do out[key]=copy(item) end;return out
end
local function namespace(host) return host.settings and (host.settings.data_dir or host.settings) end
local function enabled(host)
    local c=host.settings:get('sync',{});return type(c)=='table' and c.upload_on_close==true
end
local function online(host)
    return host.isNetworkConnected and host:isNetworkConnected()
        or not host.isNetworkConnected and host.isNetworkOnline and host:isNetworkOnline()
end
local function drop(entry,message)
    if active[entry.namespace]~=entry then return end
    active[entry.namespace]=nil
    if entry.task then UI:unschedule(entry.task);entry.task=nil end
    if entry.worker then entry.worker:cancel() end
    if entry.service then entry.service:cancel() end
    entry.input=nil
    if message and entry.host.showTransientInfo then entry.host:showTransientInfo(_(message),3) end
end
function M.cancel(host)
    local entry=active[namespace(host)];if entry then drop(entry) end
end
local function current(entry)
    local h=entry.host;local age=os.time()-entry.frozen
    return active[entry.namespace]==entry and age>=0 and age<=90 and not h._weread_suspended
        and enabled(h) and online(h) and h.settings:auth_scope_matches(entry.scope)
        and h.library_db and h.library_db:accountKey()==entry.account
        and Access.matches(h.settings,entry.native) and Currentness.matches(h.settings,entry.web)
end
function M.freeze(host)
    local timer=host._native_direct_interval;local c=timer and timer.context
    if not c or not enabled(host) or not timer:access_current() or not online(host) or timer.attempt
        or host._native_direct_position or host._offline_time_transfer_lock or host.busy_message or not host.library_db
        or type(host.library_db.open)~='function' then return nil end
    local location=Context.location(c.document,c.reader.view and c.reader.view.view_mode or 'page')
    if not location or Context.same_location(location,c.location) then return nil end
    local function live()
        return timer:access_current() and not host._native_direct_position and not host.busy_message
            and Context.same_location(location,Context.location(c.document,c.reader.view and c.reader.view.view_mode or 'page'))
    end
    local input=Context.capture(c.document,c.entry.book_id,location,{
        viewport_height=host.progress_sync and host.progress_sync.get_viewport_height and host.progress_sync.get_viewport_height(),
        is_current=live,metadata_resolver=function(document,book_id,render_path)
            if document~=c.document or book_id~=c.entry.book_id or render_path~='OEBPS/text/chapter.xhtml' then return nil end
            local actual=Identity.read_document(document,book_id)
            if actual.file_id~=c.entry.file_id or actual.book_id~=c.entry.book_id
                or actual.book_version~=c.entry.book_version then return nil end
            return {metadata=c.entry.file_id..c.entry.source_sha256,identity=actual,chapter_uid=c.entry.chapter_uid}
        end})
    if not input or input.error or not live() then return nil end
    local key=namespace(host);if not key then return nil end
    if active[key] then drop(active[key]) end
    local token={};active[key]={host=host,namespace=key,token=token,frozen=os.time(),input=input,file=c.file,
        scope=c.scope,account=c.account,native=c.native,web=c.web,entry=copy(c.entry),baseline=copy(c.baseline)}
    return token
end
local function metadata(entry,value)
    local p=type(value)=='table' and value.position;local e=entry.entry;local b=entry.baseline
    if not require('weread.lib.native_direct_position').matches_point(e,p) or value.dispatch_authorized~=false then return nil end
    local m={book_id=e.book_id,before=value.before,desired=value.desired,counts=value.counts,version=value.version,
        shelf_sha256=value.shelf_sha256,source_sha256=value.source_sha256,file_id=value.file_id,basis=value.basis}
    if not Contract.valid(m) or m.basis~=p.basis or m.basis~=b.basis or not State.equal(m.before,b.position)
        or not P.same_counts(m.counts,b.counts) or m.version~=b.version or m.shelf_sha256~=b.shelf_sha256
        or m.source_sha256~=b.source_sha256 or m.file_id~=b.file_id
        or m.desired.book_id~=p.book_id or m.desired.chapter_uid~=p.chapter_uid
        or m.desired.chapter_idx~=p.chapter_idx or m.desired.chapter_offset~=p.chapter_offset
        or m.desired.raw_percent~=m.before.raw_percent then return nil end
    return m
end
function M.start(host,token)
    local entry=active[namespace(host)]
    if not entry or entry.host~=host or entry.token~=token or entry.started or not current(entry) then
        if entry and entry.token==token then drop(entry) end;return false
    end
    entry.started=true
    local function failed() drop(entry,'Could not sync the closed chapter. Your local position is kept.') end
    local ok,service=pcall(function() return require('weread.lib.native_position_service'):new{
        settings=host.settings,client=host.client,library=host.library_db,scheduler=UI} end)
    if not ok or not service then failed();return false end
    entry.service=service
    local read_ok,pending,reason=pcall(service.pending,service)
    if not read_ok or pending or reason then drop(entry,'A previous position sync needs review. Choose sync again.');return false end
    local worker_ok,worker=pcall(function() return require('weread.lib.memory_worker'):new{
        scheduler=UI,codec=host.client,max_bytes=65536,timeout=80} end)
    if not worker_ok or not worker then failed();return false end
    entry.worker=worker
    local launch
    launch=function()
        if not current(entry) then drop(entry);return end
        local called,started=pcall(worker.start,worker,function()
            local result,why=require('weread.lib.native_direct_upload_preview').prepare(host.client,host.settings,
                entry.entry,entry.file,entry.input,entry.native,entry.web,function() return current(entry) end)
            return result and {preview=result} or {error=why or 'unavailable'}
        end,function(result)
            if not current(entry) then drop(entry);return end
            local selected=type(result)=='table' and metadata(entry,result.preview)
            if not selected then failed();return end
            if not State.none(selected.before) and selected.before.chapter_uid==selected.desired.chapter_uid
                and selected.before.chapter_idx==selected.desired.chapter_idx
                and selected.before.chapter_offset==selected.desired.chapter_offset then drop(entry);return end
            if not entry.checked then entry.checked=copy(selected);launch();return end
            if not Contract.same(entry.checked,selected) then failed();return end
            local invoked,sent=pcall(service.start,service,selected,function() return current(entry) end,function(out,receipt)
                if not current(entry) then drop(entry);return end
                if out.kind=='confirmed' and receipt and service:accept(receipt) then drop(entry);return end
                drop(entry,out.attempted and 'Automatic position sync needs review. Open sync to check it.'
                    or 'Could not sync the closed chapter. Your local position is kept.')
            end)
            if not invoked or not sent then failed() end
        end)
        if not called or not started then failed() end
    end
    entry.task=function() entry.task=nil;launch() end;UI:scheduleIn(0.1,entry.task)
    return true
end
return M
