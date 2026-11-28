package.path='./?.lua;'..package.path
local timers={}
package.preload['ui/uimanager']=function() return {scheduleIn=function(_,_,task) timers[#timers+1]=task end,
    unschedule=function(_,task) for i=#timers,1,-1 do if timers[i]==task then table.remove(timers,i) end end end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(s) return s end} end
local scope={vid='123',epoch=1};local entry={book_id='41',chapter_uid='2',file_id=string.rep('a',64),book_version=7,
    source_sha256=string.rep('b',64),key=string.rep('c',64)}
local state
package.preload['weread.lib.native_direct_cache']=function() return {
    identify=function(_,vid,file,current) assert(vid=='123' and file==state.file and current());return state.entry and entry or nil end,
    valid_entry=function(value,book,vid) return value==entry and book=='41' and vid=='123' end} end
package.preload['weread.lib.book_file_identity']=function() return {read_document=function()
    return {book_id='41',file_id=state.identity and entry.file_id or string.rep('d',64),book_version=7} end} end
package.preload['weread.lib.source_context']=function() return {
    location=function() return {xpointer='view',page=state.page,pos=0,view_mode='page'} end,
    same_location=function(a,b) return a and b and a.page==b.page and a.xpointer==b.xpointer end} end
local Contract=require('weread.lib.mark_edit_contract')
package.preload['weread.lib.personal_mark_task']=function() return {MAX_NATIVE_BYTES=4096,
    prepare_direct=function(_,_,_,file,value,metadata,rows,online)
        assert(file==state.file and value==entry and online==state.online and #rows==1)
        state.prepares=state.prepares+1;local row=rows[1]
        if state.missing then return {metadata=metadata,format='web_xhtml',rows={}} end
        return {metadata=metadata,format='web_xhtml',rows={{bookmarkId=row.bookmarkId,reference_hash=state.bad_hash and 'wrong' or Contract.row_hash(row),
            bookmark=row.type==0 or nil,anchor={co=15},first_anchor={},last_anchor={},normalized_sha256=string.rep('e',64)}}}
    end,
    verify=function(rows) return state.bad_quote and {} or {rows[1].bookmarkId} end} end
package.preload['weread.lib.source_dom']=function() return {open_direct_prepared=function(_,book,uid,id,options)
    assert(book=='41' and uid=='2' and id.file_id==entry.file_id and options.is_current())
    return {locate_span=function() if state.diverge then return nil,'source_dom/walk_diverged' end
            return {pos0='target',text='Verified quote'} end,
        locate_span_search=function(_,_,_,quote) state.fallback=state.fallback+1;assert(quote=='Unique quotation')
            return {pos0='target',text='Verified quote'} end,
        locate_anchor=function() if state.diverge then return nil,'source_dom/walk_diverged' end return {co=15,xpointer='target'} end,
        locate_point_search=function(_,_,quote) state.fallback=state.fallback+1;assert(quote=='Unique quotation')
            return {co=15,xpointer='target'} end}
end} end
package.loaded['weread.lib.source_dom']=nil
local Mark=require('weread.lib.my_mark_target');local Thought=require('weread.lib.my_thought_target')
local Bookmark=require('weread.lib.my_bookmark_target')
Mark.can_locate=function() return true end;Thought.can_locate=function() return true end;Bookmark.can_locate=function() return true end
local Navigation=require('weread.ui.my_mark_navigation')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message or ('check '..checks)) end
local function fixture(kind)
    timers={};state={file='/direct/native-reader-v1/book.epub',account='a',valid=true,identity=true,entry=true,
        online=false,page=1,prepares=0,fallback=0,jobs={}}
    local row=kind=='thought' and {type=1,chapterUid=2,reviewId='thought',abstract='Unique quotation',range='15-31'}
        or {type=kind=='bookmark' and 0 or 1,chapterUid=2,bookmarkId='mark',markText='Unique quotation',range=kind=='bookmark' and '15' or '15-31'}
    local owner={id='41',account='a',scope=scope,value={},thoughts=kind=='thought'}
    local doc={file=state.file,isXPointerInDocument=function(_,xp) return xp=='target' end}
    local host={ui={document=doc,view={view_mode='page'},rolling={onGotoXPointer=function(_,xp) state.moved=xp end}},
        client={},_reader_session_gen=1,settings={data_dir='/direct',get_book=function() return nil end,
            auth_scope_matches=function(_,v) return state.valid and v==scope end},
        library_db={accountKey=function() return state.account end},isNetworkOnline=function() return state.online end,
        detectWeReadBook=function() return nil end,
        showBusy=function(self,_,cancel) self.busy_message={cancel=cancel} end,closeBusy=function(self) self.busy_message=nil end,
        showInfo=function(_,message) state.message=message end}
    host.closeWeReadUI=function() state.closed=true;Navigation.cancel(host,owner) end
    package.loaded['weread.lib.memory_worker']={new=function() return {start=function(_,task,callback)
        state.jobs[#state.jobs+1]={task=task,callback=callback};return true end,cancel=function() end} end}
    local function current() return state.valid and state.account==owner.account end
    local function finish() local job=table.remove(state.jobs,1);assert(job);local value=job.task();job.callback(value) end
    local function tick() local task=table.remove(timers,1);assert(task);task() end
    local function start() return Navigation.start(host,owner,row,current) end
    return host,owner,start,finish,tick
end
for _,kind in ipairs({'mark','thought','bookmark'}) do
    local _,owner,start,finish,tick=fixture(kind);expect(start());finish();finish();tick()
    if kind~='bookmark' then finish() end
    expect(state.moved=='target' and state.closed and not owner.navigation and state.prepares==1,'direct '..kind..' did not navigate offline')
end
for _,kind in ipairs({'mark','bookmark'}) do
    local _,_,start,finish,tick=fixture(kind);state.diverge=true;expect(start());finish();finish();tick()
    if kind=='mark' then finish() end
    expect(state.moved=='target' and state.fallback==1,'strict '..kind..' fallback was not used')
end
for _,failure in ipairs({'missing','bad_hash','bad_quote','identity','account','page'}) do
    local _,owner,start,finish,tick=fixture('mark');expect(start());finish()
    if failure=='identity' then state.identity=false elseif failure=='account' then state.account='b'
    elseif failure=='page' then state.page=2 else state[failure]=true end
    finish()
    if failure=='bad_quote' then tick();finish() end
    expect(not state.moved and not state.closed and not owner.navigation,'stale or invalid '..failure..' navigated')
end
local _,other,start,finish=fixture('mark');other.id='42'
Mark.resolve=function(book) state.generic=true;assert(book.book_id=='42');return {request_id=1} end
expect(start());finish();finish()
expect(state.generic and state.prepares==0 and not state.moved,'another book was treated as the current native chapter')
print('native_direct_note_navigation_spec: '..checks..' checks passed')
