-- Continue a one-use cloud target after opening its native chapter.
local UI=require('ui/uimanager')
local Access=require('weread.lib.native_read_access')
local Cache=require('weread.lib.native_direct_cache')
local Cloud=require('weread.lib.native_direct_cloud')
local Context=require('weread.lib.source_context')
local Currentness=require('weread.lib.source_currentness')
local Identity=require('weread.lib.book_file_identity')
local P=require('weread.lib.native_position_protocol')
local _=require('weread.lib.plugin_util').tr
local M={}
local function location(reader,doc)
    return Context.location(doc,reader.view and reader.view.view_mode)
end
function M.cancel(host)
    local incoming=host._native_direct_cloud_incoming;host._native_direct_cloud_incoming=nil
    if incoming and incoming.task then UI:unschedule(incoming.task) end
    local ctx=host._native_direct_cloud_open;host._native_direct_cloud_open=nil
    if not ctx then return end
    if ctx.task then UI:unschedule(ctx.task) end
    if host._native_direct_cloud_open_worker then host._native_direct_cloud_open_worker:cancel() end
    if ctx.busy and host.busy_message==ctx.busy then host:closeBusy() end
    ctx.thread,ctx.anchor=nil,nil
end
function M.on_view_changed(host)
    local incoming=host._native_direct_cloud_incoming
    if incoming and (host.ui~=incoming.reader or incoming.reader.document~=incoming.document
        or not Context.same_location(incoming.location,location(incoming.reader,incoming.document))) then M.cancel(host);return end
    local ctx=host._native_direct_cloud_open
    if ctx and not ctx.committing and ctx.current and not ctx.current() then M.cancel(host) end
end
local function message(reason)
    if reason=='auth_expired' then return 'E-Ink authorization expired. Please authorize again.' end
    if reason=='web_expired' then return 'WeRead login expired. Please sign in again and retry.' end
    if reason=='rate_limited' then return 'WeRead is limiting requests. Please try again later.' end
    if reason=='cloud_changed' then return 'The cloud position changed during the check. Your current page is kept.' end
    return 'The cloud position could not be located in this chapter. Your current page is kept.'
end
function M.start(host,entry,wanted,native,web)
    local reader=host.ui;local doc=reader and reader.document;local scope=host.settings:get_auth_scope()
    if not reader or not doc or not scope or not host.settings:auth_scope_matches(scope) or not Cloud.valid_target(wanted)
        or not Cache.valid_entry(entry,wanted.book_id,scope.vid) or entry.chapter_uid~=wanted.chapter_uid
        or entry.chapter_idx~=wanted.chapter_idx or not Access.matches(host.settings,native)
        or not Currentness.matches(host.settings,web) then return false end
    local identity=Identity.read_document(doc,wanted.book_id);local initial=location(reader,doc)
    if not initial or identity.book_id~=wanted.book_id or identity.file_id~=entry.file_id
        or identity.book_version~=entry.book_version then return false end
    M.cancel(host)
    local ctx={reader=reader,document=doc,file=doc.file,scope=scope,session=host._reader_session_gen or 0,
        account=host.library_db and host.library_db:accountKey(),identity=identity,location=initial,
        native=native,web=web,entry=entry,target=wanted,started=os.time()}
    host._native_direct_cloud_open=ctx
    local function current()
        local age=os.time()-ctx.started
        if host._native_direct_cloud_open~=ctx or age<0 or age>180 or host.ui~=reader or reader.document~=doc
            or doc.file~=ctx.file or (host._reader_session_gen or 0)~=ctx.session
            or not host.settings:auth_scope_matches(scope) or host.library_db and host.library_db:accountKey()~=ctx.account
            or not Access.matches(host.settings,native) or not Currentness.matches(host.settings,web) then return false end
        local actual=Identity.read_document(doc,wanted.book_id)
        return actual.file_id==identity.file_id and actual.book_id==wanted.book_id and actual.book_version==identity.book_version
            and Context.same_location(initial,location(reader,doc))
    end
    ctx.current=current
    local function fail(reason)
        if host._native_direct_cloud_open~=ctx then return end
        local visible=current();M.cancel(host)
        if visible then host:showInfo(_(message(reason))) end
    end
    host:showBusy(_('Locating cloud reading position...'),function() M.cancel(host) end);ctx.busy=host.busy_message
    if not host._native_direct_cloud_open_worker then
        local ok,worker=pcall(function() return require('weread.lib.memory_worker'):new{
            scheduler=UI,codec=host.client,max_bytes=65536,timeout=180} end)
        if not ok then fail();return false end
        host._native_direct_cloud_open_worker=worker
    end
    local worker=host._native_direct_cloud_open_worker
    local function run(callback)
        local ok,started=pcall(worker.start,worker,function()
            local function active()
                return host.settings:auth_scope_matches(scope) and Access.matches(host.settings,native)
                    and Currentness.matches(host.settings,web)
            end
            local result,reason=Cloud.prepare_destination(host.client,host.settings,entry,ctx.file,native,web,active,wanted)
            return result and {value=result} or {error=reason or 'unavailable'}
        end,function(result)
            if host._native_direct_cloud_open~=ctx then return end
            if not current() then M.cancel(host);return end
            local value=type(result)=='table' and result.value
            local anchor=type(value)=='table' and value.anchor
            if type(anchor)~='table' or not Cloud.same_target(value.target,wanted)
                or anchor.co~=wanted.chapter_offset or anchor.basis~='filtered_xhtml_utf16'
                or anchor.point_unit~='unicode_scalars' or type(anchor.text)~='string' or #anchor.text<12 or #anchor.text>8192
                or not P.integer(anchor.point_offset,0,8192) then
                fail(type(result)=='table' and result.error);return
            end
            callback(anchor)
        end)
        if not ok or not started then fail();return false end
        return true
    end
    local function locate(anchor)
        ctx.anchor=anchor
        ctx.thread=coroutine.create(function()
            local first,last=true,os.clock()
            local index=require('weread.lib.source_dom').open_direct_prepared(doc,entry.book_id,entry.chapter_uid,identity,{
                is_current=current,yield=function()
                    if first or os.clock()-last>=0.02 then first=false;coroutine.yield();last=os.clock() end
                end,
            })
            return index and index:locate_anchor(anchor) or nil
        end)
        local step
        step=function()
            ctx.task=nil
            if not current() then M.cancel(host);return end
            local ok,point=coroutine.resume(ctx.thread)
            if not ok then fail();return end
            if coroutine.status(ctx.thread)~='dead' then ctx.task=step;UI:scheduleIn(0.1,step);return end
            ctx.thread=nil
            if type(point)~='table' or point.co~=wanted.chapter_offset or point.book_id~=entry.book_id
                or point.chapter_uid~=entry.chapter_uid or point.file_id~=entry.file_id
                or point.render_path~='OEBPS/text/chapter.xhtml' or type(point.xpointer)~='string'
                or #point.xpointer>4096 or not current() then fail();return end
            run(function(fresh)
                for _,key in ipairs({'co','text','point_offset','point_unit','basis'}) do
                    if fresh[key]~=anchor[key] then fail('cloud_changed');return end
                end
                if not current() then M.cancel(host);return end
                local geometry=require('weread.lib.reader_position');ctx.committing=true
                local applied=geometry.goto_xpointer(reader,point.xpointer);ctx.committing=false
                local frame=geometry.snapshot(doc,reader.view and reader.view.view_mode,
                    host.progress_sync and host.progress_sync.get_viewport_height and host.progress_sync.get_viewport_height())
                local verified=applied and geometry.contains_anchor(doc,frame,point.xpointer)
                if host._native_direct_cloud_open~=ctx then return end
                M.cancel(host)
                host:showInfo(_(verified and 'Opened the cloud reading position in this chapter.'
                    or 'Could not confirm the cloud position. Please check the current page.'))
            end)
        end
        ctx.task=step;UI:scheduleIn(0.1,step)
    end
    return run(locate)
end
-- The after-open callback fires before the new ReaderUI is installed. Defer
-- without assuming the destination page remains unchanged in the meantime.
function M.receive(host,entry,wanted,native,web)
    M.cancel(host)
    local reader=host.ui;local doc=reader and reader.document
    local at=doc and location(reader,doc)
    if not at then return false end
    local incoming={reader=reader,document=doc,location=at,session=host._reader_session_gen or 0,started=os.time()}
    incoming.task=function()
        if host._native_direct_cloud_incoming~=incoming then return end
        host._native_direct_cloud_incoming=nil
        local age=os.time()-incoming.started
        if age<0 or age>120 or host.ui~=reader or reader.document~=doc or doc.file==nil
            or (host._reader_session_gen or 0)~=incoming.session or not Context.same_location(at,location(reader,doc))
            or not Access.matches(host.settings,native) or not Currentness.matches(host.settings,web) then return end
        M.start(host,entry,wanted,native,web)
    end
    host._native_direct_cloud_incoming=incoming;UI:scheduleIn(0.1,incoming.task)
    return true
end
return M
