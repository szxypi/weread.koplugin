-- Offer a verified local-only handoff to an improved native chapter copy.
local UI=require('ui/uimanager')
local Cache=require('weread.lib.native_direct_cache')
local Context=require('weread.lib.source_context')
local Identity=require('weread.lib.book_file_identity')
local Path=require('weread.lib.native_direct_path')
local _=require('weread.lib.plugin_util').tr
local M={}
local FAILURE='Could not match this page in the new copy. Your current page was kept.'
function M.cancel(host)
    local ctx=host._native_direct_copy_resume;host._native_direct_copy_resume=nil
    if not ctx then return end
    if ctx.task then UI:unschedule(ctx.task) end
    if ctx.worker then ctx.worker:cancel() end
    if ctx.busy and host.busy_message==ctx.busy then host:closeBusy() end
    local dialog=ctx.dialog;ctx.dialog=nil
    if dialog then UI:close(dialog) end
    ctx.thread=nil
end
function M.offer(host,entry,destination)
    local reader=host.ui;local doc=reader and reader.document;local scope=host.settings:get_auth_scope()
    local account=host.library_db and host.library_db:accountKey()
    if not doc or not scope or not account or not host.settings:auth_scope_matches(scope)
        or not Cache.valid_entry(entry,entry and entry.book_id,scope.vid) or not entry.file_id
        or not Path.contains(host.settings,doc.file) or not Path.contains(host.settings,destination)
        or destination==doc.file then return false end
    M.cancel(host)
    local ctx={reader=reader,document=doc,file=doc.file,session=host._reader_session_gen or 0,
        account=account,scope=scope,entry=entry,destination=destination,started=os.time()}
    host._native_direct_copy_resume=ctx
    local function view_current()
        local age=os.time()-ctx.started
        return host._native_direct_copy_resume==ctx and not host._weread_suspended and age>=0 and age<=300
            and host.ui==reader and reader.document==doc and doc.file==ctx.file
            and (host._reader_session_gen or 0)==ctx.session and host.settings:auth_scope_matches(scope)
            and host.library_db and host.library_db:accountKey()==account
    end
    local function location() return Context.location(doc,reader.view and reader.view.view_mode) end
    local function page_current() return view_current() and Context.same_location(ctx.location,location()) end
    local function fail()
        if host._native_direct_copy_resume~=ctx then return end
        local visible=view_current();M.cancel(host);if visible then host:showInfo(_(FAILURE)) end
    end
    local function prepare()
        if not view_current() then M.cancel(host);return end
        ctx.location=location();if not ctx.location then fail();return end
        host:showBusy(_('Finding this page in the new copy...'),function() M.cancel(host) end);ctx.busy=host.busy_message
        local ok,worker=pcall(function() return require('weread.lib.memory_worker'):new{scheduler=UI,codec=host.client,timeout=180} end)
        if not ok then fail();return end
        ctx.worker=worker
        local function map(input)
            local ran,started=pcall(worker.start,worker,function()
                return require('weread.lib.native_direct_copy_resume').prepare(host.settings,scope.vid,entry,ctx.file,
                    destination,input,page_current)
            end,function(value)
                if host._native_direct_copy_resume~=ctx then return end
                if not page_current() then M.cancel(host);return end
                if type(value)~='table' or not Cache.valid_entry(value.entry,entry.book_id,scope.vid)
                    or value.entry.chapter_uid~=entry.chapter_uid or value.entry.book_version~=entry.book_version
                    or value.entry.source_sha256~=entry.source_sha256 or type(value.hit)~='table'
                    or type(value.keyword)~='string' or #value.keyword<1 or #value.keyword>160 then fail();return end
                local target,hit,keyword=value.entry,value.hit,value.keyword
                M.cancel(host)
                local handed,started=pcall(function() return require('weread.ui.native_direct_search_open').start(host,target,hit,keyword,false) end)
                if not handed or not started then
                    local search=package.loaded['weread.ui.native_direct_search_open']
                    if search and search.cancel then search.cancel(host) end
                    host:showInfo(_(FAILURE))
                end
            end)
            if not ran or not started then fail() end
        end
        ctx.thread=coroutine.create(function()
            return Context.capture(doc,entry.book_id,ctx.location,{
                viewport_height=host.progress_sync and host.progress_sync.get_viewport_height and host.progress_sync.get_viewport_height(),
                is_current=page_current,yield=function() coroutine.yield() end,
                metadata_resolver=function(document,book_id,render_path)
                    if document~=doc or book_id~=entry.book_id or render_path~='OEBPS/text/chapter.xhtml' then return nil end
                    local actual=Identity.read_document(document,book_id)
                    if actual.file_id~=entry.file_id or actual.book_id~=entry.book_id or actual.book_version~=entry.book_version then return nil end
                    return {metadata=entry.file_id..entry.source_sha256,identity=actual,chapter_uid=entry.chapter_uid}
                end})
        end)
        local step
        step=function()
            ctx.task=nil
            if not page_current() then M.cancel(host);return end
            local resumed,value=coroutine.resume(ctx.thread)
            if not resumed then fail();return end
            if coroutine.status(ctx.thread)~='dead' then ctx.task=step;UI:scheduleIn(.1,step);return end
            ctx.thread=nil
            if type(value)~='table' or value.error then fail();return end
            map(value)
        end
        ctx.task=step;UI:scheduleIn(.1,step)
    end
    local dialog
    local ok,value=pcall(function() return require('ui/widget/buttondialog'):new{title=_('Images were saved in a new copy. Continue at this page?'),buttons={{
        {id='later',text=_('Later'),callback=function() if ctx.dialog==dialog then M.cancel(host) end end},
        {id='continue_copy',text=_('Continue in new copy'),callback=function()
            if ctx.dialog~=dialog then return end
            ctx.dialog=nil;UI:close(dialog);prepare()
        end},
    }},tap_close_callback=function() if ctx.dialog==dialog then ctx.dialog=nil;M.cancel(host) end end} end)
    if not ok or not value then M.cancel(host);return false end
    dialog=value;ctx.dialog=dialog
    if not pcall(UI.show,UI,dialog) then M.cancel(host);return false end
    return true
end
return M
