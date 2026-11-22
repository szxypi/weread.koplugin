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
    if ctx.confirm then UI:close(ctx.confirm);ctx.confirm=nil end
    if ctx.busy and host.busy_message==ctx.busy then host:closeBusy() end
    ctx.busy,ctx.thread,ctx.input=nil,nil,nil
end
function M.on_view_changed(host)
    local ctx=host._native_direct_position
    if ctx and not ctx.committing and ctx.is_current and not ctx.is_current() then M.cancel(host) end
end
function M.start(host,entry,options)
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
        compare=options and options.cloud==true or false,
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
    ctx.is_current=function() return page_current() and access_current() end
    local function fail(message)
        if host._native_direct_position~=ctx then return end
        local live=page_current();M.cancel(host)
        if live then host:showInfo(_(message or 'Could not check this reading position.')) end
    end
    host:showBusy(_(ctx.compare and 'Checking cloud reading position...' or 'Checking the current reading position...'),
        function() M.cancel(host) end);ctx.busy=host.busy_message
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
            if ctx.compare then
                local value,why=require('weread.lib.native_direct_cloud').prepare(host.client,host.settings,
                    entry,ctx.file,ctx.input,selected_native,selected_web,active)
                return value and {comparison=value} or {error=why or 'unavailable'}
            end
            local value,why=require('weread.lib.native_direct_position').prepare(host.client,host.settings,
                entry,ctx.file,ctx.input,selected_native,selected_web,active)
            return value and {position=value} or {error=why or 'unavailable'}
        end,function(result)
            if host._native_direct_position~=ctx or ctx.generation~=generation then return end
            if not page_current() or not access_current() then M.cancel(host);return end
            if type(result)=='table' and result.error=='web_expired' then renew_web();return end
            if type(result)=='table' and result.error=='auth_expired' then renew_native();return end
            local comparison=type(result)=='table' and result.comparison
            local p
            if ctx.compare then p=type(comparison)=='table' and comparison.position
            else p=type(result)=='table' and result.position end
            if type(p)~='table' or p.book_id~=entry.book_id or p.chapter_uid~=entry.chapter_uid
                or p.chapter_idx~=entry.chapter_idx or p.file_id~=entry.file_id or p.book_version~=entry.book_version
                or p.raw_sha256~=entry.source_sha256 or p.basis~='filtered_xhtml_utf16'
                or p.source_current~=true or p.upload_verified~=false or not Protocol.integer(p.chapter_offset,0,2147483647) then
                local message=type(result)=='table' and result.error=='source_changed'
                    and 'The chapter source changed, so the reading position could not be checked.'
                    or type(result)=='table' and result.error=='cloud_changed'
                    and 'The cloud position changed during the check. Your current page is kept.'
                    or type(result)=='table' and result.error=='rate_limited'
                    and 'WeRead is limiting requests. Please try again later.' or nil
                fail(message);return
            end
            if ctx.compare then
                local relation=comparison.relation
                local messages={same='The current page matches the cloud reading position.',
                    no_chapter='There is no cloud reading position yet. Your current page is kept.',
                    other_chapter='The cloud reading position is in another chapter. Your current page is kept.',
                    target_unavailable='The cloud position could not be located in this chapter. Your current page is kept.'}
                if messages[relation] then M.cancel(host);host:showInfo(_(messages[relation]));return end
                local anchor=comparison.anchor
                if relation~='different' or type(anchor)~='table' or anchor.co~=comparison.cloud_offset
                    or comparison.cloud_offset==p.chapter_offset
                    or not Protocol.integer(anchor.co,0,2147483647) or anchor.basis~='filtered_xhtml_utf16'
                    or anchor.point_unit~='unicode_scalars' or type(anchor.text)~='string' or #anchor.text<12
                    or #anchor.text>8192 or not Protocol.integer(anchor.point_offset,0,8192) then fail();return end
                if ctx.busy and host.busy_message==ctx.busy then host:closeBusy() end;ctx.busy=nil
                local confirm
                confirm=require('ui/widget/confirmbox'):new{
                    text=_('The cloud position differs from this page. Open the cloud position in this chapter?'),
                    ok_text=_('Open cloud position'),cancel_text=_('Keep current page'),keep_dialog_open=true,
                    cancel_callback=function()
                        if host._native_direct_position==ctx and ctx.confirm==confirm then
                            ctx.confirm=nil;M.cancel(host)
                        end
                    end,
                    ok_callback=function()
                        if not page_current() or not access_current() then M.cancel(host);return end
                        UI:close(confirm);ctx.confirm=nil
                        host:showBusy(_('Locating cloud reading position...'),function() M.cancel(host) end);ctx.busy=host.busy_message
                        local locate
                        ctx.thread=coroutine.create(function()
                            local first,last=true,os.clock()
                            local index=require('weread.lib.source_dom').open_direct_prepared(doc,entry.book_id,entry.chapter_uid,identity,{
                                is_current=function() return page_current() and access_current() end,
                                yield=function()
                                    if first or os.clock()-last>=0.02 then first=false;coroutine.yield();last=os.clock() end
                                end,
                            })
                            return index and index:locate_anchor(anchor) or nil
                        end)
                        locate=function()
                            ctx.task=nil
                            if not page_current() or not access_current() then M.cancel(host);return end
                            local ok,point=coroutine.resume(ctx.thread)
                            if not ok then fail();return end
                            if coroutine.status(ctx.thread)~='dead' then
                                ctx.task=locate;UI:scheduleIn(0.1,ctx.task);return
                            end
                            ctx.thread=nil
                            if type(point)~='table' or point.co~=anchor.co or point.book_id~=entry.book_id
                                or point.chapter_uid~=entry.chapter_uid or point.file_id~=entry.file_id
                                or point.render_path~='OEBPS/text/chapter.xhtml' or type(point.xpointer)~='string'
                                or #point.xpointer>4096 or not page_current() or not access_current() then
                                fail('The cloud position could not be located in this chapter. Your current page is kept.');return
                            end
                            -- The confirmation and DOM walk may take time. Re-read
                            -- both sources and cloud state before moving the page.
                            local native_now,web_now=ctx.native,ctx.web
                            local called,started=pcall(host._native_direct_position_worker.start,host._native_direct_position_worker,function()
                                local function active()
                                    return host.settings:auth_scope_matches(scope) and NativeAccess.matches(host.settings,native_now)
                                        and Currentness.matches(host.settings,web_now)
                                end
                                local value,why=require('weread.lib.native_direct_cloud').prepare(host.client,host.settings,
                                    entry,ctx.file,ctx.input,native_now,web_now,active)
                                return value and {comparison=value} or {error=why or 'unavailable'}
                            end,function(fresh)
                                if host._native_direct_position~=ctx then return end
                                if not page_current() or not access_current() then M.cancel(host);return end
                                local next_value=type(fresh)=='table' and fresh.comparison
                                local next_point=type(next_value)=='table' and next_value.position
                                local next_anchor=type(next_value)=='table' and next_value.anchor
                                local same=type(next_point)=='table' and type(next_anchor)=='table'
                                    and next_value.relation=='different' and next_value.cloud_offset==comparison.cloud_offset
                                if same then
                                    for _,key in ipairs({'book_id','chapter_uid','chapter_idx','chapter_offset','file_id',
                                        'book_version','raw_sha256','basis','source_current','upload_verified'}) do
                                        if next_point[key]~=p[key] then same=false end
                                    end
                                    for _,key in ipairs({'co','text','point_offset','point_unit','basis'}) do
                                        if next_anchor[key]~=anchor[key] then same=false end
                                    end
                                end
                                if not same then fail('The cloud position changed during the check. Your current page is kept.');return end
                                local geometry=require('weread.lib.reader_position')
                                ctx.committing=true
                                local applied=geometry.goto_xpointer(reader,point.xpointer)
                                ctx.committing=false
                                local frame=geometry.snapshot(doc,reader.view and reader.view.view_mode,
                                    host.progress_sync and host.progress_sync.get_viewport_height and host.progress_sync.get_viewport_height())
                                local verified=applied and geometry.contains_anchor(doc,frame,point.xpointer)
                                if host._native_direct_position~=ctx then return end
                                M.cancel(host)
                                host:showInfo(_(verified and 'Opened the cloud reading position in this chapter.'
                                    or 'Could not confirm the cloud position. Please check the current page.'))
                            end)
                            if not called or not started then fail() end
                        end
                        ctx.task=locate;UI:scheduleIn(0.1,ctx.task)
                    end,
                }
                ctx.confirm=confirm;UI:show(confirm);return
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
