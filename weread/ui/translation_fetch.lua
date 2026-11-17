-- Native existing-translation download; original EPUB and its notes stay intact.
local Fetch=require('weread.lib.translation_fetch')
local Source=require('weread.lib.position_source')
local Context=require('weread.lib.source_context')
local Dom=require('weread.lib.source_dom')
local Output=require('weread.lib.notes_export_file')
local WorkerSettings=require('weread.lib.worker_settings')
local UIManager=require('ui/uimanager')
local _,T=require('weread.lib.plugin_util').tr,require('weread.lib.plugin_util').T
local M={}
local function stat(path) return require('libs/libkoreader-lfs').symlinkattributes(path) end
local function same(a,b) return a and b and a.mode=='file' and b.mode=='file' and a.ino==b.ino and a.dev==b.dev and a.size==b.size and a.modification==b.modification end
local function owner(host)
    local doc=host.ui and host.ui.document
    local id=tostring(host:detectWeReadBook() or '')
    local account=host.library_db and host.library_db:accountKey()
    if not doc or not host.ui.doc_settings or not require('weread.lib.read_access').book_id(id) or not account then return nil end
    local mode=host.ui.view and host.ui.view.view_mode or 'page'
    local location=Context.location(doc,mode)
    local member=location and Dom.member(doc,location.xpointer)
    local source=member and Source.document_metadata(doc,id,nil,member.render_path)
    local info=stat(doc.file)
    if not source or source.record.format~='web_xhtml' or not info or info.mode~='file' then return nil end
    return {document=doc,file=doc.file,book_id=id,account=account,session=host._reader_session_gen,
        scope=host.settings:get_auth_scope(),auth=WorkerSettings.fingerprint(host.settings),stat=info,
        mode=mode,location=location,source=source,doc_settings=host.ui.doc_settings}
end
local function current(host,o)
    return o and host.ui and host.ui.document==o.document and o.document.file==o.file
        and tostring(host:detectWeReadBook() or '')==o.book_id and host._reader_session_gen==o.session
        and host.library_db:accountKey()==o.account and host.settings:auth_scope_matches(o.scope)
        and WorkerSettings.fingerprint(host.settings)==o.auth and same(stat(o.file),o.stat)
        and Context.same_location(o.location,Context.location(o.document,o.mode))
end
local function close_result(host)
    local dialog=host._translation_fetch_result;host._translation_fetch_result=nil
    host._translation_fetch_owner=nil
    if dialog then UIManager:close(dialog) end
end
function M.cancel(host)
    close_result(host)
    local job=host.translation_fetch_job;host.translation_fetch_job=nil
    if not job then return end
    if host.translation_fetch_worker then host.translation_fetch_worker:cancel() end
    if job.output then job.output:abort() end
    if job.gate then job.gate:release() end
    if job.busy and host.busy_message==job.busy then host:closeBusy() end
end
function M.view_changed(host)
    local job=host.translation_fetch_job
    if job and not current(host,job.owner) then M.cancel(host) end
    if host._translation_fetch_owner and not current(host,host._translation_fetch_owner) then close_result(host) end
end
local function failed(host,missing)
    host:showInfo(_(missing and 'No existing translation was found for this chapter. The original book is kept.'
        or 'Could not download this chapter’s translation. Check login, network and storage. The original book is kept.'))
end
local function input_for(o,book)
    return {book_id=o.book_id,chapter_uid=o.source.chapter_uid,metadata=o.source.metadata,path=o.file,
        directory=o.file:match('^(.*)/[^/]+$'),title=book and book.title,author=book and book.author,xpointer=o.location.xpointer}
end
local function publish(output,directory,title,bytes)
    if not output:accept(bytes) then return false end
    -- Reserve the final name exclusively, then replace only our empty
    -- placeholder. A prior accepted copy never becomes an overwrite target.
    local reserved=Output.create(directory,title,'epub')
    if not reserved then return false end
    if not reserved:close() or not reserved:owns() or (stat(reserved.path) or {}).size~=0
        or not output:owns() or not os.rename(output.path,reserved.path) then reserved:abort();return false end
    output.path,reserved.path=reserved.path,nil
    return true
end
local function open_copy(host,o,path,result)
    if not current(host,o) then return false end
    local sync=host.progress_sync
    if sync and (sync.uploading or sync.pulling) or host.read_report and host.read_report.job then
        host:showInfo(_('The reader is busy. Please try again shortly.'));return false
    end
    local pref=require('docsettings'):open(path)
    pref:saveSetting('weread_translation',{schema=1,book_id=o.book_id,mode='bilingual',scale=host._translation_scale or 100})
    local good,saved=pcall(pref.flush,pref)
    if not good or not saved then failed(host);return false end
    if sync then sync:begin_cloud_source_navigation() end
    host:openFile(path,function(reader)
        local next_host=reader and reader.weread
        if not next_host or not reader.document or reader.document.file~=path
            or next_host.library_db:accountKey()~=o.account or not next_host.settings:auth_scope_matches(o.scope)
            or tostring(next_host:detectWeReadBook() or '')~=o.book_id then return end
        if next_host.progress_sync then next_host.progress_sync:begin_cloud_source_navigation() end
        if result.target and reader.document:isXPointerInDocument(result.target) then reader.rolling:onGotoXPointer(result.target) end
        if next_host.source_position then next_host.source_position:on_view_changed(true) end
    end)
    return true
end
function M.saved_entry(host)
    local good,o=pcall(owner,host)
    if not good or not o or not o.doc_settings then return nil end
    local copies=o.doc_settings:readSetting('weread_translation_copies',{})
    local entry=type(copies)=='table' and copies[o.source.chapter_uid]
    local dir=o.file:match('^(.*)/[^/]+$')
    if type(entry)~='table' or entry.schema~=1 or entry.book_id~=o.book_id or entry.account~=o.account
        or entry.source_file_id~=o.source.identity.file_id or type(entry.path)~='string' or #entry.path>4096
        or entry.path:find('[%z%c]') or entry.path:match('^(.*)/[^/]+$')~=dir or entry.path==o.file
        or type(entry.file_id)~='string' or #entry.file_id~=64 or not entry.file_id:match('^[a-f0-9]+$') then return nil end
    local info=stat(entry.path)
    if not info or info.mode~='file' or info.size~=entry.bytes then return nil end
    return entry,o,info
end
function M.open_saved(host)
    local entry,o,info=M.saved_entry(host)
    if not entry then failed(host);return false end
    local input=input_for(o)
    host:closeWeReadUI()
    local job={owner=o,started=os.time()};host.translation_fetch_job=job
    host:showBusy(_('Checking saved translation…'),function() if host.translation_fetch_job==job then M.cancel(host) end end)
    job.busy=host.busy_message
    if not host.translation_fetch_worker then
        local made,worker=pcall(function() return require('weread.lib.memory_worker'):new{scheduler=UIManager,codec=host.client} end)
        if not made then M.cancel(host);failed(host);return false end;host.translation_fetch_worker=worker
    end
    local good,started=pcall(host.translation_fetch_worker.start,host.translation_fetch_worker,function() return Fetch.saved(input,entry.path) end,function(result)
        if host.translation_fetch_job~=job then return end
        if not current(host,o) or not same(stat(entry.path),info) then M.cancel(host);return end
        M.cancel(host)
        if type(result)~='table' or not result.ok or result.file_id~=entry.file_id or result.bytes~=entry.bytes then failed(host);return end
        open_copy(host,o,entry.path,result)
    end)
    if not good or not started then M.cancel(host);failed(host);return false end
    return true
end
local function success(host,o,output,result)
    local dialog
    dialog=require('ui/widget/confirmbox'):new{keep_dialog_open=true,
        text=T(_('Downloaded %1 translated blocks as a separate chapter copy. The original file and its notes are kept.'),result.blocks)
            ..'\n\n'.._(result.target and 'Open at the matching original paragraph.' or 'No unique matching paragraph was found. Open from this chapter’s beginning.'),
        ok_text=_('Open translated copy'),cancel_text=_('Close'),
        cancel_callback=function() if host._translation_fetch_result==dialog then host._translation_fetch_result=nil;host._translation_fetch_owner=nil end end,
        ok_callback=function()
            if host._translation_fetch_result~=dialog or not current(host,o) then return end
            if not output:owns() or (stat(output.path) or {}).size~=result.bytes then close_result(host);failed(host);return end
            close_result(host);open_copy(host,o,output.path,result)
        end}
    host._translation_fetch_result=dialog;host._translation_fetch_owner=o;UIManager:show(dialog)
end
function M.start(host)
    host:closeWeReadUI()
    local captured,o=pcall(owner,host)
    if not captured or not o then failed(host);return false end
    if not host:isNetworkOnline() then host:showOffline(_('Download existing translation'));return false end
    if not host:requireLogin(true,false) then return false end
    if host.downloader and (host.downloader._active_job or host.downloader._pending_start or host.downloader._scheduled_start) then
        host:showInfo(_('The reader is busy. Please try again shortly.'));return false
    end
    local directory=o.file:match('^(.*)/[^/]+$')
    local locked,gate=pcall(function() return require('weread.lib.book_operation').prepare(directory) end)
    if not locked or not gate then failed(host);return false end
    local book=host.settings:get_book(o.book_id) or {}
    local title=(book.title or _('WeRead'))..'-translation'
    local created,output=pcall(Output.create,directory,title,'epub_part')
    if not created or not output then gate:release();failed(host);return false end
    local input=input_for(o,book)
    local job={owner=o,output=output,gate=gate,started=os.time()};host.translation_fetch_job=job
    host:showBusy(_('Downloading existing translation…\nTap or press a key to cancel.'),function() if host.translation_fetch_job==job then M.cancel(host) end end)
    job.busy=host.busy_message
    if not host.translation_fetch_worker then
        local ok,worker=pcall(function() return require('weread.lib.memory_worker'):new{scheduler=UIManager,codec=host.client} end)
        if not ok then M.cancel(host);failed(host);return false end;host.translation_fetch_worker=worker
    end
    local launched,started=pcall(host.translation_fetch_worker.start,host.translation_fetch_worker,function()
        local capture=WorkerSettings.capture(host.settings)
        local result=Fetch.run(host.client,host.settings,input,output);result.auth=capture();return result
    end,function(result)
        if host.translation_fetch_job~=job then return end
        local age=os.time()-job.started
        if not current(host,o) or age<0 or age>75 then M.cancel(host);return end
        if type(result)~='table' or result.ok~=true or result.chapter_uid~=input.chapter_uid
            or type(result.bytes)~='number' or result.bytes<1 or result.bytes>Fetch.MAX_OUTPUT or result.bytes%1~=0
            or type(result.blocks)~='number' or result.blocks<1 or result.blocks>20000 or result.blocks%1~=0
            or type(result.file_id)~='string' or not result.file_id:match('^[a-f0-9]+$') or #result.file_id~=64
            or result.target~=nil and (type(result.target)~='string' or #result.target>4096 or not result.target:match('^/body/DocFragment%[1%]/body')) then
            local missing=type(result)=='table' and result.reason=='missing';M.cancel(host);failed(host,missing);return
        end
        if result.auth and not WorkerSettings.merge(host.settings,o.auth,result.auth) then M.cancel(host);failed(host);return end
        o.auth=WorkerSettings.fingerprint(host.settings)
        local committed,published=pcall(publish,output,directory,title,result.bytes)
        if not committed or not published then M.cancel(host);failed(host);return end
        job.output=nil;M.cancel(host)
        -- Keep an offline entry on the original document's existing sidecar;
        -- it never replaces its native bookmarks or current book cache path.
        local copies=o.doc_settings:readSetting('weread_translation_copies',{})
        local records={};for k,v in pairs(type(copies)=='table' and copies or {}) do records[k]=v end
        records[input.chapter_uid]={schema=1,book_id=o.book_id,account=o.account,source_file_id=o.source.identity.file_id,
            path=output.path,file_id=result.file_id,bytes=result.bytes,blocks=result.blocks,target=result.target}
        o.doc_settings:saveSetting('weread_translation_copies',records)
        local saved,where=pcall(o.doc_settings.flush,o.doc_settings)
        if not saved or not where then host:showInfo(_('The translated copy was saved, but its offline shortcut could not be saved. Check storage.')) end
        success(host,o,output,result)
    end)
    if not launched or not started then M.cancel(host);failed(host);return false end
    return true
end
return M
