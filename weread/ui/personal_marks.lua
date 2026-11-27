-- Account-owned cloud highlights/bookmarks in separate reader layers. No native note
-- mutations, document rewriting, reader movement or progress uploads.
local UI=require('ui/uimanager')
local Marks=require('weread.lib.my_cloud_marks')
local Cache=require('weread.lib.my_cloud_marks_store')
local Source=require('weread.lib.position_source')
local Dom=require('weread.lib.source_dom')
local Task=require('weread.lib.personal_mark_task')
local Contract=require('weread.lib.mark_edit_contract')
local Overlay=require('weread.ui.xpointer_overlay')
local Chapters=require('weread.lib.personal_mark_chapters')
local M={KEY='weread_personal_marks',BOOKMARK_KEY='weread_cloud_bookmarks'}
local NETWORK_RECHECK_SECONDS=30
local function current(host,s)
    return host._personal_marks==s and host.ui and host.ui.document==s.document and s.document.file==s.file
        and (s.direct or host:detectWeReadBook()==s.book)
        and host._reader_session_gen==s.session and host.library_db:accountKey()==s.account
        and host.settings:auth_scope_matches(s.scope) and (host._translation_mode==nil or host._translation_mode=='original')
end
local function dirty(host) UI:setDirty(host.dialog or host.ui,'ui') end
local function enabled(host,s)
    return current(host,s) and not s.suspended and host.settings:get('cache',{}).show_annotations~=false
end
local function cancel_work(s)
    s.generation=s.generation+1;s.job=nil
    if s.task then UI:unschedule(s.task);s.task=nil end
    if s.worker then s.worker:cancel() end
    if s.probe_worker then s.probe_worker:cancel();s.probing=false end
end
local function close_picker(s)
    local picker=s.picker;s.picker=nil
    if picker then UI:close(picker) end
end
local function clear(host,s)
    close_picker(s)
    s.indicator.allow_page_index=false
    s.records={};s.bookmarks={};s.overlay:setRecords({},true);s.indicator:setRecords({});dirty(host)
end
local function metadata(host,s)
    local ok,value=pcall(function()
        if s.direct then
            local e=s.entry;local identity=require('weread.lib.book_file_identity').read_document(s.document,s.book)
            if not e or identity.file_id~=e.file_id or identity.book_version~=e.book_version then return nil end
            return {metadata=e.file_id..e.source_sha256..e.key,chapter_uid=e.chapter_uid,record={format='web_xhtml'}}
        end
        local xp=s.document:getXPointer();local member=Dom.member(s.document,xp)
        return member and Source.document_metadata(s.document,s.book,nil,member.render_path)
    end)
    return ok and value or nil
end
local function selected(host)
    local h=host.ui and host.ui.highlight
    return h and (h.selected_text or h.hold_pos or h.select_mode==true)
end
local function schedule(host,s,callback)
    if s.task then UI:unschedule(s.task) end
    local task
    task=function()
        if s.task~=task then return end;s.task=nil
        if not current(host,s) or s.suspended then return end
        if selected(host) then schedule(host,s,callback);return end
        callback()
    end
    s.task=task;UI:scheduleIn(.1,task)
end
local function worker(host,s,task,callback)
    s.worker=s.worker or require('weread.lib.memory_worker'):new{scheduler=UI,codec=host.client,max_bytes=8*1024*1024}
    local generation=s.generation
    local ok,started=pcall(s.worker.start,s.worker,task,function(result)
        if current(host,s) and not s.suspended and generation==s.generation then callback(result) end
    end)
    return ok and started
end
local function insert(s,records,row)
    local low,high=1,#records+1
    while low<high do
        local mid=math.floor((low+high)/2);local other=records[mid]
        local order=s.document:compareXPointers(row.pos0,other.pos0)
        if order==1 or order==0 and row.bookmarkId<other.bookmarkId then high=mid else low=mid+1 end
    end
    table.insert(records,low,row)
    return low
end
local batch,load
local function same_job(host,s,job)
    if not enabled(host,s) or s.editing or s.job~=job then return false end
    local m=metadata(host,s)
    return m and m.metadata==job.metadata
end
batch=function(host,s,job)
    if not same_job(host,s,job) then return end
    if job.cursor>#job.rows then s.job=nil;s.complete=true;s.indicator.allow_page_index=true;return end
    local rows={};for i=job.cursor,math.min(#job.rows,job.cursor+Task.BATCH-1) do rows[#rows+1]=job.rows[i] end
    job.cursor=job.cursor+#rows
    local started=worker(host,s,function()
        if s.direct then return Task.prepare_direct(host.client,host.settings,host.library_db,s.file,s.entry,job.metadata,rows,
            function() return host.isNetworkOnline and host:isNetworkOnline() or false end) end
        return Task.prepare(s.file,s.book,job.metadata,rows)
    end,function(result)
        if not same_job(host,s,job) then return end
        if type(result)~='table' or result.metadata~=job.metadata or type(result.rows)~='table' then s.job=nil;return end
        local originals={};for _i,row in ipairs(rows) do originals[row.bookmarkId]={hash=Contract.row_hash(row),bookmark=row.type==0 or nil,text=row.markText} end
        local expected={}
        if #result.rows>Task.BATCH then s.job=nil;return end
        for _i,row in ipairs(result.rows) do
            local original=type(row)=='table' and originals[row.bookmarkId]
            if not original or expected[row.bookmarkId] or original.hash~=row.reference_hash or original.bookmark~=row.bookmark then s.job=nil;return end
            expected[row.bookmarkId]=row
        end
        local pending,points,verify={},{},{}
        local last_yield=os.clock()
        local thread=coroutine.create(function()
            local options={is_current=function() return same_job(host,s,job) end,
                yield=function() if os.clock()-last_yield>=.02 then coroutine.yield();last_yield=os.clock() end end}
            job.index=job.index or (s.direct and Dom.open_direct_prepared(s.document,s.book,job.uid,s.identity,options)
                or not s.direct and Dom.open_prepared(s.document,s.book,job.metadata,options))
            if not job.index then return false end
            for _i,row in ipairs(result.rows) do
                if row.bookmark then
                    local point,reason
                    if not job.direct_search then point,reason=job.index:locate_anchor(row.anchor) end
                    if s.direct and (job.direct_search or reason=='source_dom/walk_diverged') then
                        job.direct_search=true
                        point=job.index:locate_point_search(row.anchor,originals[row.bookmarkId].text,Task.MAX_NATIVE_BYTES)
                    end
                    if point and point.co==row.anchor.co then
                        points[#points+1]={bookmarkId=row.bookmarkId,pos0=point.xpointer,chapter_uid=job.uid,range=job.ranges[row.bookmarkId]}
                    end
                else
                    local span,reason
                    if not job.direct_search then span,reason=job.index:locate_span(row.first_anchor,row.last_anchor,Task.MAX_NATIVE_BYTES) end
                    if s.direct and (job.direct_search or reason=='source_dom/walk_diverged') then
                        job.direct_search=true
                        span=job.index:locate_span_search(row.first_anchor,row.last_anchor,originals[row.bookmarkId].text,Task.MAX_NATIVE_BYTES)
                    end
                    if span then
                        pending[row.bookmarkId]={bookmarkId=row.bookmarkId,thoughtId=job.thoughts[row.bookmarkId],
                            pos0=span.pos0,pos1=span.pos1,chapter_uid=job.uid,
                            range=job.ranges[row.bookmarkId],style=job.styles[row.bookmarkId]}
                        verify[#verify+1]={bookmarkId=row.bookmarkId,text=span.text,normalized_sha256=expected[row.bookmarkId].normalized_sha256}
                    end
                end
                if os.clock()-last_yield>=.02 then coroutine.yield();last_yield=os.clock() end
            end
            return true
        end)
        local advance
        advance=function()
            if not same_job(host,s,job) then return end
            local ok,value=coroutine.resume(thread)
            if not ok then s.job=nil;return end
            if coroutine.status(thread)~='dead' then schedule(host,s,advance);return end
            if not value then s.job=nil;return end
            local function finish(ids)
                if not same_job(host,s,job) then return end
                if type(ids)~='table' then s.job=nil;return end
                local seen,first_changed={}
                for _i,id in ipairs(ids) do if pending[id] and not seen[id] then
                    local at=insert(s,s.records,pending[id]);first_changed=math.min(first_changed or at,at);seen[id]=true
                end end
                for _i,row in ipairs(points) do insert(s,s.bookmarks,row) end
                if first_changed then s.overlay:setRecords(s.records,true,first_changed) end
                if #points>0 then s.indicator:setRecords(s.bookmarks) end
                if first_changed or #points>0 then dirty(host) end
                schedule(host,s,function() batch(host,s,job) end)
            end
            if #verify==0 then finish({})
            elseif not worker(host,s,function() return Task.verify(verify) end,finish) then s.job=nil end
        end
        schedule(host,s,advance)
    end)
    if not started then s.job=nil end
end
-- DNS resolution may block even when Wi-Fi is connected. Probe in a separate
-- worker, without cancelling the currently visible notes or their preparation.
local function probe_network(host,s)
    local now=os.time()
    if s.probing or now<(s.next_network_probe or 0) or not host.isNetworkOnline then return end
    s.next_network_probe=now+NETWORK_RECHECK_SECONDS
    s.probe_worker=s.probe_worker or require('weread.lib.memory_worker'):new{scheduler=UI,codec=host.client}
    local generation=s.generation
    s.probing=true
    local ok,started=pcall(s.probe_worker.start,s.probe_worker,function()
        return {online=host:isNetworkOnline() and true or false}
    end,function(result)
        if generation==s.generation then s.probing=false end
        if current(host,s) and not s.suspended and not s.editing and not s.loading and enabled(host,s)
            and generation==s.generation and not s.remote_attempted and type(result)=='table' and result.online==true then
            cancel_work(s);s.loading=false;load(host,s,true)
        end
    end)
    if not ok or not started then s.probing=false end
end
function M.update(host)
    local s=host._personal_marks;if not s then return end
    local show=enabled(host,s)
    if s.overlay.enabled~=show then s.overlay:setEnabled(show);dirty(host) end
    if s.indicator.enabled~=show then s.indicator:setEnabled(show);dirty(host) end
    if not show then
        close_picker(s)
        if s.job or s.task or s.loading or s.probing then cancel_work(s);s.loading=false;s.metadata=nil;s.complete=false end
        return
    end
    if s.editing or s.loading then return end
    if s.direct and s.loaded and not s.remote_attempted then probe_network(host,s) end
    if not s.snapshot and not s.loaded then
        load(host,s,not s.remote_attempted and 'detect' or false);return
    end
    local m=metadata(host,s)
    if not m or not m.record or m.record.format~='web_xhtml' and m.record.format~='web_txt' then
        cancel_work(s);s.metadata=nil;clear(host,s);return
    end
    if s.metadata==m.metadata and (s.job or s.complete) then return end
    cancel_work(s);s.metadata=m.metadata;s.complete=false;clear(host,s)
    if not s.snapshot and not s.thought_snapshot then return end
    local uid=m.chapter_uid;local rows,ranges,styles,thoughts={},{},{},{}
    for _i,row in ipairs(Chapters.rows(s,'snapshot',uid)) do
        if row.type==1 or row.type==0 then
            rows[#rows+1]=row;ranges[row.bookmarkId]=row.range
            styles[row.bookmarkId]=(row.style==1 or row.style==2) and row.style or 0
        end
    end
    -- Prefix with a control byte: validated bookmark IDs cannot contain one,
    -- so a thought and a mark can never alias in worker results.
    if s.direct then for _i,row in ipairs(Chapters.rows(s,'thought_snapshot',uid)) do
        if require('weread.lib.my_thought_target').can_locate(row) then
            local key='\1'..row.reviewId
            rows[#rows+1]={bookmarkId=key,type=1,chapterUid=row.chapterUid,markText=row.abstract,range=row.range}
            ranges[key]=row.range;styles[key]=3;thoughts[key]=row.reviewId
        end
    end end
    table.sort(rows,function(a,b) return a.bookmarkId<b.bookmarkId end)
    local job={metadata=m.metadata,uid=uid,rows=rows,ranges=ranges,styles=styles,thoughts=thoughts,cursor=1};s.job=job
    schedule(host,s,function() batch(host,s,job) end)
end
load=function(host,s,online)
    s.loading=true
    if online==true then s.remote_attempted=true end
    if online=='detect' then s.next_network_probe=os.time()+NETWORK_RECHECK_SECONDS end
    local started=worker(host,s,function()
        local checked_online=online==true or online=='detect' and host.isNetworkOnline and host:isNetworkOnline() or false
        local entry
        if s.direct then
            entry=require('weread.lib.native_direct_cache').identify(host.settings,s.scope.vid,s.file,function()
                return host.settings:auth_scope_matches(s.scope)
            end)
            if not entry or entry.book_id~=s.book or entry.file_id~=s.identity.file_id
                or entry.book_version~=s.identity.book_version then return {error='file_changed'} end
        end
        local access=checked_online and require('weread.lib.native_read_access').capture(host.settings)
        local value=Task.load(host.client,host.library_db,s.book,access,checked_online)
        value.entry=entry;value.checked_online=checked_online
        value.access_fingerprint=access and access.fingerprint or false
        return value
    end,function(result)
        s.loading=false
        local checked_online=type(result)=='table' and result.checked_online==true
        local fingerprint=type(result)=='table' and result.access_fingerprint
        if checked_online then s.remote_attempted=true end
        if s.direct then
            local entry=type(result)=='table' and result.entry
            if not entry or not require('weread.lib.native_direct_cache').valid_entry(entry,s.book,s.scope.vid)
                or entry.file_id~=s.identity.file_id or entry.book_version~=s.identity.book_version then
                s.loaded=false;s.entry=nil;s.snapshot=nil;s.thought_snapshot=nil
                s._mark_chapters=nil;s._thought_chapters=nil;clear(host,s);return
            end
            s.entry=entry
        end
        s.loaded=true
        local value
        if type(result)=='table' and result.refreshed then
            local saved
            value,saved=Cache:new(host.library_db,host.client):writeProjected(result.snapshot,s.book)
            if value and not saved then load(host,s,false);return end
        else
            local ok;ok,value=pcall(Marks.validate,host.client,type(result)=='table' and result.snapshot,s.book)
            if not ok then value=nil end
        end
        s.snapshot=value;s._mark_chapters=nil
        if s.direct then
            -- Fetch separately so two independently bounded note sets cannot
            -- overflow the worker pipe when both contain many entries. Bind
            -- the second read to the first grant without copying credentials
            -- over the pipe or reading their file on the reader event loop.
            s.loading=true
            local started_thoughts=worker(host,s,function()
                local access
                if checked_online and type(fingerprint)=='string' then
                    local candidate=require('weread.lib.native_read_access').capture(host.settings)
                    if candidate and candidate.fingerprint==fingerprint then access=candidate end
                end
                return Task.load_thoughts(host.client,host.library_db,s.book,access,checked_online)
            end,function(result_thoughts)
                s.loading=false
                local valid,thoughts
                if type(result_thoughts)=='table' and result_thoughts.refreshed then
                    local saved
                    thoughts,saved=Cache:new(host.library_db,host.client,'thoughts'):writeProjected(result_thoughts.snapshot,s.book)
                    valid=thoughts~=nil and saved
                else
                    valid,thoughts=pcall(require('weread.lib.my_cloud_thoughts').validate,host.client,
                        type(result_thoughts)=='table' and result_thoughts.snapshot,s.book)
                end
                if valid then s.thought_snapshot=thoughts;s._thought_chapters=nil end
                s.metadata=nil;M.update(host)
            end)
            if started_thoughts then return end
            s.loading=false
        end
        s.metadata=nil;M.update(host)
    end)
    if not started then s.loading=false end
    return started
end
function M.attach(host)
    M.detach(host)
    if not host.settings or not host.settings.get_auth_scope or not host.library_db or not host.detectWeReadBook then return false end
    local document=host.ui and host.ui.document;local book=Marks.display_id(host:detectWeReadBook())
    local direct,identity=false,nil
    if document and not book and require('weread.lib.native_direct_path').contains(host.settings,document.file) then
        local ok,raw=pcall(document.getDocumentFileContent,document,require('weread.lib.book_file_identity').PATH)
        local parsed=ok and require('weread.lib.book_file_identity').decode(raw)
        if parsed and parsed.chapter_count==1 and Marks.id(parsed.book_id) then
            book=parsed.book_id;identity=require('weread.lib.book_file_identity').read_document(document,book)
            direct=identity.file_id==parsed.file_id and identity.book_version==parsed.book_version
            if not direct then book=nil end
        end
    end
    local scope=host.settings:get_auth_scope();local account=host.library_db and host.library_db:accountKey()
    if not document or not book or not account or not scope or not host.settings:auth_scope_matches(scope)
        or not document.info or document.info.has_pages or not host.ui.view or not host.ui.view.registerViewModule then return false end
    local s={book=book,document=document,file=document.file,scope=scope,account=account,session=host._reader_session_gen,generation=0,
        records={},bookmarks={},loading=true,direct=direct,identity=identity}
    local screen=require('device').screen;local BB=require('ffi/blitbuffer')
    local painter=require('weread.ui.personal_mark_painter')
    local overlay=Overlay:new{records={},painter=painter.paint,prepare_painter=painter.prepare,
        style={width=math.max(1,screen:scaleBySize(1)),wave_step=math.max(1,screen:scaleBySize(1)),color=BB.Color8(0)}}
    local indicator=require('weread.ui.bookmark_indicator'):new{scale=function(n) return screen:scaleBySize(n) end,
        color=BB.Color8(0),allow_page_index=false}
    s.overlay=overlay;s.indicator=indicator;host._personal_marks=s
    for _i,layer in ipairs({overlay,indicator}) do
        local paint=layer.paintTo
        function layer:paintTo(...)
            local show=enabled(host,s);if self.enabled~=show then self:setEnabled(show) end;return paint(self,...)
        end
    end
    host.ui.view:registerViewModule(M.KEY,overlay)
    host.ui.view:registerViewModule(M.BOOKMARK_KEY,indicator)
    schedule(host,s,function()
        load(host,s,enabled(host,s) and 'detect' or false)
    end)
    return true
end
function M.detach(host)
    local s=host._personal_marks;host._personal_marks=nil
    if not s then return end
    cancel_work(s);close_picker(s)
    s.overlay:setEnabled(false);s.indicator:setEnabled(false)
    if host.ui and host.ui.view and host.ui.view.view_modules then
        host.ui.view.view_modules[M.KEY]=nil;host.ui.view.view_modules[M.BOOKMARK_KEY]=nil
    end
    dirty(host)
end
function M.pause(host)
    local s=host._personal_marks;if not s then return end
    s.editing=true;s.loading=false;cancel_work(s);close_picker(s)
end
function M.changed(host,snapshot)
    local s=host._personal_marks
    if not s or not current(host,s) or type(snapshot)~='table' or snapshot.book_id~=s.book then return end
    local ok,value=pcall(Marks.validate,host.client,snapshot,s.book);if not ok then return end
    cancel_work(s);s.loading=false;s.loaded=true;s.snapshot=value;s._mark_chapters=nil;s.metadata=nil;s.editing=false;s.complete=false;clear(host,s);M.update(host)
end
function M.thoughts_changed(host,snapshot)
    local s=host._personal_marks
    if not s or not s.direct or not current(host,s) or type(snapshot)~='table' or snapshot.book_id~=s.book then return end
    local ok,value=pcall(require('weread.lib.my_cloud_thoughts').validate,host.client,snapshot,s.book);if not ok then return end
    cancel_work(s);s.loading=false;s.thought_snapshot=value;s._thought_chapters=nil;s.metadata=nil;s.complete=false;clear(host,s);M.update(host)
end
function M.resume(host)
    local s=host._personal_marks;if not s or not s.editing then return end
    s.editing=false;s.metadata=nil
    if s.suspended then return end
    if not s.snapshot then load(host,s,false) else M.update(host) end
end
function M.suspend(host)
    local s=host._personal_marks;if not s then return end
    s.suspended=true;s.loading=false;cancel_work(s);close_picker(s);s.overlay:setEnabled(false);s.indicator:setEnabled(false)
end
function M.wake(host)
    local s=host._personal_marks;if not s then return end
    s.suspended=false;s.metadata=nil;s.complete=false
    if not s.snapshot then load(host,s,false) else M.update(host) end
end
function M.network_connected(host)
    local s=host._personal_marks
    if not s or not s.direct or not enabled(host,s) or s.editing then return end
    cancel_work(s);s.loading=false;load(host,s,true)
end
function M.invalidate(host)
    local s=host._personal_marks;if not s then return end
    s.overlay:invalidate();s.indicator:invalidate();M.update(host)
end
function M.available(host)
    local s=host._personal_marks;if not s or not current(host,s) then return false end
    if #s.records>0 or #s.bookmarks>0 then return true end
    if s.complete then return false end
    local m=metadata(host,s);if not m or not m.record or m.record.format~='web_xhtml' and m.record.format~='web_txt' then return false end
    for _i,row in ipairs(Chapters.rows(s,'snapshot',m.chapter_uid)) do
        if require('weread.lib.my_mark_target').can_locate(row)
            or require('weread.lib.bookmark_point').can_locate(row,not Marks.id(s.book) or m.record.format=='web_txt') then return true end
    end
    if s.direct then for _i,row in ipairs(Chapters.rows(s,'thought_snapshot',m.chapter_uid)) do
        if require('weread.lib.my_thought_target').can_locate(row) then return true end
    end end
    return false
end
local function open_record(host,s,record,bookmark)
    if not enabled(host,s) then return false end
    if bookmark then
        if not host:showMyCloudBookmarks(s.book) then return false end
    elseif record.thoughtId then
        if not host:showMyCloudThoughts(s.book) then return false end
    elseif not host:showMyCloudMarks(s.book) then return false end
    local owner=host._my_marks_owner
    for _i,item in ipairs(owner and owner.menu.item_table or {}) do
        if item.my_note_id==(record.thoughtId or record.bookmarkId) then item.callback();return true end
    end
    if owner and owner.value then
        if record.thoughtId then M.thoughts_changed(host,owner.value) else M.changed(host,owner.value) end
    end
    return true
end
local function note_preview(row,thought)
    if not row then return '' end
    local value=thought and row.content or row.markText
    if type(value)~='string' or value=='' then value=row.abstract end
    if type(value)~='string' or value=='' then return '' end
    value=value:gsub('[%z%c]',' '):gsub('%s+',' ')
    local shortened=require('weread.lib.protocol').utf8_substr(value,48)
    return #shortened<#value and shortened..'…' or shortened
end
local function choose_records(host,s,records,bookmarks,pos)
    if #records==1 then return open_record(host,s,records[1],bookmarks) end
    if type(host.showList)~='function' then return false end
    close_picker(s)
    local _=require('weread.lib.i18n').tr
    local generation=s.generation;local items,menu={}
    local marks,thoughts={},{}
    for _,row in ipairs(s.snapshot and s.snapshot.updated or {}) do marks[row.bookmarkId]=row end
    for _,row in ipairs(s.thought_snapshot and s.thought_snapshot.reviews or {}) do thoughts[row.reviewId]=row end
    for index,record in ipairs(records) do
        local preview=note_preview(record.thoughtId and thoughts[record.thoughtId] or marks[record.bookmarkId],record.thoughtId~=nil)
        local label=_(bookmarks and 'Bookmark' or record.thoughtId and 'Thought' or 'Highlight')..' '..index
        items[#items+1]={text=preview~='' and label..': '..preview or label,my_note_id=record.thoughtId or record.bookmarkId,
            my_note_kind=bookmarks and 'bookmark' or record.thoughtId and 'thought' or 'mark',
            callback=function()
                if s.picker~=menu then return end
                close_picker(s)
                if not enabled(host,s) or s.generation~=generation then return end
                if bookmarks then
                    local still_visible=false
                    for _,item in ipairs(s.indicator:hitTestAll(pos)) do if item==record then still_visible=true;break end end
                    if not still_visible then return end
                end
                open_record(host,s,record,bookmarks)
            end}
    end
    menu=host:showList(_('WeRead notes'),items,nil,{thought_text=true})
    s.picker=menu
    if menu then
        local on_close=menu.onCloseWidget
        menu.onCloseWidget=function(instance,...)
            if s.picker==instance then s.picker=nil end
            if on_close then return on_close(instance,...) end
        end
    end
    return menu~=nil
end
function M.tap(host,ges,bookmarks_only)
    local s=host._personal_marks;if not s or not enabled(host,s) or not ges or not ges.pos then return false end
    local bookmarks=s.indicator:hitTestAll(ges.pos)
    if #bookmarks>0 then return choose_records(host,s,bookmarks,true,ges.pos) end
    if bookmarks_only then return false end
    local records=s.overlay:hitTestAll(ges.pos)
    if #records==0 then return false end
    return choose_records(host,s,records,false,ges.pos)
end
return M
