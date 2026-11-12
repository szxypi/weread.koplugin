package.path='./?.lua;./?/init.lua;'..package.path
local Sync=require('weread.lib.progress_sync')
local Wait=require('weread.lib.progress_source_wait')
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local function fixture()
    local f={clock=100,queue={},gets=0,posts=0,choices=0,notices={},account='one',doc={file='/synthetic/book.epub'}}
    local book={book_id='900001',title='Synthetic',pending_upload_position={chapter_offset=999},pending_upload_reason='kept'}
    local chapters={{chapterUid=11,chapterIdx=1,wordCount=1000}}
    local values={account={user_vid='one'},books={['900001']=book},sync={pull_on_open=true,ask_on_conflict=true}}
    local settings={get=function(_self,key,default) return key=='account' and {user_vid=f.account} or values[key] or default end,
        set=function(_self,key,value) values[key]=value end,flush=function() end,
        is_api_configured=function() return true end,is_cookie_configured=function() return true end}
    local scheduler={scheduleIn=function(_self,delay,callback) f.queue[#f.queue+1]={delay=delay,callback=callback} end,
        unschedule=function(_self,callback) for i=#f.queue,1,-1 do if f.queue[i].callback==callback then table.remove(f.queue,i) end end end}
    local sync=Sync:new{settings=settings,client={},scheduler=scheduler,now=function() return f.clock end,
        get_document=function() return f.doc end,detect_book=function() return '900001' end,
        get_book=function() return book end,get_chapters=function() return chapters end,get_file_context=function() return nil,nil,true end,
        get_source_position=function() return f.point end,run_online=function(_kind,callback) callback();return true end,
        prepare_upload=function() error('read comparison prepared a write') end,
        upload_position=function() f.posts=f.posts+1;error('unexpected write') end,
        goto_fraction=function() error('unexpected navigation') end,open_chapter=function() error('unexpected chapter download') end,
        on_choice=function() f.choices=f.choices+1 end,notify=function(code) f.notices[#f.notices+1]=code end}
    sync.source_state='waiting'
    function sync:capture_local()
        return {book_id='900001',chapter_uid=11,chapter_idx=1,chapter_offset=999,percent=25,source_position=f.point},nil,
            {book_id='900001',book=book,chapters=chapters}
    end
    function sync:fetch_remote_checked(_id,_chapters,_job,current,callback)
        expect(current(),'remote read received stale scope');f.gets=f.gets+1
        callback({book_id='900001',chapter_uid='11',chapter_idx=1,chapter_offset=50,has_chapter_offset=true,has_chapter_index=true,percent=25})
    end
    function f:ready(offset,owner)
        self.point={book_id=owner or '900001',chapter_uid='11',chapter_offset=offset or 50,
            basis='filtered_xhtml_utf16',upload_verified=false,raw_sha256=string.rep('a',64),file_id=string.rep('b',64)}
        sync:on_source_position_changed('ready',self.point)
    end
    f.sync,f.book=sync,book
    return f
end
local control=fixture();local original=Wait.start
Wait.start=function() return false end
control.sync:sync_now();Wait.start=original
expect(control.gets==1 and control.choices==1 and not control.sync.verified,'negative control did not reproduce an early false conflict')
control:ready();expect(control.sync.state=='awaiting_choice','old comparison unexpectedly repeated itself after local readiness')
local f=fixture();expect(f.sync:sync_now() and f.sync.pulling and f.gets==0 and f.choices==0,'comparison did not wait for local source')
expect(#f.queue==1 and f.queue[1].delay==Wait.TIMEOUT,'source wait is not bounded')
f:ready();expect(f.gets==1 and f.sync.verified and not f.sync.pulling and f.choices==0 and f.posts==0,'matching source point raised a false conflict')
expect(#f.queue==0 and not f.sync.pull_job,'completed wait retained its timer/job')
f=fixture();f:ready();expect(f.sync:sync_now() and f.gets==1 and f.sync.verified and #f.queue==0,'ready position was delayed')
f=fixture();f.sync.prepare_upload=nil;expect(f.sync:sync_now() and f.gets==1 and #f.queue==0,'legacy comparison gained source requirement')
f=fixture();f.sync.source_state='unsupported';f.sync:sync_now()
expect(f.gets==1 and f.choices==1 and not f.sync.verified,'unsupported source bypassed explicit choice')
for _,event in ipairs({'cancel','account','document','navigate'}) do
    f=fixture();f.sync:sync_now();local wake=f.sync.pull_job.source_wait.wake
    if event=='cancel' then f.sync:_invalidate_pull()
    elseif event=='account' then f.account='two';f.sync:on_account_changed()
    elseif event=='document' then f.doc={file='/synthetic/other.epub'}
    else f.sync:begin_local_navigation() end
    f:ready();wake()
    expect(f.gets==0 and f.posts==0 and #f.queue==0 and not f.sync.pulling,event..' revived waiting comparison')
    expect(f.book.pending_upload_position.chapter_offset==999,event..' discarded local intent')
end
f=fixture();f.sync:sync_now();local old_wait=f.sync.pull_job.source_wait
f.sync:_invalidate_pull();f.sync:sync_now();local replacement=f.sync.pull_job
old_wait.wake();old_wait.expire()
expect(f.sync.pull_job==replacement and f.sync.pulling and #f.queue==1 and f.gets==0,'stale callbacks cancelled a replacement wait')
f:ready();expect(f.sync.verified and f.gets==1 and #f.queue==0,'replacement wait did not finish independently')
f=fixture();f.sync.source_state='deferred';f.sync:sync_now();f.sync:on_source_position_changed('preparing',nil)
expect(f.sync.pulling and f.gets==0 and #f.queue==1,'ongoing local preparation scheduled another read/timer')
f:ready();expect(f.sync.verified and f.gets==1,'deferred local source did not wake read')
f=fixture();f.sync:sync_now();f:ready(70)
expect(f.gets==1 and f.choices==1 and not f.sync.verified and f.posts==0,'actual moved source position was treated as equal')
for _,event in ipairs({'paused','idle','unavailable'}) do
    f=fixture();f.sync:sync_now();f.sync:on_source_position_changed(event,nil)
    expect(f.gets==0 and f.posts==0 and not f.sync.pulling and #f.queue==0,event..' did not stop before HTTP')
    expect(#f.notices==(event=='unavailable' and 1 or 0),event..' showed stale/cancellation UI')
end
f=fixture();f.sync:sync_now();local expire=table.remove(f.queue,1).callback;expire()
expect(f.gets==0 and f.sync.pulling and #f.queue==1,'early timer incorrectly ended wait')
f.clock=f.clock+Wait.TIMEOUT;table.remove(f.queue,1).callback()
expect(not f.sync.pulling and f.sync.state=='error' and #f.notices==1 and f.gets==0,'source wait timeout was not final')
expect(f.book.pending_upload_position.chapter_offset==999 and f.book.last_pull_at==nil,'timeout changed saved intent or invented a cloud read')
f:ready();expire();expect(f.gets==0 and #f.queue==0,'late readiness/timeout replayed read')
f=fixture();f.sync:sync_now();f.clock=99;table.remove(f.queue,1).callback()
expect(not f.sync.pulling and f.gets==0,'clock rollback extended waiting indefinitely')
f=fixture();f.sync:sync_now();f:ready(50,'other')
expect(f.gets==0 and not f.sync.pulling and not f.sync.verified,'foreign source point was used for cloud comparison')
print('progress_source_wait_spec: '..checks..' checks')
