-- Inspect one native reader page against an independently verified source.
-- This action is read-only and cannot authorize a cloud progress write.
local UI=require('ui/uimanager')
local Context=require('weread.lib.source_context')
local Identity=require('weread.lib.book_file_identity')
local NativeAccess=require('weread.lib.native_read_access')
local Currentness=require('weread.lib.source_currentness')
local Recovery=require('weread.lib.native_read_recovery')
local Crypto=require('weread.lib.crypto')
local Protocol=require('weread.lib.native_position_protocol')
local _=require('weread.lib.plugin_util').tr
local M={}
local function native_capture(settings,store)
    local native=NativeAccess.capture(settings,store)
    if not native then return nil end
    return {native=native,base_revision=Crypto.sha256_hex(native.scope.vid..'\0'..tostring(native.scope.epoch))}
end
function M.cancel(host)
    local ctx=host._native_direct_position
    if not ctx then return end
    host._native_direct_position=nil
    if ctx.task then UI:unschedule(ctx.task);ctx.task=nil end
    if host._native_direct_position_worker then host._native_direct_position_worker:cancel() end
    if ctx.web_job and host.source_recovery then host.source_recovery:cancel(ctx.web_job) end
    Recovery.cancel(host,ctx.native_job or {})
    if ctx.busy and host.busy_message==ctx.busy then host:closeBusy() end
    ctx.busy,ctx.thread,ctx.input=nil,nil,nil
end
function M.start(host,entry)
    local reader=host.ui;local doc=reader and reader.document
    local scope=host.settings:get_auth_scope()
    if not doc or not scope or not host.settings:auth_scope_matches(scope)
        or not require('weread.lib.native_direct_cache').valid_entry(entry,entry and entry.book_id,scope.vid) then return false end
    local online=host.isNetworkConnected and host:isNetworkConnected() or not host.isNetworkConnected and host:isNetworkOnline()
    if not online then host:showOffline(_('Check native reading position'));return false end
    local native=NativeAccess.capture(host.settings);local web=Currentness.capture(host.settings)
    if not native or native.renewal_pending or type(native.scope)~='table' or not web or type(web.web)~='table'
        or type(web.web.cookies)~='table' or web.web.cookies.wr_vid~=scope.vid or native.scope.vid~=scope.vid then
        host:showInfo(_('Sign in and authorize E-Ink access before checking this position.'));return false
    end
    if not Protocol.integer(entry.chapter_idx,0,1000000) then
        host:showInfo(_('Chapter position metadata is unavailable. Refresh the chapter list and reopen it.'));return false
    end
    local mode=reader.view and reader.view.view_mode or 'page'
    local location=Context.location(doc,mode)
    local identity=Identity.read_document(doc,entry.book_id)
    if not location or identity.book_id~=entry.book_id or identity.file_id~=entry.file_id
        or identity.book_version~=entry.book_version then
        host:showInfo(_('The current reading page could not be verified.'));return false
    end
    M.cancel(host)
    local ctx={reader=reader,document=doc,file=doc.file,scope=scope,entry=entry,identity=identity,location=location,
        session=host._reader_session_gen or 0,account=host.library_db and host.library_db:accountKey(),native=native,web=web}
    host._native_direct_position=ctx
    local function page_current()
        if host._native_direct_position~=ctx or host.ui~=reader or reader.document~=doc or doc.file~=ctx.file
            or (host._reader_session_gen or 0)~=ctx.session or not host.settings:auth_scope_matches(scope)
            or host.library_db and host.library_db:accountKey()~=ctx.account then return false end
        local now=Context.location(doc,reader.view and reader.view.view_mode or 'page')
        local file=Identity.read_document(doc,entry.book_id)
        return Context.same_location(location,now) and file.file_id==identity.file_id and file.book_id==entry.book_id
            and file.book_version==identity.book_version
    end
    local function access_current()
        return NativeAccess.matches(host.settings,ctx.native) and Currentness.matches(host.settings,ctx.web)
    end
    local function fail(message)
        if host._native_direct_position~=ctx then return end
        local live=page_current();M.cancel(host)
        if live then host:showInfo(_(message or 'Could not check this reading position.')) end
    end
    host:showBusy(_('Checking the current reading position...'),function() M.cancel(host) end);ctx.busy=host.busy_message
    if not host._native_direct_position_worker then
        local ok,worker=pcall(function() return require('weread.lib.memory_worker'):new{
            scheduler=UI,codec=host.client,max_bytes=65536,timeout=180} end)
        if not ok then fail();return false end
        host._native_direct_position_worker=worker
    end
    local launch
    local function renew_native()
        ctx.native_job=ctx.native_job or {}
        local selected={native=ctx.native,base_revision=Crypto.sha256_hex(scope.vid..'\0'..tostring(scope.epoch))}
        local started=Recovery.start(host,ctx.native_job,selected,{capture=native_capture,
            is_current=function() return page_current() and Currentness.matches(host.settings,ctx.web) end,
            stale=function() if host._native_direct_position==ctx then M.cancel(host) end end,
            complete=function(ok,fresh)
                if not ok then fail('E-Ink authorization expired. Please authorize again.');return end
                ctx.native=fresh.native;launch()
            end})
        if not started then fail('E-Ink authorization expired. Please authorize again.') end
    end
    local function renew_web()
        if ctx.web_attempted or not host.source_recovery then
            fail('WeRead login expired. Please sign in again and retry.');return
        end
        ctx.web_attempted=true
        local started,job=host.source_recovery:start(entry.book_id,ctx.web,function()
            return page_current() and NativeAccess.matches(host.settings,ctx.native)
        end,function(fresh)
            ctx.web_job=nil
            if not fresh then fail('WeRead login expired. Please sign in again and retry.');return end
            ctx.web=fresh;launch()
        end)
        if host._native_direct_position==ctx then
            if started then ctx.web_job=job else fail('WeRead login expired. Please sign in again and retry.') end
        end
    end
    launch=function()
        if not page_current() or not access_current() then M.cancel(host);return end
        ctx.generation=(ctx.generation or 0)+1;local generation=ctx.generation
        local selected_native,selected_web=ctx.native,ctx.web
        local ok,started=pcall(host._native_direct_position_worker.start,host._native_direct_position_worker,function()
            -- Child may inspect settings/files, but must never call native document methods.
            local function active()
                return host.settings:auth_scope_matches(scope) and NativeAccess.matches(host.settings,selected_native)
                    and Currentness.matches(host.settings,selected_web)
            end
            local value,why=require('weread.lib.native_direct_position').prepare(host.client,host.settings,
                entry,ctx.file,ctx.input,selected_native,selected_web,active)
            return value and {position=value} or {error=why or 'unavailable'}
        end,function(result)
            if host._native_direct_position~=ctx or ctx.generation~=generation then return end
            if not page_current() or not access_current() then M.cancel(host);return end
            if type(result)=='table' and result.error=='web_expired' then renew_web();return end
            if type(result)=='table' and result.error=='auth_expired' then renew_native();return end
            local p=type(result)=='table' and result.position
            if type(p)~='table' or p.book_id~=entry.book_id or p.chapter_uid~=entry.chapter_uid
                or p.chapter_idx~=entry.chapter_idx or p.file_id~=entry.file_id or p.book_version~=entry.book_version
                or p.raw_sha256~=entry.source_sha256 or p.basis~='filtered_xhtml_utf16'
                or p.source_current~=true or p.upload_verified~=false or not Protocol.integer(p.chapter_offset,0,2147483647) then
                local message=type(result)=='table' and result.error=='source_changed'
                    and 'The chapter source changed, so the reading position could not be checked.' or nil
                fail(message);return
            end
            M.cancel(host)
            host:showInfo(_('The local reading position was checked against the chapter source. Cloud sync is not enabled yet.'))
        end)
        if not ok or not started then fail() end
    end
    local function resume_capture()
        ctx.task=nil
        if not page_current() or not access_current() then M.cancel(host);return end
        local ok,value=coroutine.resume(ctx.thread)
        if not ok then fail();return end
        if coroutine.status(ctx.thread)~='dead' then
            ctx.task=function() resume_capture() end;UI:scheduleIn(0.1,ctx.task);return
        end
        ctx.thread=nil
        if not value or value.error then fail('The current reading page could not be verified.');return end
        ctx.input=value;launch()
    end
    ctx.thread=coroutine.create(function()
        return Context.capture(doc,entry.book_id,location,{
            viewport_height=host.progress_sync and host.progress_sync.get_viewport_height and host.progress_sync.get_viewport_height(),
            is_current=function() return page_current() and access_current() end,
            yield=function() coroutine.yield() end,
            metadata_resolver=function(document,book_id,render_path)
                if document~=doc or book_id~=entry.book_id or render_path~='OEBPS/text/chapter.xhtml' then return nil end
                local actual=Identity.read_document(document,book_id)
                if actual.file_id~=entry.file_id or actual.book_id~=entry.book_id or actual.book_version~=entry.book_version then return nil end
                return {metadata=entry.file_id..entry.source_sha256,identity=actual,chapter_uid=entry.chapter_uid}
            end,
        })
    end)
    ctx.task=function() resume_capture() end;UI:scheduleIn(0.1,ctx.task)
    return true
end
return M
