-- Standalone chapter links use the existing downloader, then enter the native
-- reader at a verified literal anchor. No WebView or new network protocol.
local Task=require('weread.lib.chapter_link_worker')
local History=require('weread.lib.chapter_link_history')
local Identity=require('weread.lib.book_file_identity')
local Context=require('weread.lib.source_context')
local BookLinks=require('weread.lib.book_link_paths')
local Crypto=require('weread.lib.crypto')
local UI=require('ui/uimanager')
local _=require('weread.lib.plugin_util').tr
local M={}
local metadata={'chapterUid','uid','chapterIdx','index','href','file','filename','fileName','path','chapterPath'}
local function dense(values,maximum)
    if type(values)~='table' or #values>maximum then return false end
    local count=0
    for key in pairs(values) do
        if type(key)~='number' or key%1~=0 or key<1 or key>#values then return false end
        count=count+1
    end
    return count==#values
end
local function account(host) return host.library_db and host.library_db:accountKey() end
local function marker(host) return host.ui and host.ui.rolling and host.ui.rolling.xpointer end
local function location(host)
    return Context.location(host.ui.document,host.ui.view and host.ui.view.view_mode or 'page')
end
local function catalog(host,id)
    local book=host.settings:get_book(id)
    if type(book)=='table' and host.ensureChaptersLoaded then book.chapters=host:ensureChaptersLoaded(book) end
    if type(book)~='table' or not dense(book.chapters,Task.MAX_CATALOG) or #book.chapters==0 then return end
    local chapters,stamp={},{}
    for index,chapter in ipairs(book.chapters) do
        if type(chapter)~='table' then return end
        local item,row={},{}
        for n,key in ipairs(metadata) do
            local value=chapter[key]
            if value~=nil and type(value)~='string' and type(value)~='number' then return end
            item[key]=value
            if value==nil then row[n]=false else row[n]=value end
        end
        if chapter.files~=nil and not dense(chapter.files,2048) then return end
        item.files={};row[#metadata+1]=item.files
        for n,file in ipairs(chapter.files or {}) do
            if type(file)~='string' then return end
            item.files[n]=file
        end
        chapters[index],stamp[index]=item,row
    end
    return book,chapters,Crypto.sha256_hex(host.client:json_encode(stamp))
end
local function describe(host)
    local ui=host.ui
    local id=host._current_weread_book_id
    if not id or not ui or not ui.document or not ui.rolling or not ui.link then return end
    id=tostring(id)
    local identity=Identity.read_document(ui.document,id)
    if identity.chapter_count~=1 then return end
    local book,chapters,digest=catalog(host,id)
    if not book then return end
    local chapter,full=select(2,host:getChapterInfoFromFile(book,ui.document.file))
    if not chapter or full then return end
    local uid=tostring(chapter.chapterUid or chapter.uid or '')
    if uid=='' or not book.cached_chapters or book.cached_chapters[uid]~=ui.document.file then return end
    local auth=host.settings:get_auth_scope()
    if not account(host) or not host.settings:auth_scope_matches(auth) then return end
    return {book_id=id,uid=uid,path=ui.document.file,file_id=identity.file_id,chapters=chapters,
        catalog=digest,owner=account(host),auth=auth}
end
local function same(host,job,closed)
    local elapsed=os.time()-job.started
    if elapsed<0 or elapsed>180 or account(host)~=job.owner
        or not host.settings:auth_scope_matches(job.auth) then return false end
    if closed then return (host._reader_session_gen or 0)==job.session+1 end
    if host._chapter_link_job~=job or host.ui.document~=job.document
        or (host._reader_session_gen or 0)~=job.session or marker(host)~=job.marker
        or not Context.same_location(job.location,location(host)) then return false end
    local current=describe(host)
    return current and current.uid==job.uid and current.path==job.path
        and current.file_id==job.file_id and current.catalog==job.catalog
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
function M.view_changed(host)
    local job=host._chapter_link_job
    if job and not job.dispatched and not same(host,job,false) then M.cancel(host) end
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
        location={xpointer=marker(host),marker_xpointer=job.from_xpointer},back=back,forward=forward}
end
local function open(host,job,result)
    if not same(host,job,false) then M.cancel(host);return end
    local book=host.settings:get_book(job.book_id)
    if not book or not book.cached_chapters or book.cached_chapters[result.target_uid]~=result.target_path then fail(host,job);return end
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
        local valid=not job.cancelled and same(host,job,true)
        if host._chapter_link_job==job then host._chapter_link_job=nil end
        local next_host=reader and reader.weread
        local current=next_host and describe(next_host)
        if not valid or not current or next_host==host or current.book_id~=job.book_id
            or current.owner~=job.owner or not next_host.settings:auth_scope_matches(job.auth)
            or current.catalog~=job.catalog or current.uid~=result.target_uid or current.path~=result.target_path
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
            reader.rolling:onGotoXPointer(xp,point and point.marker_xpointer)
            applied=reader.rolling.xpointer==xp
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
    if not same(host,job,false) then if host._chapter_link_job==job then M.cancel(host) end;return false end
    if not job.worker then
        local ok,value=pcall(function() return require('weread.lib.memory_worker'):new{scheduler=UI,codec=host.client,max_bytes=128*1024} end)
        if not ok then fail(host,job);return false end
        job.worker=value
    end
    local ok,started=pcall(job.worker.start,job.worker,task,function(result)
        if not same(host,job,false) then if host._chapter_link_job==job then M.cancel(host) end;return end
        if type(result)~='table' or result.kind~='ready' and result.kind~='needs_download' then fail(host,job);return end
        callback(result)
    end)
    if not ok or not started then fail(host,job);return false end
    return true
end
local prepare
local function download(host,job,result)
    if job.downloaded then fail(host,job);return end
    local book=host.settings:get_book(job.book_id)
    if book and host.ensureChaptersLoaded then book.chapters=host:ensureChaptersLoaded(book) end
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
            if not same(host,job,false) then if host._chapter_link_job==job then M.cancel(host) end;return end
            if not ok then fail(host,job);return end
            busy(host,job);prepare(host,job)
        end)
    end
    job.download_callback=callback
    local ok,started=pcall(host.downloader.start,host.downloader,book,{chapter},'chapter',{
        single_chapter=true,silent_completion=true,offer_read=false,on_complete=callback})
    if not ok or not started then fail(host,job) end
end
prepare=function(host,job)
    local book=host.settings:get_book(job.book_id)
    local cached={};for uid,path in pairs(book.cached_chapters or {}) do cached[tostring(uid)]=path end
    local input={book_id=job.book_id,chapter_uid=job.uid,file=job.path,file_id=job.file_id,
        native_uri=job.native_uri,chapters=job.chapters,cached_chapters=cached}
    return work(host,job,function() return Task.prepare(input) end,function(result)
        if result.kind=='ready' then open(host,job,result) else download(host,job,result) end
    end)
end
local function start(host,current)
    M.cancel(host)
    current.document=host.ui.document;current.session=host._reader_session_gen or 0
    current.marker=marker(host);current.location=location(host);current.started=os.time()
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
    end,function(result) open(host,job,result) end)
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
    if not describe(host) then return false end
    local link=host.ui.link
    local state={link=link,document=host.ui.document,wrappers={},originals={}}
    host._chapter_links=state
    local function active() return host._chapter_links==state and host.ui.document==state.document and host.ui.link==link end
    local function install(name,handler)
        local original=link[name];state.originals[name]=original
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
        local current=describe(host)
        if not current then return false end
        local job=start(host,current);job.native_uri=target.xpointer;job.from_xpointer=target.from_xpointer;job.direction='new'
        prepare(host,job);return true
    end)
    install('onGoBackLink',function() return go_history(host,'back') end)
    install('onGoForwardLink',function() return go_history(host,'forward') end)
    return true
end
return M
