-- Navigate untrusted online search results in native chapters. All source
-- verification runs in workers, and each reader handoff is one-use.
local UI=require('ui/uimanager')
local Cache=require('weread.lib.native_direct_cache')
local Resolver=require('weread.lib.native_direct_online_search_target')
local NativeAccess=require('weread.lib.native_read_access')
local WebAccess=require('weread.lib.source_currentness')
local Context=require('weread.lib.source_context')
local Identity=require('weread.lib.book_file_identity')
local Path=require('weread.lib.native_direct_path')
local Navigation=require('weread.ui.my_mark_navigation')
local _=require('weread.lib.plugin_util').tr
local M={}
local function location(reader,doc) return Context.location(doc,reader.view and reader.view.view_mode) end
local function account(host) return host.library_db and host.library_db:accountKey() end
local function same_anchor(a,b)
    if type(a)~='table' or type(b)~='table' then return false end
    for _,key in ipairs({'co','text','point_offset','point_unit','basis'}) do if a[key]~=b[key] then return false end end
    return true
end
local function message(reason)
    if reason=='auth_expired' then return 'E-Ink authorization expired. Please authorize again.' end
    if reason=='web_expired' then return 'WeRead login expired. Please sign in again and retry.' end
    if reason=='rate_limited' then return 'WeRead is limiting requests. Please try again later.' end
    if reason=='not_entitled' then return 'The cloud chapter is not available to this account.' end
    if reason=='catalog_changed' then return 'The chapter list changed. Please open it again.' end
    return 'Could not locate this search result in the original text. Try downloading the chapter again.'
end
local function accesses(host,native,web,scope,owner)
    return host.settings:auth_scope_matches(scope) and account(host)==owner
        and NativeAccess.matches(host.settings,native) and WebAccess.matches(host.settings,web)
end
function M.cancel(host)
    local incoming=host._native_online_search_incoming;host._native_online_search_incoming=nil
    if incoming and incoming.task then UI:unschedule(incoming.task) end
    local ctx=host._native_online_search_open;host._native_online_search_open=nil
    if not ctx then return end
    if ctx.task then UI:unschedule(ctx.task) end
    if ctx.worker then ctx.worker:cancel() end
    if ctx.busy and host.busy_message==ctx.busy then host:closeBusy() end
    ctx.thread=nil
end
function M.on_view_changed(host)
    local incoming=host._native_online_search_incoming
    if incoming and (host.ui~=incoming.reader or incoming.reader.document~=incoming.document
        or not Context.same_location(incoming.location,location(incoming.reader,incoming.document))) then M.cancel(host);return end
    local ctx=host._native_online_search_open
    if ctx and not ctx.committing and ctx.current and not ctx.current() then M.cancel(host) end
    local owner=host._book_search_owner
    if owner and owner.native_entry and owner.navigation and owner.navigation.current
        and not owner.navigation.current() then Navigation.cancel(host,owner) end
end
local function book(host,id)
    local saved=host.settings:get_book(id) or {}
    if type(saved)~='table' then saved={} end
    local function safe(value)
        return type(value)=='string' and #value<=2048 and not value:find('[%z%c]')
            and require('weread.lib.protocol').utf8_substr(value,#value)==value and value or ''
    end
    return {book_id=id,title=safe(saved.title),author=safe(saved.author)}
end
function M.receive(host,entry,hit,native,web,scope,owner,anchor)
    M.cancel(host)
    local reader=host.ui;local doc=reader and reader.document;local at=doc and location(reader,doc)
    if not at or not Cache.valid_entry(entry,entry and entry.book_id,scope.vid)
        or not accesses(host,native,web,scope,owner) then return false end
    local incoming={reader=reader,document=doc,location=at,session=host._reader_session_gen or 0,started=os.time()}
    incoming.task=function()
        if host._native_online_search_incoming~=incoming then return end
        host._native_online_search_incoming=nil
        local age=os.time()-incoming.started
        if age<0 or age>120 or host.ui~=reader or reader.document~=doc or (host._reader_session_gen or 0)~=incoming.session
            or not Context.same_location(at,location(reader,doc)) or not accesses(host,native,web,scope,owner) then return end
        M.open(host,entry,hit,native,web,scope,owner,anchor)
    end
    host._native_online_search_incoming=incoming;UI:scheduleIn(.1,incoming.task);return true
end
function M.open(host,entry,hit,native,web,scope,owner,expected)
    local reader=host.ui;local doc=reader and reader.document;local at=doc and location(reader,doc)
    if not at or not Cache.valid_entry(entry,entry and entry.book_id,scope.vid)
        or not accesses(host,native,web,scope,owner) then return false end
    local identity=Identity.read_document(doc,entry.book_id)
    if identity.book_id~=entry.book_id or identity.book_version~=entry.book_version or identity.file_id~=entry.file_id then return false end
    M.cancel(host)
    local ctx={reader=reader,document=doc,file=doc.file,scope=scope,session=host._reader_session_gen or 0,
        account=owner,location=at,started=os.time()};host._native_online_search_open=ctx
    local function current()
        local age=os.time()-ctx.started
        return host._native_online_search_open==ctx and age>=0 and age<=180 and host.ui==reader and reader.document==doc
            and doc.file==ctx.file and (host._reader_session_gen or 0)==ctx.session
            and accesses(host,native,web,scope,owner) and Context.same_location(at,location(reader,doc))
    end
    ctx.current=current
    local function fail(reason)
        if host._native_online_search_open~=ctx then return end
        local live=current();M.cancel(host);if live then host:showInfo(_(message(reason))) end
    end
    host:showBusy(_('Locating search result…'),function() M.cancel(host) end);ctx.busy=host.busy_message
    local ok,worker=pcall(function() return require('weread.lib.memory_worker'):new{
        scheduler=UI,codec=host.client,max_bytes=1024*1024,timeout=180} end)
    if not ok then fail();return false end;ctx.worker=worker
    local function check(done)
        local called,started=pcall(worker.start,worker,function()
            local target,why=Resolver.resolve(host.client,host.settings,entry,ctx.file,hit,native,web,
                function() return host.settings:auth_scope_matches(scope) end,false,book(host,entry.book_id))
            return target and {target=target} or {error=why}
        end,function(value)
            if host._native_online_search_open~=ctx then return end
            if not current() then M.cancel(host);return end
            local target=type(value)=='table' and value.target
            if type(target)~='table' or target.path~=ctx.file or not Cache.valid_entry(target.entry,entry.book_id,scope.vid)
                or target.entry.file_id~=entry.file_id or target.local_only~=true or not same_anchor(target.anchor,expected) then
                fail(type(value)=='table' and value.error);return
            end
            done(target.anchor)
        end)
        if not called or not started then fail();return false end;return true
    end
    local function locate(anchor)
        ctx.thread=coroutine.create(function()
            local first,last=true,os.clock()
            local index=require('weread.lib.source_dom').open_direct_prepared(doc,entry.book_id,entry.chapter_uid,identity,{
                is_current=current,source_format=anchor.basis=='raw_txt_utf16' and 'web_txt' or nil,
                yield=function() if first or os.clock()-last>=.02 then first=false;coroutine.yield();last=os.clock() end end})
            return index and index:locate_anchor(anchor) or nil
        end)
        local step
        step=function()
            ctx.task=nil
            if not current() then M.cancel(host);return end
            local resumed,point=coroutine.resume(ctx.thread)
            if not resumed then fail();return end
            if coroutine.status(ctx.thread)~='dead' then ctx.task=step;UI:scheduleIn(.1,step);return end
            ctx.thread=nil
            if type(point)~='table' or point.co~=anchor.co or point.book_id~=entry.book_id
                or point.chapter_uid~=entry.chapter_uid or point.file_id~=entry.file_id
                or point.render_path~='OEBPS/text/chapter.xhtml' or type(point.xpointer)~='string' or #point.xpointer>4096 then fail();return end
            check(function()
                if not current() then M.cancel(host);return end
                local geometry=require('weread.lib.reader_position');ctx.committing=true
                local applied=geometry.goto_xpointer(reader,point.xpointer);ctx.committing=false
                local frame=geometry.snapshot(doc,reader.view and reader.view.view_mode,
                    host.progress_sync and host.progress_sync.get_viewport_height and host.progress_sync.get_viewport_height())
                local verified=applied and geometry.contains_anchor(doc,frame,point.xpointer)
                if host._native_online_search_open~=ctx then return end
                M.cancel(host);if not verified then host:showInfo(_(message())) end
            end)
        end
        ctx.task=step;UI:scheduleIn(.1,step)
    end
    return check(locate)
end
function M.start(host,owner,hit,is_current)
    if not owner.native_entry or type(is_current)~='function' or not is_current(host,owner) then return false end
    local reader=host.ui;local doc=reader and reader.document;local at=doc and location(reader,doc)
    local native=NativeAccess.capture(host.settings);local web=WebAccess.capture(host.settings);local scope=owner.scope
    if not at or not scope then host:showInfo(_(message()));return false end
    if not native or native.renewal_pending then
        host:showInfo(_('Authorize or renew E-Ink login in settings, then try again.'));return false
    end
    if not web or not web.web or not accesses(host,native,web,scope,owner.account) then
        host:showInfo(_('A verified WeRead web login is required for online book search.'));return false
    end
    Navigation.cancel(host,owner)
    local frozen={};for _,key in ipairs({'chapter_uid','start','finish','text','source_verified'}) do frozen[key]=hit[key] end
    local job={started=os.time(),location=at};owner.navigation=job
    local function current()
        local age=os.time()-job.started
        for key,value in pairs(frozen) do if hit[key]~=value then return false end end
        return owner.navigation==job and age>=0 and age<=180 and is_current(host,owner)
            and accesses(host,native,web,scope,owner.account) and Context.same_location(at,location(reader,doc))
    end
    job.current=current
    local function fail(reason)
        if owner.navigation~=job then return end
        local live=current();Navigation.cancel(host,owner);if live then host:showInfo(_(message(reason))) end
    end
    local ok,worker=pcall(function() return require('weread.lib.memory_worker'):new{
        scheduler=UI,codec=host.client,max_bytes=1024*1024,timeout=180} end)
    if not ok then fail();return false end;job.worker=worker
    local function busy()
        host:showBusy(_('Locating search result…'),function() if owner.navigation==job then Navigation.cancel(host,owner) end end)
        job.busy=host.busy_message
    end
    local run
    run=function(download)
        if not current() then Navigation.cancel(host,owner);return end
        busy()
        local called,started=pcall(worker.start,worker,function()
            local resolved,why=Resolver.resolve(host.client,host.settings,owner.native_entry,doc.file,frozen,native,web,
                function() return host.settings:auth_scope_matches(scope) end,download,book(host,owner.id))
            return resolved and {target=resolved} or {error=why}
        end,function(value)
            if owner.navigation~=job then return end
            if not current() then Navigation.cancel(host,owner);return end
            if job.busy and host.busy_message==job.busy then host:closeBusy() end;job.busy=nil
            local target=type(value)=='table' and value.target
            if type(target)~='table' then
                local why=type(value)=='table' and value.error
                if why=='not_saved' and not download then
                    local confirm
                    confirm=require('ui/widget/confirmbox'):new{
                        text=_('No matching downloaded chapter. Download it and locate this search result?'),
                        ok_text=_('Download target chapter'),cancel_text=_('Cancel'),keep_dialog_open=true,
                        ok_callback=function()
                            if not current() or job.confirm~=confirm then return end
                            job.confirm=nil;UI:close(confirm);run(true)
                        end,
                        cancel_callback=function() if owner.navigation==job and job.confirm==confirm then job.confirm=nil;Navigation.cancel(host,owner) end end}
                    job.confirm=confirm;UI:show(confirm);return
                end
                fail(why);return
            end
            if target.local_only~=true or not Path.contains(host.settings,target.path)
                or not Cache.valid_entry(target.entry,owner.id,scope.vid) or target.entry.chapter_uid~=frozen.chapter_uid
                or type(target.entry.file_id)~='string' or type(target.anchor)~='table' then fail();return end
            local destination=target.path;local started_at=os.time();local used=false
            local function receive(next_reader)
                if used then return false end;used=true
                local age=os.time()-started_at;local next_host=next_reader and next_reader.weread
                local next_doc=next_host and next_host.ui and next_host.ui.document
                if age<0 or age>180 or not next_host or not next_doc or next_doc~=next_reader.document or next_doc.file~=destination
                    or not accesses(host,native,web,scope,owner.account) or not accesses(next_host,native,web,scope,owner.account)
                    or not (next_host==host and next_doc==doc and (host._reader_session_gen or 0)==owner.session
                        or next_host~=host and (host._reader_session_gen or 0)==owner.session+1) then return false end
                local identity=Identity.read_document(next_doc,owner.id)
                if identity.book_id~=owner.id or identity.file_id~=target.entry.file_id
                    or identity.book_version~=target.entry.book_version then return false end
                return M.receive(next_host,target.entry,frozen,native,web,scope,owner.account,target.anchor)
            end
            owner.navigation=nil
            if destination==doc.file then host:cancelBookSearch();receive(reader)
            else host:openFile(destination,receive) end
        end)
        if not called or not started then fail() end
    end
    run(false);return true
end
return M
