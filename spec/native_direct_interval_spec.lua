package.path='./?.lua;'..package.path
local n=0;local function expect(value,message) n=n+1;assert(value,message) end
local live,access,page=true,true,1
local scope={vid='123',epoch=1};local native={scope=scope};local web={}
local entry={book_id='42',chapter_uid='37',chapter_idx=2,book_version=7,source_sha256=string.rep('c',64),file_id=string.rep('a',64)}
package.preload['ui/uimanager']=function() return {} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(text) return text end} end
package.preload['weread.lib.source_context']=function() return {
    location=function() return {page=page} end,same_location=function(a,b) return a and b and a.page==b.page end} end
package.preload['weread.lib.book_file_identity']=function() return {read_document=function()
    return {book_id=entry.book_id,file_id=entry.file_id,book_version=entry.book_version} end} end
package.preload['weread.lib.native_read_access']=function() return {matches=function() return access end} end
package.preload['weread.lib.source_currentness']=function() return {matches=function() return access end} end
package.preload['weread.lib.progress_interval']=function() return {minutes=function(v)
    return type(v)=='number' and v%1==0 and v>=1 and v<=60 and v or 0 end} end
package.preload['weread.ui.native_direct_position']=function() return {cancel=function(host)
    host.auto_cancelled=true;host._native_direct_position=nil
end} end
local Interval=require('weread.lib.native_direct_interval')
local function fixture()
    live,access,page=true,true,1
    local f={time=100,minutes=1,online=true,jobs={},messages={}}
    local doc={file='/native'};local reader={document=doc,view={view_mode='page'}}
    f.host={ui=reader,_reader_session_gen=1,settings={get=function(_,key) if key=='sync' then return {upload_interval_minutes=f.minutes} end end,
        auth_scope_matches=function(_,s) return live and s==scope end},library_db={accountKey=function() return 'owner' end},
        isNetworkConnected=function() return f.online end,showTransientInfo=function(_,msg) f.messages[#f.messages+1]=msg end}
    f.context={reader=reader,document=doc,file=doc.file,scope=scope,session=1,account='owner',native=native,web=web,location={page=1}}
    f.before={book_id='42',chapter_uid='37',chapter_idx=2,chapter_offset=10,raw_percent=20,summary='cloud baseline'}
    f.desired={book_id='42',chapter_uid='37',chapter_idx=2,chapter_offset=11,raw_percent=20,summary='local position'}
    f.metadata={book_id='42',before=f.before,desired=f.desired,counts={readingTime=10,recordReadingTime=0,ttsTime=0},
        version=7,shelf_sha256=string.rep('b',64),source_sha256=entry.source_sha256,file_id=entry.file_id,basis='filtered_xhtml_utf16'}
    f.scheduler={scheduleIn=function(_,seconds,task) f.jobs[task]=f.time+seconds end,
        unschedule=function(_,task) f.jobs[task]=nil end}
    f.interval=Interval:new(f.host,{scheduler=f.scheduler,now=function() return f.time end,start=function(_,e,opts)
        expect(e.book_id=='42' and opts.upload and opts.automatic.current(),'timer lost its session')
        f.starts=(f.starts or 0)+1;f.options=opts;return true
    end})
    function f.arm() return f.interval:arm(entry,f.context,f.metadata,'before') end
    function f.advance(seconds)
        f.time=f.time+seconds
        local due={};for task,when in pairs(f.jobs) do if when<=f.time then due[#due+1]=task end end
        for _,task in ipairs(due) do f.jobs[task]=nil;task() end
    end
    return f
end
local f=fixture();expect(f.arm() and not next(f.jobs),'verified session should start idle')
page=2;f.interval:changed();expect(next(f.jobs)~=nil,'changed page did not schedule a timer')
f.advance(30);page=3;f.interval:changed();f.advance(30)
expect(f.starts==1 and f.options.automatic.current(),'page changes postponed the deadline')
local frozen=f.options.automatic.baseline;expect(frozen.position.chapter_offset==10,'cloud baseline changed')
f.options.automatic.done('confirmed',f.metadata,{page=3})
expect(f.interval.context.baseline.position.chapter_offset==11 and not f.interval.dirty and not next(f.jobs),'confirmed sync did not advance baseline')
page=4;f.interval:changed();f.advance(60);expect(f.starts==2,'subsequent page did not schedule')
f.options.automatic.done('unconfirmed');expect(not f.host._native_direct_interval and #f.messages==1,'unknown result was retried')
f=fixture();f.arm();page=2;f.interval:changed();page=1;f.interval:changed();expect(not next(f.jobs),'return to verified page kept a timer')
f=fixture();f.arm();page=2;f.interval:changed();f.online=false;f.advance(60)
expect(not f.starts and not f.host._native_direct_interval,'offline timer attempted a network action')
f=fixture();f.arm();page=2;f.interval:changed();access=false;f.advance(60)
expect(not f.starts and not f.host._native_direct_interval,'changed authorization started a timer upload')
f=fixture();f.arm();page=2;f.interval:changed();live=false;f.advance(60)
expect(not f.starts and not f.host._native_direct_interval,'changed account started a timer upload')
f=fixture();f.arm();page=2;f.interval:changed();f.host.busy_message={};f.advance(60)
expect(not f.starts and next(f.jobs),'busy reader was interrupted')
f.host.busy_message=nil;f.advance(60);expect(f.starts==1,'busy reader did not reschedule')
f.options.automatic.done('conflict');expect(not f.host._native_direct_interval and #f.messages==1,'cloud conflict did not pause')
f=fixture();f.arm();page=2;f.interval:changed();f.advance(60);page=3;f.options.automatic.done('cancelled')
expect(f.host._native_direct_interval and next(f.jobs),'cancelled source check lost the next timer')
f=fixture();f.arm();page=2;f.interval:changed();f.advance(60)
f.host._native_direct_position={automatic=f.options.automatic};f.interval:stop()
expect(f.host.auto_cancelled and not f.options.automatic.current() and not f.host._native_direct_interval,
    'stopping the interval left a running upload active')
f=fixture();f.arm();page=2;f.interval:changed();f.minutes=0;f.interval:settings_changed()
expect(not next(f.jobs) and not f.starts,'disabled interval kept a timer')
f=fixture();f.arm();page=2;f.interval:changed();f.time=50;f.advance(110)
expect(f.starts==1,'valid deadline should still fire after clock catches up')
f=fixture();f.arm();page=2;f.interval:changed();f.time=50;local task=next(f.jobs);f.jobs[task]=nil;task()
expect(not f.starts and f.interval.started==50 and f.interval.due==110,'backward clock did not restart the interval')
print('PASS: native interval remains session-bound and conflict-safe ('..n..' checks)')
