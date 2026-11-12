package.path='./?.lua;'..package.path
local Sync=require('weread.lib.progress_sync')
local Dispatch=require('weread.lib.source_dispatch')
local Interval=require('weread.lib.progress_interval')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message or ('check '..checks)) end
local function copy(value)
    if type(value)~='table' then return value end
    local out={};for key,item in pairs(value) do out[key]=copy(item) end;return out
end
local function fixture()
    local f={clock=100,online=true,tasks={},queue={},reads=0,writes=0,report_busy=false,cancelled=0,released=0,notifications={}}
    f.values={account={user_vid='900000'},sync={upload_interval_minutes=1,ask_on_conflict=false},
        books={['900001']={book_id='900001',title='Synthetic book'}}}
    local settings={get=function(_self,key,default) return f.values[key] or default end,
        set=function(_self,key,value) f.values[key]=value end,flush=function() end}
    f.point={book_id='900001',chapter_uid='11',chapter_offset=1000,basis='filtered_xhtml_utf16',upload_verified=false,
        file_id=string.rep('a',64),raw_sha256=string.rep('b',64),book_version=1,render_path='chapter.xhtml'}
    f.position={book_id='900001',chapter_uid=11,chapter_idx=0,chapter_offset=5,percent=10,source_position=copy(f.point)}
    f.remote={book_id='900001',chapter_uid=11,chapter_idx=0,chapter_offset=500,percent=10,
        has_chapter_offset=true,has_chapter_index=true}
    local chapters={{chapterUid=11,chapterIdx=0,wordCount=100}}
    local document={file='synthetic.epub'}
    f.scheduler={scheduleIn=function(_self,delay,fn) f.tasks[fn]=f.clock+delay end,
        unschedule=function(_self,fn) f.tasks[fn]=nil end}
    local sync=Sync:new{settings=settings,client={},scheduler=f.scheduler,
        now=function() return f.clock end,get_document=function() return document end,
        detect_book=function() return '900001' end,get_book=function(id) return f.values.books[id] end,
        get_source_position=function() return copy(f.point) end,get_chapters=function() return chapters end,
        get_file_context=function() return nil,nil,true end,goto_fraction=function() error('timer navigated') end,
        open_chapter=function() error('timer opened a chapter') end,on_choice=function(choice) f.choice=choice end,
        notify=function(code) f.notifications[#f.notifications+1]=code end,
        is_online=function() return f.online end,is_report_busy=function() return f.report_busy end,
        cancel_upload_preparation=function() f.cancelled=f.cancelled+1 end,
        run_online=function(kind,callback,options)
            if kind=='progress_interval' or kind=='progress_upload' then expect(options.silent_offline,'automatic task opened offline UI') end
            if f.queued then f.queue[#f.queue+1]=callback else callback() end
            return true
        end,
        upload_position=function(_id,wire,elapsed,plan)
            expect(elapsed==0 and wire.chapter_offset==1000,'timer used time or estimated coordinates')
            expect(plan.before_send() and f.journal:pending('900001'),'timer sent before journal')
            f.writes=f.writes+1
            if f.unknown then return false,{error_kind='unconfirmed',report_attempted=true,enter_attempted=false} end
            f.remote.chapter_offset=1000
            return true,{acknowledged=true,position_confirmed=true,remote=copy(f.remote)}
        end}
    f.sync=sync
    f.journal=Dispatch:new{settings=settings,now=function() return f.clock end,nonce=function() return string.rep('a',32) end}
    sync.source_dispatch=f.journal
    sync.capture_local=function() return copy(f.position),nil,{book_id='900001',book=f.values.books['900001'],chapters=chapters} end
    sync._fetch_remote=function()
        f.reads=f.reads+1
        if f.read_failure then return nil,'synthetic transport' end
        return copy(f.remote)
    end
    sync.prepare_upload=function(intent,callback)
        local plan={position={book_id='900001',chapter_uid='11',chapter_idx=0,chapter_offset=1000,percent=intent.percent,summary='SYNTHETIC'},
            source_position=copy(f.point),basis='filtered_xhtml_utf16',is_current=function() return true end,
            release=function() f.released=f.released+1 end}
        if f.defer_prepare then f.ready=function() callback(plan) end else callback(plan) end
    end
    function f.verify()
        sync:_mark_verified('900001','synthetic',copy(f.position),copy(f.remote));sync.dirty=true;sync.interval:refresh()
    end
    function f.advance(seconds)
        f.clock=f.clock+seconds
        for _i=1,30 do
            local ready
            for task,due in pairs(f.tasks) do if due<=f.clock then ready=task;break end end
            if not ready then return end
            f.tasks[ready]=nil;ready()
        end
        error('timer failed to quiesce')
    end
    return f
end
for _i,value in ipairs({0,-1,0.5,61,math.huge,'1',false}) do expect(Interval.minutes(value)==0,'invalid interval enabled sync') end
expect(Interval.minutes(1)==1 and Interval.minutes(60)==60)
local f=fixture();f.values.sync.upload_interval_minutes=0;f.verify()
expect(not f.sync.interval.task and not next(f.tasks),'disabled timer scheduled work')
f=fixture();f.verify();local task=f.sync.interval.task
expect(task and f.sync.interval.due==160,'dirty verified session did not arm one deadline')
f.clock=110;f.tasks[task]=nil;task()
expect(f.reads==0 and f.tasks[task]==160,'accelerated UI clock fired a real deadline early')
f.sync:on_page_update();expect(f.sync.interval.task==task and f.sync.interval.due==160,'movement postponed deadline')
local get_source=f.sync.get_source_position
f.sync.source_state='waiting';f.sync.get_source_position=function() return nil end
f.sync.interval:refresh()
expect(f.sync.interval.task==task and f.sync.interval.due==160,'source recapture postponed every page-turn deadline')
f.sync.source_state='ready';f.sync.get_source_position=get_source
f.advance(50)
expect(f.reads==1 and f.writes==1 and not f.sync.dirty,'unchanged cloud did not receive one current position')
expect(not f.journal:pending('900001') and not f.sync.interval.task and not next(f.tasks),'clean confirmed timer retained work')
expect(f.values.books['900001'].last_uploaded_position.chapter_offset==1000
    and f.values.books['900001'].last_local_position.chapter_offset==5,'timer changed persisted local units')
expect(f.sync.remote_position.chapter_offset==1000,'confirmed upload did not advance known cloud baseline')
f.sync.dirty=true;f.position.source_position.chapter_offset=1200;f.point.chapter_offset=1200
local confirmed=copy(f.remote);confirmed.chapter_offset=1100;confirmed.summary='SYNTHETIC_BODY'
expect(f.sync:accept_report_confirmation(confirmed) and f.sync.remote_position.chapter_offset==1100,'periodic confirmation did not advance baseline')
expect(f.sync.dirty and not f.sync.remote_position.summary and not f.values.books['900001'].last_remote_position.summary,
    'periodic confirmation erased newer movement or persisted text')
f.sync.verified=false;confirmed.chapter_offset=1300
expect(not f.sync:accept_report_confirmation(confirmed) and f.sync.remote_position.chapter_offset==1100,'stale report granted a new baseline')

f=fixture();f.remote.chapter_offset=1000;f.verify();f.advance(60)
expect(f.reads==1 and f.writes==0 and not f.sync.dirty and not f.sync.interval.task,'already uploaded source was sent again')
f=fixture();f.verify();f.remote.chapter_offset=750;f.advance(60)
expect(f.choice and f.writes==0 and not f.sync.verified and not f.sync.interval.task,
    'changed cloud silently overwrote or navigated with ask=false')
expect(f.choice.remote_position.chapter_offset==750,'cloud conflict lost actual coordinate')

f=fixture();f.report_busy=true;f.verify();f.advance(60)
expect(f.reads==0 and f.writes==0 and f.sync.interval.due==220,'timer competed with periodic reporter')
f.report_busy=false;f.advance(60);expect(f.writes==1,'timer did not resume after busy reporter')
f=fixture();f.verify();f.online=false;f.advance(60)
expect(f.reads==0 and f.writes==0 and not f.sync.verified and not f.sync.interval.task,'offline timer requested network or retained authority')
expect(f.values.books['900001'].pending_upload_position,'offline timer lost local position')
f=fixture();f.verify();f.read_failure=true;f.advance(60)
expect(f.reads==1 and f.writes==0 and not f.sync.verified and not f.sync.interval.cycle,'failed comparison retained automatic authority')

f=fixture();f.verify();f.unknown=true;f.advance(60)
expect(f.writes==1 and f.journal:pending('900001') and not f.sync.verified,'unknown timed write was cleared')
expect(#f.notifications==1 and f.notifications[1]=='upload_unconfirmed','unknown timed write did not explain recovery once')
f.advance(600);expect(f.writes==1 and not f.sync.interval.task,'unknown timed write was automatically replayed')
f=fixture();f.verify();f.defer_prepare=true;f.advance(60)
expect(f.sync.uploading and f.sync.interval.cycle and f.ready,'timer did not prepare asynchronously')
f.values.sync.upload_interval_minutes=0;f.sync.interval:reschedule();f.ready()
expect(f.cancelled==1 and f.writes==0 and not f.sync.uploading and f.released==1,'disabled preparation sent or leaked a late plan')
expect(f.values.books['900001'].pending_upload_position,'disabled preparation discarded local intent')

for _i,event in ipairs({'on_suspend','on_close_document','on_reader_ready','on_account_changed','begin_local_navigation'}) do
    f=fixture();f.verify();local stale=f.sync.interval.task
    f.sync[event](f.sync)
    stale();expect(f.writes==0 and f.reads==0 and not f.sync.interval.cycle,'old deadline survived '..event)
end
f=fixture();f.verify();f.clock=90;local early=f.sync.interval.task;f.tasks[early]=nil;early()
expect(f.sync.interval.due==150 and f.reads==0,'clock rollback made a catch-up upload')
f=fixture();f.verify();f.values.sync.upload_interval_minutes=5;f.sync.interval:reschedule()
expect(f.sync.interval.due==400,'interval change retained old deadline')
f=fixture();f.verify();f.queued=true;f.advance(60)
expect(f.sync.interval.cycle and #f.queue==1)
f.values.sync.upload_interval_minutes=0;f.sync.interval:reschedule();f.queue[1]()
expect(f.reads==0 and f.writes==0,'disabled queued comparison executed')
f=fixture();f.verify();f.sync.source_state='unavailable';f.sync.get_source_position=function() return nil end;f.sync.interval:refresh()
expect(not f.sync.interval.task and f.reads==0,'unavailable source kept polling cloud')
f=fixture();f.point.basis='raw_txt_utf16';f.position.source_position=copy(f.point);f.remote.source='web'
f.sync.prepare_upload=function(intent,callback)
    expect(intent.native_position_only==true and intent.expected_remote.source=='web','TXT timer lost native route or cloud baseline')
    callback{transport='native_position',basis='raw_txt_utf16',source_position=copy(f.point),
        position={book_id='900001',chapter_uid='11',chapter_idx=0,chapter_offset=1000,percent=10},
        is_current=function() return true end,dispatch=function(done)
            f.writes=f.writes+1;f.deliver=done;return true
        end}
end
f.verify();expect(f.sync.interval.task and f.sync.interval.due==160,'TXT source never armed a position deadline')
f.advance(60);expect(f.reads==1 and f.writes==1 and f.sync.uploading,'TXT timer did not use asynchronous native dispatch')
local remote=copy(f.remote);remote.chapter_offset=1000;remote.source='native'
f.deliver(true,true,{acknowledged=true,position_confirmed=true,report_attempted=true,remote=remote})
expect(not f.sync.uploading and not f.sync.dirty and not f.sync.interval.task and not f.journal:pending('900001'),
    'TXT timer retained work or used Web dispatch state')
f=fixture();f.point.basis='unknown';f.position.source_position=copy(f.point);f.verify()
expect(not f.sync.interval.task,'unknown units enabled the timer')
print(('progress_interval_spec: %d checks'):format(checks))
