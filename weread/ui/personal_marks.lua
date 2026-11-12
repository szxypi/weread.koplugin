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
local M={KEY='weread_personal_marks',BOOKMARK_KEY='weread_cloud_bookmarks'}
local function current(host,s)
    return host._personal_marks==s and host.ui and host.ui.document==s.document and s.document.file==s.file
        and host:detectWeReadBook()==s.book
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
end
local function clear(host,s)
    s.records={};s.bookmarks={};s.overlay:setRecords({},true);s.indicator:setRecords({});dirty(host)
end
local function metadata(host,s)
    local ok,value=pcall(function()
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
end
local batch,load
local function same_job(host,s,job)
    if not enabled(host,s) or s.editing or s.job~=job then return false end
    local m=metadata(host,s)
    return m and m.metadata==job.metadata
end
batch=function(host,s,job)
    if not same_job(host,s,job) then return end
    if job.cursor>#job.rows then s.job=nil;s.complete=true;return end
    local rows={};for i=job.cursor,math.min(#job.rows,job.cursor+Task.BATCH-1) do rows[#rows+1]=job.rows[i] end
    job.cursor=job.cursor+#rows
    local started=worker(host,s,function() return Task.prepare(s.file,s.book,job.metadata,rows) end,function(result)
        if not same_job(host,s,job) then return end
        if type(result)~='table' or result.metadata~=job.metadata or type(result.rows)~='table' then s.job=nil;return end
        local originals={};for _i,row in ipairs(rows) do originals[row.bookmarkId]={hash=Contract.row_hash(row),bookmark=row.type==0 or nil} end
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
            job.index=job.index or Dom.open_prepared(s.document,s.book,job.metadata,{is_current=function() return same_job(host,s,job) end,
                yield=function() if os.clock()-last_yield>=.02 then coroutine.yield();last_yield=os.clock() end end})
            if not job.index then return false end
            for _i,row in ipairs(result.rows) do
                if row.bookmark then
                    local point=job.index:locate_anchor(row.anchor)
                    if point and point.co==row.anchor.co then
                        points[#points+1]={bookmarkId=row.bookmarkId,pos0=point.xpointer,chapter_uid=job.uid,range=job.ranges[row.bookmarkId]}
                    end
                else
                    local span=job.index:locate_span(row.first_anchor,row.last_anchor,Task.MAX_NATIVE_BYTES)
                    if span then
                        pending[row.bookmarkId]={bookmarkId=row.bookmarkId,pos0=span.pos0,pos1=span.pos1,chapter_uid=job.uid,
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
            local verifying=worker(host,s,function() return Task.verify(verify) end,function(ids)
                if not same_job(host,s,job) then return end
                if type(ids)~='table' then s.job=nil;return end
                local seen={}
                for _i,id in ipairs(ids) do if pending[id] and not seen[id] then insert(s,s.records,pending[id]);seen[id]=true end end
                for _i,row in ipairs(points) do insert(s,s.bookmarks,row) end
                s.overlay:setRecords(s.records,true);s.indicator:setRecords(s.bookmarks);dirty(host);schedule(host,s,function() batch(host,s,job) end)
            end)
            if not verifying then s.job=nil end
        end
        schedule(host,s,advance)
    end)
    if not started then s.job=nil end
end
function M.update(host)
    local s=host._personal_marks;if not s then return end
    local show=enabled(host,s)
    if s.overlay.enabled~=show then s.overlay:setEnabled(show);dirty(host) end
    if s.indicator.enabled~=show then s.indicator:setEnabled(show);dirty(host) end
    if not show then
        if s.job or s.task or s.loading then cancel_work(s);s.loading=false;s.metadata=nil;s.complete=false end
        return
    end
    if s.editing or s.loading then return end
    if not s.snapshot and not s.loaded then
        load(host,s,not s.remote_attempted and host.isNetworkOnline and host:isNetworkOnline() or false);return
    end
    local m=metadata(host,s)
    if not m or not m.record or m.record.format~='web_xhtml' then cancel_work(s);s.metadata=nil;clear(host,s);return end
    if s.metadata==m.metadata and (s.job or s.complete) then return end
    cancel_work(s);s.metadata=m.metadata;s.complete=false;clear(host,s)
    if not s.snapshot then return end
    local uid=m.chapter_uid;local rows,ranges,styles={},{},{}
    for _i,row in ipairs(s.snapshot.updated) do
        if (row.type==1 or row.type==0) and tostring(row.chapterUid)==uid then
            rows[#rows+1]=row;ranges[row.bookmarkId]=row.range;styles[row.bookmarkId]=row.style or 0
        end
    end
    table.sort(rows,function(a,b) return a.bookmarkId<b.bookmarkId end)
    local job={metadata=m.metadata,uid=uid,rows=rows,ranges=ranges,styles=styles,cursor=1};s.job=job
    schedule(host,s,function() batch(host,s,job) end)
end
load=function(host,s,online)
    s.loading=true
    if online then s.remote_attempted=true end
    local access=online and require('weread.lib.native_read_access').capture(host.settings)
    local started=worker(host,s,function() return Task.load(host.client,host.library_db,s.book,access,online) end,function(result)
        s.loading=false
        s.loaded=true
        local ok,value=pcall(Marks.validate,host.client,type(result)=='table' and result.snapshot,s.book)
        if not ok then return end
        if result.refreshed then
            local saved=Cache:new(host.library_db,host.client):write(value)
            if not saved then
                load(host,s,false);return
            end
        end
        s.snapshot=value;s.metadata=nil;M.update(host)
    end)
    if not started then s.loading=false end
    return started
end
function M.attach(host)
    M.detach(host)
    if not host.settings or not host.settings.get_auth_scope or not host.library_db or not host.detectWeReadBook then return false end
    local document=host.ui and host.ui.document;local book=Marks.id(host:detectWeReadBook())
    local scope=host.settings:get_auth_scope();local account=host.library_db and host.library_db:accountKey()
    if not document or not book or not account or not scope or not host.settings:auth_scope_matches(scope)
        or not document.info or document.info.has_pages or not host.ui.view or not host.ui.view.registerViewModule then return false end
    local s={book=book,document=document,file=document.file,scope=scope,account=account,session=host._reader_session_gen,generation=0,
        records={},bookmarks={},loading=true}
    local screen=require('device').screen;local BB=require('ffi/blitbuffer')
    local overlay=Overlay:new{records={},painter=require('weread.ui.personal_mark_painter').paint,
        style={width=math.max(1,screen:scaleBySize(1)),wave_step=math.max(1,screen:scaleBySize(1)),color=BB.Color8(0)}}
    local indicator=require('weread.ui.bookmark_indicator'):new{scale=function(n) return screen:scaleBySize(n) end,color=BB.Color8(0)}
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
        load(host,s,enabled(host,s) and host.isNetworkOnline and host:isNetworkOnline() or false)
    end)
    return true
end
function M.detach(host)
    local s=host._personal_marks;host._personal_marks=nil
    if not s then return end
    cancel_work(s);s.overlay:setEnabled(false);s.indicator:setEnabled(false)
    if host.ui and host.ui.view and host.ui.view.view_modules then
        host.ui.view.view_modules[M.KEY]=nil;host.ui.view.view_modules[M.BOOKMARK_KEY]=nil
    end
    dirty(host)
end
function M.pause(host)
    local s=host._personal_marks;if not s then return end
    s.editing=true;s.loading=false;cancel_work(s)
end
function M.changed(host,snapshot)
    local s=host._personal_marks
    if not s or not current(host,s) or type(snapshot)~='table' or snapshot.book_id~=s.book then return end
    local ok,value=pcall(Marks.validate,host.client,snapshot,s.book);if not ok then return end
    cancel_work(s);s.loading=false;s.loaded=true;s.snapshot=value;s.metadata=nil;s.editing=false;s.complete=false;clear(host,s);M.update(host)
end
function M.resume(host)
    local s=host._personal_marks;if not s or not s.editing then return end
    s.editing=false;s.metadata=nil
    if s.suspended then return end
    if not s.snapshot then load(host,s,false) else M.update(host) end
end
function M.suspend(host)
    local s=host._personal_marks;if not s then return end
    s.suspended=true;s.loading=false;cancel_work(s);s.overlay:setEnabled(false);s.indicator:setEnabled(false)
end
function M.wake(host)
    local s=host._personal_marks;if not s then return end
    s.suspended=false;s.metadata=nil;s.complete=false
    if not s.snapshot then load(host,s,false) else M.update(host) end
end
function M.invalidate(host)
    local s=host._personal_marks;if not s then return end
    s.overlay:invalidate();s.indicator:invalidate();M.update(host)
end
function M.available(host)
    local s=host._personal_marks;if not s or not current(host,s) then return false end
    if #s.records>0 or #s.bookmarks>0 then return true end
    if s.complete then return false end
    local m=metadata(host,s);if not m or not m.record or m.record.format~='web_xhtml' then return false end
    for _i,row in ipairs(s.snapshot and s.snapshot.updated or {}) do
        if tostring(row.chapterUid)==m.chapter_uid and (require('weread.lib.my_mark_target').can_locate(row)
            or require('weread.lib.bookmark_point').can_locate(row)) then return true end
    end
    return false
end
function M.tap(host,ges,bookmarks_only)
    local s=host._personal_marks;if not s or not enabled(host,s) or not ges or not ges.pos then return false end
    local bookmark=s.indicator:hitTest(ges.pos)
    local record=bookmark or not bookmarks_only and s.overlay:hitTest(ges.pos);if not record then return false end
    if bookmark then
        if not host:showMyCloudBookmarks(s.book) then return false end
    elseif not host:showMyCloudMarks(s.book) then return false end
    local owner=host._my_marks_owner
    for _i,item in ipairs(owner and owner.menu.item_table or {}) do
        if item.my_note_id==record.bookmarkId then item.callback();return true end
    end
    if owner and owner.value then M.changed(host,owner.value) end
    return true
end
return M
