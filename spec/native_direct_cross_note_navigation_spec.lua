package.path='./?.lua;'..package.path
local tasks,jobs,state
package.preload['ui/uimanager']=function() return {scheduleIn=function(_,_,fn) tasks[#tasks+1]=fn end,
    unschedule=function(_,fn) for i=#tasks,1,-1 do if tasks[i]==fn then table.remove(tasks,i) end end end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(s) return s end} end
local scope={vid='7',epoch=1}
local source={book_id='41',chapter_uid='2',book_version=3,file_id=string.rep('a',64),key='s',copy=0,
    source_sha256='source',catalog_sha256='catalog',catalog_order=1,catalog_count=2}
local target={book_id='41',chapter_uid='3',book_version=3,file_id=string.rep('b',64),key='t',copy=0,
    source_sha256='target',catalog_sha256='catalog',catalog_order=2,catalog_count=2}
package.loaded['weread.lib.native_direct_cache']={valid_entry=function(entry,book,vid)
    return type(entry)=='table' and entry.book_id==book and vid=='7' end,
    identify=function(_,_,file,current)
        if not current() then return nil end
        return file==state.source_file and source or file==state.target_file and target or nil
    end}
package.loaded['weread.lib.native_direct_path']={contains=function(_,file) return file==state.source_file or file==state.target_file end}
package.loaded['weread.lib.book_file_identity']={read_document=function(doc)
    local entry=doc.file==state.source_file and source or target
    return {book_id=entry.book_id,book_version=entry.book_version,file_id=entry.file_id}
end}
package.loaded['weread.lib.source_context']={location=function(doc) return {page=doc.page} end,
    same_location=function(a,b) return a and b and a.page==b.page end}
local Contract=require('weread.lib.mark_edit_contract')
package.loaded['weread.lib.native_direct_note_target']={resolve=function(_,_,_,entry,file,book,row,online,current)
    assert(entry==source and file==state.source_file and book.book_id=='41' and row.chapterUid==3 and online and current())
    return state.bad_target and {path=state.target_file,entry=source} or {path=state.target_file,entry=target}
end}
package.loaded['weread.lib.personal_mark_task']={MAX_NATIVE_BYTES=4096,prepare_direct=function(_,_,_,file,entry,metadata,rows)
    assert(file==state.target_file and entry==target)
    local row=rows[1]
    return {metadata=metadata,rows={{bookmarkId=row.bookmarkId,reference_hash=Contract.row_hash(row),
        bookmark=row.type==0 or nil,anchor={co=1},first_anchor={},last_anchor={},normalized_sha256=string.rep('d',64)}}}
end,verify=function(rows) return {rows[1].bookmarkId} end}
package.loaded['weread.lib.source_dom']={open_direct_prepared=function(_,book,chapter,_,options)
    assert(book=='41' and chapter=='3' and options.is_current())
    return {locate_span=function() return {pos0='target',text='quote'} end,
        locate_anchor=function() return {co=1,xpointer='target'} end}
end}
package.loaded['weread.lib.memory_worker']={new=function() return {start=function(_,fn,callback)
    jobs[#jobs+1]={fn=fn,callback=callback};return true end,cancel=function() end} end}
local Mark=require('weread.lib.my_mark_target');local Thought=require('weread.lib.my_thought_target')
local Bookmark=require('weread.lib.my_bookmark_target')
Mark.can_locate=function() return true end;Thought.can_locate=function() return true end;Bookmark.can_locate=function() return true end
local Navigation=require('weread.ui.my_mark_navigation')
local checks=0
local function expect(value) checks=checks+1;assert(value,'check '..checks) end
local function fixture(kind)
    tasks,jobs={},{};state={source_file='/direct/a.epub',target_file='/direct/b.epub',account='a',valid=true}
    local settings={get_book=function() return nil end,auth_scope_matches=function(_,v) return state.valid and v==scope end}
    local function new_host(file)
        local doc={file=file,page=1,isXPointerInDocument=function(_,xp) return xp=='target' end}
        local host={settings=settings,client={},library_db={accountKey=function() return state.account end},_reader_session_gen=0,
            isNetworkOnline=function() return true end,showInfo=function(_,value) state.message=value end,
            showBusy=function(self) self.busy_message={} end,closeBusy=function(self) self.busy_message=nil end,
            closeWeReadUI=function() end,ui={document=doc,view={view_mode='page'},
                rolling={onGotoXPointer=function(_,xp) state.moved=xp end}}}
        return host
    end
    local host=new_host(state.source_file);host._reader_session_gen=4
    local next_host=new_host(state.target_file)
    host.openFile=function(_,path,callback) state.opened=path;state.callback=callback end
    local owner={id='41',account='a',scope=scope,value={},thoughts=kind=='thought'}
    local row=kind=='thought' and {type=1,chapterUid=3,reviewId='thought',abstract='text',range='1-5'}
        or {type=kind=='bookmark' and 0 or 1,chapterUid=3,bookmarkId='bookmark',markText='text',range='1-5'}
    local function finish() local work=table.remove(jobs,1);assert(work);work.callback(work.fn()) end
    local function tick() local task=table.remove(tasks,1);assert(task);task() end
    local function start() return Navigation.start(host,owner,row,function() return state.valid end) end
    local function receive()
        host._reader_session_gen=5
        local reader=next_host.ui;reader.weread=next_host
        return state.callback(reader)
    end
    return host,next_host,start,finish,tick,receive
end
for _,kind in ipairs({'mark','thought','bookmark'}) do
    local _,_,start,finish,tick,receive=fixture(kind)
    expect(start());finish();finish();expect(state.opened==state.target_file and receive());tick();finish();finish();tick()
    if kind~='bookmark' then finish() end
    expect(state.moved=='target' and not receive())
end
do local _,_,start,finish=fixture('mark');state.bad_target=true;expect(start());finish();finish();expect(not state.opened and state.message) end
do local _,next_host,start,finish,tick,receive=fixture('mark');expect(start());finish();finish();expect(receive());next_host.ui.document.page=2;tick();expect(not state.moved and #jobs==0) end
do local _,_,start,finish,_,receive=fixture('mark');expect(start());finish();finish();state.account='b';expect(not receive() and not state.moved) end
do local _,_,start,finish,_,receive=fixture('mark');expect(start());finish();finish();state.valid=false;expect(not receive() and not state.moved) end
print('native_direct_cross_note_navigation_spec: '..checks..' checks passed')
