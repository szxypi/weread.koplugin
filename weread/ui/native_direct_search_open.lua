-- Resolve a local-only search hit in a verified chapter, including across readers.
local UI=require('ui/uimanager')
local Cache=require('weread.lib.native_direct_cache')
local Search=require('weread.lib.native_direct_search')
local Context=require('weread.lib.source_context')
local Identity=require('weread.lib.book_file_identity')
local Path=require('weread.lib.native_direct_path')
local _=require('weread.lib.plugin_util').tr
local M={}
local function location(reader,doc) return Context.location(doc,reader.view and reader.view.view_mode) end
local function same_anchor(a,b)
    if type(a)~='table' or type(b)~='table' then return false end
    for _,key in ipairs({'co','text','point_offset','point_unit','basis'}) do if a[key]~=b[key] then return false end end
    return true
end
function M.cancel(host)
    local incoming=host._native_direct_search_incoming;host._native_direct_search_incoming=nil
    if incoming and incoming.task then UI:unschedule(incoming.task) end
    local ctx=host._native_direct_search_open;host._native_direct_search_open=nil
    if not ctx then return end
    if ctx.task then UI:unschedule(ctx.task) end
    if ctx.worker then ctx.worker:cancel() end
    if ctx.busy and host.busy_message==ctx.busy then host:closeBusy() end
    ctx.thread=nil
end
function M.on_view_changed(host)
    local incoming=host._native_direct_search_incoming
    if incoming and (host.ui~=incoming.reader or incoming.reader.document~=incoming.document
        or not Context.same_location(incoming.location,location(incoming.reader,incoming.document))) then M.cancel(host);return end
    local ctx=host._native_direct_search_open
    if ctx and not ctx.committing and ctx.current and not ctx.current() then M.cancel(host) end
end
function M.start(host,entry,hit,keyword,ignore_case)
    local reader=host.ui;local doc=reader and reader.document;local scope=host.settings:get_auth_scope()
    local at=doc and location(reader,doc);local account=host.library_db and host.library_db:accountKey()
    if not at or not scope or not account or not host.settings:auth_scope_matches(scope)
        or not Cache.valid_entry(entry,entry and entry.book_id,scope.vid)
        or type(hit)~='table' or hit.chapter_uid~=entry.chapter_uid or type(hit.byte)~='number'
        or hit.byte%1~=0 or hit.byte<1 or type(hit.file_id)~='string' or #hit.file_id~=64
        or not hit.file_id:match('^[a-f0-9]+$') or type(hit.anchor)~='table'
        or type(keyword)~='string' or #keyword<1 or #keyword>160 or type(ignore_case)~='boolean' then return false end
    M.cancel(host)
    local ctx={reader=reader,document=doc,file=doc.file,scope=scope,session=host._reader_session_gen or 0,
        account=account,location=at,started=os.time()}
    host._native_direct_search_open=ctx
    local function current()
        local age=os.time()-ctx.started
        return host._native_direct_search_open==ctx and age>=0 and age<=180 and host.ui==reader and reader.document==doc
            and doc.file==ctx.file and (host._reader_session_gen or 0)==ctx.session
            and host.settings:auth_scope_matches(scope) and host.library_db and host.library_db:accountKey()==account
            and Context.same_location(at,location(reader,doc))
    end
    ctx.current=current
    local function fail()
        if host._native_direct_search_open~=ctx then return end
        local visible=current();M.cancel(host)
        if visible then host:showInfo(_('Could not locate this downloaded search result. The cached chapter may have changed.')) end
    end
    host:showBusy(_('Locating search result…'),function() M.cancel(host) end);ctx.busy=host.busy_message
    local ok,worker=pcall(function() return require('weread.lib.memory_worker'):new{
        scheduler=UI,codec=host.client,max_bytes=1024*1024,timeout=180} end)
    if not ok then fail();return false end
    ctx.worker=worker
    local function run(done)
        local called,started=pcall(worker.start,worker,function()
            local active=function() return host.settings:auth_scope_matches(scope) end
            local saved=Cache.open(host.settings,scope.vid,entry.book_id,entry,active)
            if not saved or saved.file_id~=hit.file_id then return {error='changed'} end
            local result=Search.scan(host.settings,scope.vid,entry,keyword,hit.byte,ignore_case,active)
            local found=type(result)=='table' and type(result.hits)=='table' and result.hits[1]
            if not found or found.byte~=hit.byte or found.file_id~=hit.file_id or not same_anchor(found.anchor,hit.anchor) then
                return {error='changed'}
            end
            return {path=saved.path}
        end,function(result)
            if host._native_direct_search_open~=ctx then return end
            if not current() then M.cancel(host);return end
            if type(result)~='table' or not Path.contains(host.settings,result.path) then fail();return end
            done(result.path)
        end)
        if not called or not started then fail();return false end
        return true
    end
    local function locate(path)
        if path~=doc.file then
            local used=false;local started=os.time()
            local function handoff(next_reader)
                if used then return false end;used=true
                local age=os.time()-started;local next_host=next_reader and next_reader.weread
                local next_doc=next_host and next_host.ui and next_host.ui.document
                if age<0 or age>180 or (host._reader_session_gen or 0)~=ctx.session+1
                    or not host.settings:auth_scope_matches(scope) or not next_host or next_host==host
                    or not next_doc or next_doc~=next_reader.document or next_doc.file~=path
                    or not next_host.settings:auth_scope_matches(scope) or not next_host.library_db
                    or next_host.library_db:accountKey()~=account then return false end
                local identity=Identity.read_document(next_doc,entry.book_id)
                if identity.book_id~=entry.book_id or identity.book_version~=entry.book_version or identity.file_id~=hit.file_id then return false end
                return M.receive(next_host,entry,hit,keyword,ignore_case,scope,account)
            end
            M.cancel(host);host:openFile(path,handoff);return
        end
        local identity=Identity.read_document(doc,entry.book_id)
        if identity.book_id~=entry.book_id or identity.book_version~=entry.book_version or identity.file_id~=hit.file_id then fail();return end
        ctx.thread=coroutine.create(function()
            local first,last=true,os.clock()
            local index=require('weread.lib.source_dom').open_direct_prepared(doc,entry.book_id,entry.chapter_uid,identity,{
                is_current=current,yield=function()
                    if first or os.clock()-last>=.02 then first=false;coroutine.yield();last=os.clock() end
                end})
            return index and index:locate_anchor(hit.anchor) or nil
        end)
        local step
        step=function()
            ctx.task=nil
            if not current() then M.cancel(host);return end
            local resumed,point=coroutine.resume(ctx.thread)
            if not resumed then fail();return end
            if coroutine.status(ctx.thread)~='dead' then ctx.task=step;UI:scheduleIn(.1,step);return end
            ctx.thread=nil
            if type(point)~='table' or point.co~=hit.anchor.co or point.book_id~=entry.book_id
                or point.chapter_uid~=entry.chapter_uid or point.file_id~=hit.file_id
                or point.render_path~='OEBPS/text/chapter.xhtml' or type(point.xpointer)~='string'
                or #point.xpointer>4096 then fail();return end
            run(function(fresh)
                if fresh~=path or not current() then fail();return end
                local geometry=require('weread.lib.reader_position');ctx.committing=true
                local applied=geometry.goto_xpointer(reader,point.xpointer);ctx.committing=false
                local frame=geometry.snapshot(doc,reader.view and reader.view.view_mode,
                    host.progress_sync and host.progress_sync.get_viewport_height and host.progress_sync.get_viewport_height())
                local verified=applied and geometry.contains_anchor(doc,frame,point.xpointer)
                if host._native_direct_search_open~=ctx then return end
                M.cancel(host)
                if not verified then host:showInfo(_('Could not locate this downloaded search result. The cached chapter may have changed.')) end
            end)
        end
        ctx.task=step;UI:scheduleIn(.1,step)
    end
    return run(locate)
end
function M.receive(host,entry,hit,keyword,ignore_case,scope,account)
    M.cancel(host)
    local reader=host.ui;local doc=reader and reader.document;local at=doc and location(reader,doc)
    if not at or not scope or not host.settings:auth_scope_matches(scope) or not host.library_db
        or host.library_db:accountKey()~=account then return false end
    local incoming={reader=reader,document=doc,location=at,session=host._reader_session_gen or 0,started=os.time()}
    incoming.task=function()
        if host._native_direct_search_incoming~=incoming then return end
        host._native_direct_search_incoming=nil
        local age=os.time()-incoming.started
        if age<0 or age>120 or host.ui~=reader or reader.document~=doc or (host._reader_session_gen or 0)~=incoming.session
            or not Context.same_location(at,location(reader,doc)) or not host.settings:auth_scope_matches(scope)
            or not host.library_db or host.library_db:accountKey()~=account then return end
        M.start(host,entry,hit,keyword,ignore_case)
    end
    host._native_direct_search_incoming=incoming;UI:scheduleIn(.1,incoming.task);return true
end
return M
