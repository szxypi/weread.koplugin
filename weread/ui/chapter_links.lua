-- Standalone chapter links use the existing downloader, then enter the native
-- reader at a verified literal anchor. No WebView or new network protocol.
local Task=require('weread.lib.chapter_link_worker')
local History=require('weread.lib.chapter_link_history')
local NativePosition=require('weread.lib.chapter_link_position')
local Identity=require('weread.lib.book_file_identity')
local Context=require('weread.lib.source_context')
local BookLinks=require('weread.lib.book_link_paths')
local ReadAccess=require('weread.lib.read_access')
local Crypto=require('weread.lib.crypto')
local UI=require('ui/uimanager')
local _=require('weread.lib.plugin_util').tr
local M={}
local metadata={'chapterUid','uid','chapterIdx','index','href','file','filename','fileName','path','chapterPath'}
local max_chapter_files=2048
local function dense(values,maximum)
    if type(values)~='table' then return false end
    local length=#values
    if length>maximum then return false end
    local count=0
    for key in pairs(values) do
        if type(key)~='number' or key%1~=0 or key<1 or key>length then return false end
        count=count+1
    end
    return count==length
end
local function account(host) return host.library_db and host.library_db:accountKey() end
local function marker(host) return host.ui and host.ui.rolling and host.ui.rolling.xpointer end
local function location(host)
    return Context.location(host.ui.document,host.ui.view and host.ui.view.view_mode or 'page')
end
local function capture_catalog(host,source)
    local chapters,stamp={},{}
    for index,chapter in ipairs(source) do
        if type(chapter)~='table' then return end
        local item,row={},{}
        for n,key in ipairs(metadata) do
            local value=chapter[key]
            if value~=nil and type(value)~='string' and type(value)~='number' then return end
            item[key]=value
            if value==nil then row[n]=false else row[n]=value end
        end
        if chapter.files~=nil and not dense(chapter.files,max_chapter_files) then return end
        item.files={};row[#metadata+1]=item.files
        for n,file in ipairs(chapter.files or {}) do
            if type(file)~='string' then return end
            item.files[n]=file
        end
        chapters[index],stamp[index]=item,row
    end
    return chapters,Crypto.sha256_hex(host.client:json_encode(stamp))
end

-- An active job owns a copy of the link fields and file lists. Re-read
-- the catalog at each boundary, then compare without allocating another
-- projection or serializing it. History frames only hold the digest.
local function matches_catalog(source,expected)
    if #source~=#expected then return false end
    for index,chapter in ipairs(source) do
        if type(chapter)~='table' then return false end
        local snapshot=expected[index]
        for _,key in ipairs(metadata) do
            if chapter[key]~=snapshot[key] then return false end
        end
        local files=chapter.files
        if files==nil then
            if #snapshot.files~=0 then return false end
        else
            if not dense(files,max_chapter_files) or #files~=#snapshot.files then return false end
            for i,path in ipairs(files) do
                if path~=snapshot.files[i] then return false end
            end
        end
    end
    return true
end
local function standalone_reader(host)
    local ui=host.ui
    local id=host._current_weread_book_id
    if not id or not ui or not ui.document or not ui.rolling or not ui.link then return end
    id=tostring(id)
    local identity=Identity.read_document(ui.document,id)
    if identity.chapter_count~=1 then return end
    return ui,id,identity
end
local function describe(host,expected)
    local ui,id,identity=standalone_reader(host)
    if not ui then return end
    local owner=account(host)
    if not owner or expected and (owner~=expected.owner or id~=expected.book_id) then return end
    local auth=expected and expected.auth or host.settings:get_auth_scope()
    if not auth or not host.settings:auth_scope_matches(auth) then return end
    local book=ReadAccess.load_cached_book(host.settings,id)
    if book and host.ensureChaptersLoaded then book.chapters=host:ensureChaptersLoaded(book,true) end
    if type(book)~='table' or not dense(book.chapters,Task.MAX_CATALOG) or #book.chapters==0 then return end
    local chapters,digest
    if expected then
        if not matches_catalog(book.chapters,expected.chapters) then return end
    else
        chapters,digest=capture_catalog(host,book.chapters)
        if not chapters then return end
    end
    local chapter,full=select(2,host:getChapterInfoFromFile(book,ui.document.file))
    if not chapter or full then return end
    local uid=tostring(chapter.chapterUid or chapter.uid or '')
    if uid=='' or ReadAccess.cached_chapter(book.cached_chapters,uid)~=ui.document.file then return end
    return {book_id=id,uid=uid,path=ui.document.file,file_id=identity.file_id,chapters=chapters,
        catalog=digest,owner=owner,auth=auth},book
end
local function live(job)
    local elapsed=os.time()-job.started
    return not job.cancelled and elapsed>=0 and elapsed<=180
end
local function same_view(host,job)
    local ui=host.ui
    return host._chapter_link_job==job and ui and ui.document==job.document
        and ui.document.file==job.path and ui.link==job.link
        and tostring(host._current_weread_book_id or '')==job.book_id
        and (host._reader_session_gen or 0)==job.session and marker(host)==job.marker
        and Context.same_location(job.location,location(host))
end
local function dismiss(host,job)
    if job.busy and host.busy_message==job.busy then host:closeBusy() end
    job.busy=nil
end
function M.cancel(host)
    local job=host._chapter_link_job;host._chapter_link_job=nil
    if not job then return end
    job.cancelled=true
    if job.worker then job.worker:cancel() end
    if job.download_callback then host.downloader:cancelRequest(job.download_callback,'chapter_link_cancelled') end
    dismiss(host,job)
end
local function cancel_if_current(host,job)
    if host._chapter_link_job==job then M.cancel(host) end
end
local function current_book(host,job)
    if live(job) and same_view(host,job) then
        local current,book=describe(host,job)
        if current and current.uid==job.uid and current.path==job.path and current.file_id==job.file_id then return book end
    end
    cancel_if_current(host,job)
end
function M.view_changed(host)
    local job=host._chapter_link_job
    -- Repeated viewport notifications only check the active reader. Results
    -- still reload the catalog and recheck authorization before they are used.
    if job and not job.dispatched and not (live(job) and same_view(host,job)) then M.cancel(host) end
end
local function fail(host,job)
    if host._chapter_link_job~=job then return end
    M.cancel(host)
    host:showTransientInfo(_('Could not open this chapter link. The current reading position is kept.'),4)
end
local function busy(host,job)
    host:showBusy(_('Checking chapter link…'),function() if host._chapter_link_job==job then M.cancel(host) end end)
    job.busy=host.busy_message
end
local function frame(host,job,direction,index)
    local back,forward=History.stacks(host.ui.link,direction,index)
    return {book_id=job.book_id,uid=job.uid,path=job.path,file_id=job.file_id,sha256=job.source_sha256,
        owner=job.owner,auth=job.auth,catalog=job.catalog,
        location=NativePosition.capture(host.ui,job.from_xpointer),back=back,forward=forward}
end
local function open(host,job,result,book)
    if type(result.target_path)~='string' or result.target_path==''
        or ReadAccess.cached_chapter(book.cached_chapters,result.target_uid)~=result.target_path then fail(host,job);return end
    job.source_sha256=result.source_sha256
    local departing=frame(host,job,job.direction,job.index)
    local sync=host.progress_sync
    if sync then
        sync:checkpoint_local('chapter_link_departure')
        sync:begin_file_resume_departure()
    end
    dismiss(host,job);job.dispatched=true
    local used=false
    host:openFile(result.target_path,function(reader)
        if used then return false end
        used=true
        local valid=live(job) and (host._reader_session_gen or 0)==job.session+1
            and account(host)==job.owner and host.settings:auth_scope_matches(job.auth)
        if host._chapter_link_job==job then host._chapter_link_job=nil end
        local next_host=reader and reader.weread
        if not valid or not next_host or next_host==host then return false end
        local current=describe(next_host,job)
        if not current or current.uid~=result.target_uid or current.path~=result.target_path
            or current.file_id~=result.target_file_id then return false end
        local next_sync=next_host.progress_sync
        if not next_sync or next_sync.navigation_generation~=0 or next_sync.pending_jump or next_sync.verified
            or next_host.cloud_source_request then return false end
        local resume=next_sync:begin_file_resume()
        if not resume then return false end
        local doc=reader.document
        local point=job.destination and job.destination.location
        local xp=point and point.xpointer or result.anchor and '#_doc_fragment_0_ ' .. result.anchor
        -- Native external URI fragments have already been decoded. The literal
        -- ID, including any remaining percent signs, must never be decoded again.
        local applied=false
        if xp and doc:isXPointerInDocument(xp) then
            applied=NativePosition.restore(reader,point or {xpointer=xp})
        elseif not xp then
            reader.rolling:onGotoPage(1);applied=true
        end
        if applied then
            History.restore(reader.link,job.destination,job.direction,departing,reader.link:getCurrentLocation())
        end
        next_sync:finish_file_resume(resume,applied)
        if not applied then next_host:showTransientInfo(_('Could not locate the linked text in this chapter.'),4) end
        return applied
    end)
end
local function work(host,job,task,callback)
    if not (live(job) and same_view(host,job)) then cancel_if_current(host,job);return false end
    if not job.worker then
        local ok,value=pcall(function() return require('weread.lib.memory_worker'):new{scheduler=UI,codec=host.client,max_bytes=128*1024} end)
        if not ok then fail(host,job);return false end
        job.worker=value
    end
    local ok,started=pcall(job.worker.start,job.worker,task,function(result)
        local book=current_book(host,job)
        if not book then return end
        if type(result)~='table' or result.kind~='ready' and result.kind~='needs_download' then fail(host,job);return end
        callback(result,book)
    end)
    if not ok or not started then fail(host,job);return false end
    return true
end
local prepare
local function download(host,job,result,book)
    if job.downloaded then fail(host,job);return end
    local chapter
    for _i,item in ipairs(book.chapters or {}) do
        if tostring(item.chapterUid or item.uid or '')==result.target_uid then chapter=item;break end
    end
    if not chapter then fail(host,job);return end
    job.downloaded=true;dismiss(host,job)
    local callback
    callback=function(ok)
        if job.download_callback~=callback then return end
        job.download_callback=nil
        UI:scheduleIn(0.1,function()
            local refreshed=current_book(host,job)
            if not refreshed then return end
            if not ok then fail(host,job);return end
            busy(host,job);prepare(host,job,refreshed)
        end)
    end
    job.download_callback=callback
    local ok,started=pcall(host.downloader.start,host.downloader,book,{chapter},'chapter',{
        single_chapter=true,silent_completion=true,offer_read=false,on_complete=callback})
    if not ok or not started then fail(host,job) end
end
prepare=function(host,job,book)
    local cached={}
    for uid in pairs(book.cached_chapters or {}) do
        local key=tostring(uid)
        cached[key]=ReadAccess.cached_chapter(book.cached_chapters,key)
    end
    local input={book_id=job.book_id,chapter_uid=job.uid,file=job.path,file_id=job.file_id,
        native_uri=job.native_uri,chapters=job.chapters,cached_chapters=cached}
    return work(host,job,function() return Task.prepare(input) end,function(result,checked)
        if result.kind=='ready' then open(host,job,result,checked) else download(host,job,result,checked) end
    end)
end
local function start(host,current)
    current.document=host.ui.document;current.link=host.ui.link;current.session=host._reader_session_gen or 0
    current.marker=marker(host);current.location=location(host);current.started=os.time()
    M.cancel(host)
    host._chapter_link_job=current;busy(host,current)
    return current
end
local function go_history(host,direction)
    local target,index=History.candidate(host.ui.link,direction)
    if not target then return false end
    local current=describe(host)
    if not current or target.owner~=current.owner or target.book_id~=current.book_id
        or target.catalog~=current.catalog or not host.settings:auth_scope_matches(target.auth) then return true end
    local job=start(host,current);job.direction=direction;job.index=index;job.destination=target
    work(host,job,function()
        local source=Task.read(job.path,job.book_id,job.uid,job.file_id)
        local destination=Task.read(target.path,target.book_id,target.uid,target.file_id)
        if not source or not destination or destination.sha256~=target.sha256 then return {kind='unavailable'} end
        return {kind='ready',source_sha256=source.sha256,target_uid=target.uid,target_path=target.path,
            target_file_id=target.file_id,target_sha256=destination.sha256}
    end,function(result,book) open(host,job,result,book) end)
    return true
end
function M.detach(host)
    local job=host._chapter_link_job
    if job and not job.dispatched then M.cancel(host) end
    local state=host._chapter_links;host._chapter_links=nil
    if not state then return end
    for name,wrapper in pairs(state.wrappers) do
        if state.link[name]==wrapper then state.link[name]=state.originals[name] end
    end
end
function M.attach(host)
    M.detach(host)
    -- Document identity is already pinned when the reader opens. Defer the
    -- catalog and account checks until a candidate crosses a file boundary.
    local ui=standalone_reader(host)
    if not ui then return false end
    local link=ui.link
    local state={link=link,document=ui.document,wrappers={},originals={}}
    host._chapter_links=state
    local function active() return host._chapter_links==state and host.ui==ui and ui.document==state.document and ui.link==link end
    local function install(name,handler)
        local original=link[name]
        if type(original)~='function' then return end
        state.originals[name]=original
        local wrapper=function(link_self,...)
            if active() and handler(...) then return true end
            return original(link_self,...)
        end
        state.wrappers[name]=wrapper;link[name]=wrapper
    end
    install('onGotoLink',function(target)
        if type(target)~='table' or type(target.xpointer)~='string' then return false end
        local pointer=BookLinks.native_xpointer(state.document,target.xpointer)
        if state.document:isXPointerInDocument(pointer) then return false end
        if not BookLinks.native_uri_key(Task.RENDER_PATH,target.xpointer) then return false end
        local current,book=describe(host)
        if not current then return false end
        local job=start(host,current);job.native_uri=target.xpointer;job.from_xpointer=target.from_xpointer;job.direction='new'
        prepare(host,job,book);return true
    end)
    install('onGoBackLink',function() return go_history(host,'back') end)
    install('onGoForwardLink',function() return go_history(host,'forward') end)
    return true
end
return M
