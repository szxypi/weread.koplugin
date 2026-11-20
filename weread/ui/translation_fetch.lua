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
    local generation=package.loaded['weread.ui.translation_generation'];if generation then generation.cancel(host) end
    local annotations=package.loaded['weread.ui.translation_annotations'];if annotations then annotations.cancel(host) end
    local prompt=host._translation_resume_prompt;host._translation_resume_prompt=nil;host._translation_resume_owner=nil
    if prompt then UIManager:close(prompt) end
    close_result(host)
    local job=host.translation_fetch_job;host.translation_fetch_job=nil
    if not job then return end
    if host.translation_fetch_worker then host.translation_fetch_worker:cancel() end
    if job.output then job.output:abort() end
    if job.gate then job.gate:release() end
    if job.busy and host.busy_message==job.busy then host:closeBusy() end
end
function M.view_changed(host)
    local generation=package.loaded['weread.ui.translation_generation'];if generation then generation.view_changed(host) end
    local annotations=package.loaded['weread.ui.translation_annotations'];if annotations then annotations.view_changed(host) end
    local job=host.translation_fetch_job
    if job and not current(host,job.owner) then M.cancel(host) end
    if host._translation_resume_owner and not current(host,host._translation_resume_owner) then M.cancel(host) end
    if host._translation_fetch_owner and not current(host,host._translation_fetch_owner) then close_result(host) end
end
local function failed(host,missing,full,limit,range)
    host:showInfo(_(range and (limit and 'The selected chapters exceed the translation size limit. The original book is kept.'
        or missing and 'No existing translation was found in the selected chapters. The original book is kept.'
        or 'Could not download the selected chapters. Check login, network and storage. The original book is kept.')
        or limit and 'This book exceeds the current full-book translation size limit. The original book is kept.'
        or missing and (full and 'No existing translation was found for this book. The original book is kept.'
        or 'No existing translation was found for this chapter. The original book is kept.')
        or full and 'Could not download the full-book translation copy. Check login, network and storage. The original book is kept.'
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
local function open_copy(host,o,path,result,after_open)
    if not current(host,o) then return false end
    if not require('weread.lib.translation_record_isolation').check(o.file,path) then
        host:showInfo(_('The translated copy may share reading records with the original book, so it cannot be opened safely. The original notes are kept.'))
        return false
    end
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
        if after_open then after_open(reader,next_host) end
    end)
    return true
end
M.open_copy=open_copy
M.is_current=current
M.capture_owner=owner
function M.saved_entry(host)
    local good,o=pcall(owner,host)
    if not good or not o or not o.doc_settings then return nil end
    local copies=o.doc_settings:readSetting('weread_translation_copies',{})
    local dir=o.file:match('^(.*)/[^/]+$')
    for _,key in ipairs({'__range_'..o.source.chapter_uid,'__full',o.source.chapter_uid}) do
        local entry=type(copies)=='table' and copies[key]
        if type(entry)=='table' and entry.schema==1 and entry.book_id==o.book_id and entry.account==o.account
            and entry.source_file_id==o.source.identity.file_id and type(entry.path)=='string' and #entry.path<=4096
            and not entry.path:find('[%z%c]') and entry.path:match('^(.*)/[^/]+$')==dir and entry.path~=o.file
            and type(entry.file_id)=='string' and #entry.file_id==64 and entry.file_id:match('^[a-f0-9]+$') then
            local info=stat(entry.path)
            if info and info.mode=='file' and info.size==entry.bytes
                and not (info.ino==o.stat.ino and info.dev==o.stat.dev) then return entry,o,info end
        end
    end
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
    host.translation_fetch_worker.timeout=75
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
local function success(host,o,output,result,full,cleanup_failed,range)
    local dialog
    dialog=require('ui/widget/confirmbox'):new{keep_dialog_open=true,
        text=(range and T(_('Downloaded existing translations for %1 of %2 selected chapters as a separate copy. The original file and its notes are kept.'),result.translated_chapters,result.chapters)
            or full and T(_('Downloaded existing translations for %1 of %2 chapters as a separate book copy. The original file and its notes are kept.'),result.translated_chapters,result.chapters)
            or T(_('Downloaded %1 translated blocks as a separate chapter copy. The original file and its notes are kept.'),result.blocks))
            ..'\n\n'.._(((full or range) and result.matched or not full and not range and result.target) and 'Open at the matching original paragraph.' or 'No unique matching paragraph was found. Open from this chapter’s beginning.')
            ..(cleanup_failed and '\n\n'.._('The copy was saved, but interrupted chapters could not be removed. You can delete them from the download menu.') or ''),
        ok_text=_('Open translated copy'),cancel_text=_('Close'),
        cancel_callback=function() if host._translation_fetch_result==dialog then host._translation_fetch_result=nil;host._translation_fetch_owner=nil end end,
        ok_callback=function()
            if host._translation_fetch_result~=dialog or not current(host,o) then return end
            if not output:owns() or (stat(output.path) or {}).size~=result.bytes then close_result(host);failed(host);return end
            close_result(host);open_copy(host,o,output.path,result)
        end}
    host._translation_fetch_result=dialog;host._translation_fetch_owner=o;UIManager:show(dialog)
end
function M.start(host,full,resume)
    local range=full=='range'
    full=full==true
    local multiple=full or range
    host:closeWeReadUI()
    local captured,o=pcall(owner,host)
    if not captured or not o then failed(host,false,full,false,range);return false end
    if not host:isNetworkOnline() then host:showOffline(_(range and 'Download existing translations for next chapters'
        or full and 'Download existing translations for full book' or 'Download existing translation'));return false end
    if not host:requireLogin(true,false) then return false end
    local resume_store
    if full and type(host.library_db.open)=='function' then
        resume_store=require('weread.lib.translation_resume'):new(host.library_db,host.client,o.scope)
        local saved=resume==nil and resume_store:summary(o.book_id,o.source.identity.file_id)
        if saved then
            local dialog
            local dated,when=pcall(os.date,'%Y-%m-%d %H:%M',saved.started)
            if not dated or type(when)~='string' then when=_('Unknown') end
            local function choose(value)
                if host._translation_resume_prompt~=dialog or not current(host,o) then return end
                host._translation_resume_prompt,host._translation_resume_owner=nil,nil
                UIManager:close(dialog);M.start(host,true,value)
            end
            dialog=require('ui/widget/buttondialog'):new{
                title=T(_('An interrupted download started at %1 has %2 saved chapters. Translations may have changed since then. Continue with these chapters, or download the whole book again?'),when,saved.count),
                buttons={{{text=_('Continue download'),callback=function() choose(true) end}},
                    {{text=_('Download again'),callback=function() choose(false) end}},
                    {{text=_('Delete saved chapters'),callback=function()
                        if host._translation_resume_prompt~=dialog or not current(host,o) then return end
                        host._translation_resume_prompt,host._translation_resume_owner=nil,nil
                        UIManager:close(dialog)
                        if resume_store:clear{book_id=o.book_id,generation=saved.generation} then
                            host:showInfo(_('The interrupted download was removed.'))
                        else host:showInfo(_('Could not remove the interrupted download. Check storage and try again.')) end
                    end}},
                    {{text=_('Cancel'),callback=function() if host._translation_resume_prompt==dialog then M.cancel(host) end end}}},
            }
            host._translation_resume_prompt,host._translation_resume_owner=dialog,o;UIManager:show(dialog);return true
        end
    end
    if host.downloader and (host.downloader._active_job or host.downloader._pending_start or host.downloader._scheduled_start) then
        host:showInfo(_('The reader is busy. Please try again shortly.'));return false
    end
    local directory=o.file:match('^(.*)/[^/]+$')
    local locked,gate=pcall(function() return require('weread.lib.book_operation').prepare(directory) end)
    if not locked or not gate then failed(host,false,full,false,range);return false end
    local book=host.settings:get_book(o.book_id) or {}
    local title=(book.title or _('WeRead'))..(range and '-partial-translation' or full and '-full-translation' or '-translation')
    local created,output=pcall(Output.create,directory,title,'epub_part')
    if not created or not output then gate:release();failed(host,false,full,false,range);return false end
    local input=input_for(o,book)
    local job={owner=o,output=output,gate=gate,started=os.time()};host.translation_fetch_job=job
    job.cancel=function() if host.translation_fetch_job==job then M.cancel(host) end end
    if multiple then
        local shown=pcall(function()
            local dialog=require('weread.ui.download_dialog'):new{
                title=_(range and 'Download existing translations for next chapters' or 'Download existing translations for full book'),
                description=_(range and 'Downloading the current and next two chapters, then checking the copy.'
                    or 'Downloading chapters and checking the completed copy. Completed chapters are saved when storage is available.'),
                buttons={{{text=_('Cancel'),callback=job.cancel}}},
            }
            host:closeBusy();host.busy_message=dialog;job.busy=dialog;dialog:show()
        end)
        if not shown then M.cancel(host);failed(host,false,full,false,range);return false end
    else
        host:showBusy(_('Downloading existing translation…\nTap or press a key to cancel.'),job.cancel)
    end
    job.busy=host.busy_message
    if not host.translation_fetch_worker then
        local ok,worker=pcall(function() return require('weread.lib.memory_worker'):new{scheduler=UIManager,codec=host.client} end)
        if not ok then M.cancel(host);failed(host,false,full,false,range);return false end;host.translation_fetch_worker=worker
    end
    host.translation_fetch_worker.timeout=range and 300 or full and 3600 or 75
    local launched,started=pcall(host.translation_fetch_worker.start,host.translation_fetch_worker,function(progress)
        local capture=WorkerSettings.capture(host.settings)
        local good,result=pcall(multiple and Fetch.run_book or Fetch.run,host.client,host.settings,input,output,progress,resume_store,resume==true,range and 3 or nil)
        if not good then
            if multiple and (result=='translation_fetch/source_limit' or result=='translation_fetch/asset_limit'
                or result=='translation_fetch/content_limit' or result=='translation_fetch/chapter_limit') then return {ok=false,reason='limit'} end
            error(result,0)
        end
        result.auth=capture();return result
    end,function(result)
        if host.translation_fetch_job~=job then return end
        local age=os.time()-job.started
        if not current(host,o) or age<0 or age>(range and 300 or full and 3600 or 75) then M.cancel(host);return end
        local target=type(result)=='table' and result.target
        local number,tail
        if type(target)=='string' then number,tail=target:match('^/body/DocFragment%[(%d+)%](/body.*)$') end
        local ordinal=number and tonumber(number)
        local valid_range=true
        if range then
            local ids=type(result)=='table' and result.chapter_ids
            valid_range=type(ids)=='table' and #ids>=1 and #ids<=3 and #ids==result.chapters and ids[1]==input.chapter_uid
            local seen={}
            if valid_range then
                for key,value in pairs(ids) do
                    if type(key)~='number' or key%1~=0 or key<1 or key>#ids or type(value)~='string'
                        or not require('weread.lib.read_access').book_id(value) or seen[value] then valid_range=false;break end
                    seen[value]=true
                end
            end
        end
        if type(result)~='table' or result.ok~=true or result.chapter_uid~=input.chapter_uid or not valid_range
            or type(result.bytes)~='number' or result.bytes<1 or result.bytes>Fetch.MAX_OUTPUT or result.bytes%1~=0
            or type(result.blocks)~='number' or result.blocks<1 or result.blocks>20000 or result.blocks%1~=0
            or type(result.file_id)~='string' or not result.file_id:match('^[a-f0-9]+$') or #result.file_id~=64
            or multiple and (type(result.chapters)~='number' or result.chapters%1~=0 or result.chapters<1 or result.chapters>Fetch.MAX_BOOK_CHAPTERS
                or type(result.translated_chapters)~='number' or result.translated_chapters%1~=0
                or result.translated_chapters<1 or result.translated_chapters>result.chapters or type(result.matched)~='boolean' or not target)
            or target~=nil and (not ordinal or ordinal<1 or ordinal>(multiple and result.chapters or 1) or #target>4096
                or tail~='/body' and tail:sub(1,6)~='/body/' and tail:sub(1,6)~='/body.') then
            local missing=type(result)=='table' and result.reason=='missing'
            local limit=type(result)=='table' and result.reason=='limit';M.cancel(host);failed(host,missing,full,limit,range);return
        end
        if result.auth and not WorkerSettings.merge(host.settings,o.auth,result.auth) then M.cancel(host);failed(host,false,full,false,range);return end
        o.auth=WorkerSettings.fingerprint(host.settings)
        local committed,published=pcall(publish,output,directory,title,result.bytes)
        if not committed or not published then M.cancel(host);failed(host,false,full,false,range);return end
        local cleanup_failed=false
        if resume_store and type(result.resume_token)=='table' and result.resume_token.book_id==input.book_id
            and type(result.resume_token.generation)=='string' and #result.resume_token.generation==32
            and result.resume_token.generation:match('^[a-f0-9]+$') then cleanup_failed=not resume_store:clear(result.resume_token) end
        job.output=nil;M.cancel(host)
        -- Keep an offline entry on the original document's existing sidecar;
        -- it never replaces its native bookmarks or current book cache path.
        local copies=o.doc_settings:readSetting('weread_translation_copies',{})
        local records={};for k,v in pairs(type(copies)=='table' and copies or {}) do records[k]=v end
        local entry={schema=1,book_id=o.book_id,account=o.account,source_file_id=o.source.identity.file_id,
            path=output.path,file_id=result.file_id,bytes=result.bytes,blocks=result.blocks,target=result.target}
        if range then
            for _,uid in ipairs(result.chapter_ids) do records['__range_'..uid]=entry end
        else
            if full then for key in pairs(records) do
                if type(key)=='string' and key:match('^__range_[1-9]%d*$') then records[key]=nil end
            end end
            records[full and '__full' or input.chapter_uid]=entry
        end
        o.doc_settings:saveSetting('weread_translation_copies',records)
        local saved,where=pcall(o.doc_settings.flush,o.doc_settings)
        if not saved or not where then host:showInfo(_('The translated copy was saved, but its offline shortcut could not be saved. Check storage.')) end
        success(host,o,output,result,full,cleanup_failed,range)
    end,multiple and function(value)
        if host.translation_fetch_job~=job then return end
        if not current(host,o) or host.busy_message~=job.busy then M.cancel(host);return end
        if type(value)=='number' and value%1==0 and value>=0 and value<=98
            and value>(job.progress or -1) then
            job.progress=value;job.busy:reportProgress(value)
        end
    end or nil)
    if not launched or not started then M.cancel(host);failed(host,false,full,false,range);return false end
    return true
end
return M
