-- Parent-owned native reader position checks and guarded cloud sync.
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
    if ctx.service then ctx.service:cancel() end
    if ctx.review then ctx.review:cancel() end
    if ctx.web_job and host.source_recovery then host.source_recovery:cancel(ctx.web_job) end
    Recovery.cancel(host,ctx.native_job or {})
    if ctx.confirm then UI:close(ctx.confirm);ctx.confirm=nil end
    if ctx.busy and host.busy_message==ctx.busy then host:closeBusy() end
    ctx.busy,ctx.thread,ctx.input=nil,nil,nil
    if ctx.automatic then pcall(ctx.automatic.done,ctx.auto_status or 'cancelled',ctx.auto_metadata,ctx.location) end
end
function M.on_view_changed(host)
    local ctx=host._native_direct_position
    if ctx and not ctx.committing and ctx.is_current and not ctx.is_current() then M.cancel(host) end
end
function M.start(host,entry,options)
    local automatic=options and options.automatic
    if options and options.upload and host._offline_time_transfer_lock then
        if not automatic and host.showInfo then host:showInfo(_('Another synchronization is running. Try again after it finishes.')) end
        return false
    end
    if automatic and (type(automatic)~='table' or type(automatic.current)~='function' or type(automatic.done)~='function'
        or type(automatic.baseline)~='table' or options.upload~=true or options.cloud==true
        or host._native_direct_position or not automatic.current()) then return false end
    if not automatic and options and (options.upload or options.cloud) then
        local interval=package.loaded['weread.lib.native_direct_interval'];if interval then interval.cancel(host) end
    end
    local reader=host.ui;local doc=reader and reader.document
    local scope=host.settings:get_auth_scope()
    if not doc or not scope or not host.settings:auth_scope_matches(scope)
        or not require('weread.lib.native_direct_cache').valid_entry(entry,entry and entry.book_id,scope.vid) then return false end
    local online=host.isNetworkConnected and host:isNetworkConnected() or not host.isNetworkConnected and host:isNetworkOnline()
    if not online then if not automatic then host:showOffline(_('Check native reading position')) end;return false end
    local native=NativeAccess.capture(host.settings);local web=Currentness.capture(host.settings)
    if not native or native.renewal_pending or type(native.scope)~='table' or not web or type(web.web)~='table'
        or type(web.web.cookies)~='table' or web.web.cookies.wr_vid~=scope.vid or native.scope.vid~=scope.vid then
        if not automatic then host:showInfo(_('Sign in and authorize E-Ink access before checking this position.')) end;return false
    end
    if not Protocol.integer(entry.chapter_idx,0,1000000) then
        if not automatic then host:showInfo(_('Chapter position metadata is unavailable. Refresh the chapter list and reopen it.')) end;return false
    end
    local mode=reader.view and reader.view.view_mode or 'page'
    local location=Context.location(doc,mode)
    local identity=Identity.read_document(doc,entry.book_id)
    if not location or identity.book_id~=entry.book_id or identity.file_id~=entry.file_id
        or identity.book_version~=entry.book_version then
        if not automatic then host:showInfo(_('The current reading page could not be verified.')) end;return false
    end
    M.cancel(host)
    local ctx={reader=reader,document=doc,file=doc.file,scope=scope,entry=entry,identity=identity,location=location,
        compare=options and options.cloud==true or false,upload=options and options.upload==true or false,automatic=automatic,
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
    ctx.is_current=function() return page_current() and access_current() and (not automatic or automatic.current()) end
    local function fail(message)
        if host._native_direct_position~=ctx then return end
        local live=page_current()
        if automatic then ctx.auto_status=message=='The cloud position changed during the check. Your current page is kept.'
            and 'conflict' or 'failed';M.cancel(host);return end
        M.cancel(host)
        if live then host:showInfo(_(message or 'Could not check this reading position.')) end
    end
    if ctx.upload then
        if ctx.compare or not host.library_db or type(host.library_db.open)~='function' then
            fail('Could not prepare the reading position sync.');return false
        end
        ctx.service=require('weread.lib.native_position_service'):new{
            settings=host.settings,client=host.client,library=host.library_db,scheduler=UI}
        local pending,reason=ctx.service:pending()
        if reason then fail('Could not check the previous position sync.');return false end
        if pending then
            if automatic then ctx.auto_status='unconfirmed';M.cancel(host);return true end
            ctx.review=require('weread.lib.native_position_review'):new{
                settings=host.settings,client=host.client,library=host.library_db,scheduler=UI}
            local function cancel() if host._native_direct_position==ctx then M.cancel(host) end end
            local function inspect()
                if not ctx.is_current() then cancel();return end
                if ctx.confirm then UI:close(ctx.confirm);ctx.confirm=nil end
                host:showBusy(_('Checking the previous position sync...'),cancel);ctx.busy=host.busy_message
                local started=ctx.review:start(ctx.is_current,function(result,token)
                    if host._native_direct_position~=ctx then return end
                    if not ctx.is_current() then cancel();return end
                    if ctx.busy and host.busy_message==ctx.busy then host:closeBusy() end;ctx.busy=nil
                    if result.kind~='observed' or not token then fail('Could not check the previous position sync.');return end
                    local title=_('Previous book')
                    if type(pending.metadata)=='table' and type(host.library_db.getBook)=='function' then
                        local ok,book=pcall(host.library_db.getBook,host.library_db,pending.metadata.book_id)
                        if ok and type(book)=='table' and type(book.title)=='string' and #book.title>0 and #book.title<=512
                            and not book.title:find('[%z%c]') then title=book.title end
                    end
                    if type(result.percent)~='number' or result.percent~=result.percent or result.percent<0 or result.percent>100 then
                        fail('Could not check the previous position sync.');return
                    end
                    local observed=result.no_chapter and string.format(_('No cloud position for “%s”.'),title)
                        or string.format(_('Current cloud percentage for “%s”: %s%%.'),title,string.format('%.0f',result.percent))
                    local dialog
                    dialog=require('ui/widget/confirmbox'):new{
                        text=observed..'\n\n'.._('Archive the previous result without resending? A delayed update may still arrive.'),
                        ok_text=_('Archive previous result'),cancel_text=_('Keep pending record'),keep_dialog_open=true,
                        cancel_callback=cancel,ok_callback=function()
                            if not ctx.is_current() or ctx.confirm~=dialog or not ctx.review:current(token) then cancel();return end
                            local archived=ctx.review:archive(token);M.cancel(host)
                            host:showInfo(_(archived and 'Previous result archived. Choose sync again to check the current page.'
                                or 'Could not archive the previous position sync.'))
                        end}
                    ctx.confirm=dialog;UI:show(dialog)
                end,pending)
                if not started then fail('Could not check the previous position sync.') end
            end
            ctx.confirm=require('ui/widget/confirmbox'):new{
                text=_('A previous position sync needs review. Check its current cloud state without resending?'),
                ok_text=_('Check cloud position'),cancel_text=_('Keep pending record'),keep_dialog_open=true,
                ok_callback=inspect,cancel_callback=cancel}
            UI:show(ctx.confirm);return true
        end
    end
    if not automatic then
        host:showBusy(_(ctx.upload and 'Preparing reading position sync...' or ctx.compare and 'Checking cloud reading position...' or 'Checking the current reading position...'),
            function() M.cancel(host) end);ctx.busy=host.busy_message
    end
    if not host._native_direct_position_worker then
        local ok,worker=pcall(function() return require('weread.lib.memory_worker'):new{
            scheduler=UI,codec=host.client,max_bytes=65536,timeout=180} end)
        if not ok then fail();return false end
        host._native_direct_position_worker=worker
    end
    local launch
    local function renew_native()
        ctx.confirmed_metadata=nil
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
        ctx.confirmed_metadata=nil
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
        if not ctx.is_current() then M.cancel(host);return end
        ctx.generation=(ctx.generation or 0)+1;local generation=ctx.generation
        local selected_native,selected_web=ctx.native,ctx.web
        local ok,started=pcall(host._native_direct_position_worker.start,host._native_direct_position_worker,function()
            -- Child may inspect settings/files, but must never call native document methods.
            local function active()
                return host.settings:auth_scope_matches(scope) and NativeAccess.matches(host.settings,selected_native)
                    and Currentness.matches(host.settings,selected_web)
            end
            if ctx.upload then
                local value,why=require('weread.lib.native_direct_upload_preview').prepare(host.client,host.settings,
                    entry,ctx.file,ctx.input,selected_native,selected_web,active)
                return value and {preview=value} or {error=why or 'unavailable'}
            elseif ctx.compare then
                local value,why=require('weread.lib.native_direct_cloud').prepare(host.client,host.settings,
                    entry,ctx.file,ctx.input,selected_native,selected_web,active)
                return value and {comparison=value} or {error=why or 'unavailable'}
            end
            local value,why=require('weread.lib.native_direct_position').prepare(host.client,host.settings,
                entry,ctx.file,ctx.input,selected_native,selected_web,active)
            return value and {position=value} or {error=why or 'unavailable'}
        end,function(result)
            if host._native_direct_position~=ctx or ctx.generation~=generation then return end
            if not ctx.is_current() then M.cancel(host);return end
            if type(result)=='table' and result.error=='web_expired' then renew_web();return end
            if type(result)=='table' and result.error=='auth_expired' then renew_native();return end
            local comparison=type(result)=='table' and result.comparison
            local p
            if ctx.upload then p=type(result)=='table' and type(result.preview)=='table' and result.preview.position
            elseif ctx.compare then p=type(comparison)=='table' and comparison.position
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
                    and 'WeRead is limiting requests. Please try again later.'
                    or type(result)=='table' and result.error=='baseline_unavailable'
                    and 'The cloud position could not be safely checked. Your current page is kept.' or nil
                fail(message);return
            end
            if ctx.upload then
                local preview=result.preview;local Contract=require('weread.lib.native_position_contract')
                local State=require('weread.lib.native_cloud_state')
                local metadata={book_id=entry.book_id,before=preview.before,desired=preview.desired,counts=preview.counts,
                    version=preview.version,shelf_sha256=preview.shelf_sha256,source_sha256=preview.source_sha256,
                    file_id=preview.file_id,basis=preview.basis}
                if preview.dispatch_authorized~=false or not Contract.valid(metadata)
                    or metadata.basis~='filtered_xhtml_utf16' or metadata.source_sha256~=entry.source_sha256
                    or metadata.file_id~=entry.file_id or metadata.version~=entry.book_version
                    or metadata.desired.book_id~=p.book_id or metadata.desired.chapter_uid~=p.chapter_uid
                    or metadata.desired.chapter_idx~=p.chapter_idx or metadata.desired.chapter_offset~=p.chapter_offset
                    or metadata.desired.raw_percent~=metadata.before.raw_percent then fail();return end
                if automatic then
                    local b=automatic.baseline
                    if not State.equal(metadata.before,b.position) or not Protocol.same_counts(metadata.counts,b.counts)
                        or metadata.version~=b.version or metadata.shelf_sha256~=b.shelf_sha256
                        or metadata.source_sha256~=b.source_sha256 or metadata.file_id~=b.file_id then
                        fail('The cloud position changed during the check. Your current page is kept.');return
                    end
                end
                if not State.none(metadata.before) and metadata.before.chapter_uid==metadata.desired.chapter_uid
                    and metadata.before.chapter_idx==metadata.desired.chapter_idx
                    and metadata.before.chapter_offset==metadata.desired.chapter_offset then
                    if automatic then
                        local reconnect=package.loaded['weread.ui.native_direct_reconnect'];if reconnect then reconnect.synced(host,entry,ctx.location) end
                        ctx.auto_status,ctx.auto_metadata='same',metadata;M.cancel(host);return
                    end
                    M.cancel(host)
                    local reconnect=package.loaded['weread.ui.native_direct_reconnect'];if reconnect then reconnect.synced(host,entry,ctx.location) end
                    require('weread.lib.native_direct_interval').arm_session(host,entry,ctx,metadata,'before')
                    host:showInfo(_('The current page matches the cloud reading position.'));return
                end
                if not ctx.confirmed_metadata then
                    if automatic then ctx.confirmed_metadata=metadata;launch();return end
                    if ctx.busy and host.busy_message==ctx.busy then host:closeBusy() end;ctx.busy=nil
                    local dialog
                    dialog=require('ui/widget/confirmbox'):new{
                        text=_('Save this page as your cloud reading position? The cloud percentage is kept until WeRead updates it.'),
                        ok_text=_('Sync this page'),cancel_text=_('Keep cloud position'),keep_dialog_open=true,
                        cancel_callback=function() if host._native_direct_position==ctx then M.cancel(host) end end,
                        ok_callback=function()
                            if not ctx.is_current() or ctx.confirm~=dialog then M.cancel(host);return end
                            UI:close(dialog);ctx.confirm=nil;ctx.confirmed_metadata=metadata
                            host:showBusy(_('Rechecking reading position...'),function() M.cancel(host) end);ctx.busy=host.busy_message
                            launch()
                        end}
                    ctx.confirm=dialog;UI:show(dialog);return
                end
                if not Contract.same(metadata,ctx.confirmed_metadata) then
                    fail('The cloud position changed during the check. Your current page is kept.');return
                end
                local started,why=ctx.service:start(metadata,ctx.is_current,function(out,token)
                    if host._native_direct_position~=ctx then return end
                    if not ctx.is_current() then M.cancel(host);return end
                    local confirmed=out.kind=='confirmed' and token and ctx.service:accept(token)
                    if automatic then
                        local reconnect=package.loaded['weread.ui.native_direct_reconnect']
                        if confirmed and reconnect then reconnect.synced(host,entry,ctx.location) end
                        ctx.auto_status=confirmed and 'confirmed' or out.attempted and 'unconfirmed' or 'failed'
                        ctx.auto_metadata=confirmed and metadata or nil;M.cancel(host);return
                    end
                    M.cancel(host)
                    local reconnect=package.loaded['weread.ui.native_direct_reconnect']
                    if confirmed and reconnect then reconnect.synced(host,entry,ctx.location) end
                    if confirmed then require('weread.lib.native_direct_interval').arm_session(host,entry,ctx,metadata,'desired') end
                    host:showInfo(_(confirmed and 'Cloud reading position synced and checked.'
                        or out.attempted and 'The sync result could not be confirmed. Choose sync again to review it.'
                        or 'Could not sync this position. Your current page is kept.'))
                end)
                if not started then fail(why=='pending' and 'A previous position sync needs review. Choose sync again.'
                    or 'Could not sync this position. Your current page is kept.') end
                return
            end
            if ctx.compare then
                local relation=comparison.relation
                local messages={same='The current page matches the cloud reading position.',
                    no_chapter='There is no cloud reading position yet. Your current page is kept.',
                    target_unavailable='The cloud position could not be located in this chapter. Your current page is kept.'}
                if messages[relation] then
                    M.cancel(host)
                    local reconnect=package.loaded['weread.ui.native_direct_reconnect']
                    if relation=='same' and reconnect then reconnect.synced(host,entry,ctx.location) end
                    host:showInfo(_(messages[relation]));return
                end
                if relation=='other_chapter' then
                    local cloud=require('weread.lib.native_direct_cloud');local wanted=comparison.target
                    if not cloud.valid_target(wanted) or wanted.book_id~=entry.book_id
                        or wanted.chapter_uid==entry.chapter_uid then fail();return end
                    if ctx.busy and host.busy_message==ctx.busy then host:closeBusy() end;ctx.busy=nil
                    local confirm
                    confirm=require('ui/widget/confirmbox'):new{
                        text=_('The cloud position is in another chapter. Open the saved chapter or download it if needed?'),
                        ok_text=_('Open cloud chapter'),cancel_text=_('Keep current page'),keep_dialog_open=true,
                        cancel_callback=function()
                            if host._native_direct_position==ctx and ctx.confirm==confirm then ctx.confirm=nil;M.cancel(host) end
                        end,
                        ok_callback=function()
                            if not page_current() or not access_current() then M.cancel(host);return end
                            UI:close(confirm);ctx.confirm=nil
                            host:showBusy(_('Preparing the cloud chapter...'),function() M.cancel(host) end);ctx.busy=host.busy_message
                            local saved=host.settings.get_book and host.settings:get_book(entry.book_id) or nil
                            if type(saved)~='table' or tostring(saved.book_id or saved.bookId or '')~=entry.book_id then saved={} end
                            local function text(value,fallback)
                                return type(value)=='string' and #value<=2048 and not value:find('[%z%c]')
                                    and require('weread.lib.protocol').utf8_substr(value,#value)==value and value or fallback
                            end
                            local book={book_id=entry.book_id,title=text(saved.title,entry.book_id),author=text(saved.author,'')}
                            local target_native,target_web=ctx.native,ctx.web
                            local called,started=pcall(host._native_direct_position_worker.start,host._native_direct_position_worker,function()
                                local function active()
                                    return host.settings:auth_scope_matches(scope) and NativeAccess.matches(host.settings,target_native)
                                        and Currentness.matches(host.settings,target_web)
                                end
                                local value,why=require('weread.lib.native_direct_cloud_target').resolve(host.client,host.settings,
                                    entry,ctx.file,ctx.input,target_native,target_web,active,wanted,book)
                                return value and {resolved=value} or {error=why or 'unavailable'}
                            end,function(result_)
                                if host._native_direct_position~=ctx then return end
                                if not page_current() or not access_current() then M.cancel(host);return end
                                local resolved=type(result_)=='table' and result_.resolved
                                if type(resolved)~='table' or not cloud.same_target(resolved.target,wanted)
                                    or not require('weread.lib.native_direct_path').contains(host.settings,resolved.path)
                                    or not require('weread.lib.native_direct_cache').valid_entry(resolved.entry,entry.book_id,scope.vid)
                                    or resolved.entry.chapter_uid~=wanted.chapter_uid or resolved.entry.chapter_idx~=wanted.chapter_idx then
                                    local why=type(result_)=='table' and result_.error
                                    fail(why=='not_entitled' and 'The cloud chapter is not available to this account.'
                                        or why=='target_unavailable' and 'The cloud position could not be located in the target chapter. Your current page is kept.'
                                        or why=='cloud_changed' and 'The cloud position changed during the check. Your current page is kept.'
                                        or why=='rate_limited' and 'WeRead is limiting requests. Please try again later.'
                                        or why=='auth_expired' and 'E-Ink authorization expired. Please authorize again.'
                                        or why=='web_expired' and 'WeRead login expired. Please sign in again and retry.'
                                        or why=='catalog_changed' and 'The chapter list changed. Please open it again.'
                                        or 'Could not prepare the cloud chapter. Your current page is kept.');return
                                end
                                local handoff=require('weread.lib.native_direct_cloud_handoff').prepare(host,ctx,resolved,function(next_host,next_entry,target,native_,web_)
                                    return require('weread.ui.native_direct_cloud_open').receive(next_host,next_entry,target,native_,web_)
                                end)
                                if not handoff then fail();return end
                                local path=resolved.path;M.cancel(host);host:openFile(path,handoff)
                            end)
                            if not called or not started then fail() end
                        end,
                    }
                    ctx.confirm=confirm;UI:show(confirm);return
                end
                local anchor=comparison.anchor
                local cloud=require('weread.lib.native_direct_cloud')
                if relation~='different' or type(anchor)~='table' or anchor.co~=comparison.cloud_offset
                    or comparison.cloud_offset==p.chapter_offset
                    or not cloud.valid_target(comparison.target) or comparison.target.book_id~=entry.book_id
                    or comparison.target.chapter_uid~=entry.chapter_uid or comparison.target.chapter_idx~=entry.chapter_idx
                    or comparison.target.chapter_offset~=comparison.cloud_offset
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
                                    and cloud.same_target(next_value.target,comparison.target)
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
            host:showInfo(_('The local reading position was checked against the chapter source.'))
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
