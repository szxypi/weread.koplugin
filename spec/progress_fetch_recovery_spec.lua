package.path='./?.lua;'..package.path
local Sync=require('weread.lib.progress_sync')
local Access=require('weread.lib.read_access')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message or ('check '..checks)) end
local function copy(value)
    if type(value)~='table' then return value end
    local out={};for key,item in pairs(value) do out[key]=copy(item) end;return out
end
local function fixture(outcomes)
    local f={clock=100,marker='/synthetic/1',online=true,gateway=true,web=true,reads={},renewals=0,cancelled=0,
        pending=false,notifications={},tasks={},queue={},outcomes=outcomes or {401,200},web_reads=0}
    f.values={account={user_vid='900000'},api_key='synthetic-gateway',cookies={wr_vid='900000',wr_skey='synthetic-before'},
        sync={pull_on_open=false,upload_on_close=false,ask_on_conflict=true,upload_interval_minutes=0},books={['900001']={book_id='900001'}}}
    local settings={get=function(_self,key,default) return f.values[key] or default end,
        set=function(_self,key,value) f.values[key]=value end,flush=function() end,
        get_auth_scope=function() return {vid='900000',epoch=1} end,
        auth_scope_matches=function() return true end,
        is_api_configured=function() return f.gateway end,is_cookie_configured=function() return f.web end}
    f.remote={book={bookId='900001',chapterUid=11,chapterIdx=0,chapterOffset=1000,progress=37}}
    f.point={book_id='900001',chapter_uid='11',chapter_offset=1000,basis='filtered_xhtml_utf16',upload_verified=false,
        file_id=string.rep('a',64),raw_sha256=string.rep('b',64),book_version=1,render_path='chapter.xhtml'}
    f.position={book_id='900001',chapter_uid=11,chapter_idx=0,chapter_offset=7,percent=37,source_position=copy(f.point)}
    local chapters={{chapterUid=11,chapterIdx=0,wordCount=100}}
    local document={file='synthetic.epub'}
    f.document=document
    local client={get_progress_snapshot=function(_self,id,access,flags)
        expect(id=='900001' and flags.classify_auth and flags.fresh,'preflight lost bounded captured access')
        f.reads[#f.reads+1]={kind=access.kind,cookie=access.cookies and access.cookies.wr_skey}
        if access.kind=='web' then
            f.web_reads=f.web_reads+1
            local status=f.outcomes[f.web_reads] or 200
            if status==401 then return nil,'web_expired' end
            if status=='transport' then error('web_expired',0) end
            if status~=200 then error('display_progress/unavailable',0) end
        end
        return copy(f.remote)
    end}
    f.recovery={start=function(_self,_id,access,current,callback)
        expect(Access.matches(settings,access) and current(),'stale preflight started renewal')
        if f.pending then return false end
        f.renewals=f.renewals+1;f.guard,f.ready=current,callback;return true,{}
    end,cancel=function() f.cancelled=f.cancelled+1 end}
    local sync=Sync:new{settings=settings,client=client,scheduler={
        scheduleIn=function(_self,delay,fn) f.tasks[fn]=f.clock+delay end,unschedule=function(_self,fn) f.tasks[fn]=nil end},
        get_document=function() return document end,detect_book=function() return '900001' end,
        get_navigation_xpointer=function() return f.marker end,get_source_position=function() return copy(f.point) end,
        get_book=function(id) return f.values.books[id] end,get_chapters=function() return chapters end,
        get_file_context=function() return nil,nil,true end,
        run_online=function(kind,callback)
            if f.defer_resumed and kind=='progress_pull_recovered' then f.queue[#f.queue+1]=callback else callback() end
            return true
        end,recovery=f.recovery,now=function() return f.clock end,is_online=function() return f.online end,
        prepare_upload=function() error('read-only recovery uploaded a position') end,
        upload_position=function() error('preflight sent account data') end,
        goto_fraction=function() error('recovery navigated without a choice') end,open_chapter=function() return true end,
        on_choice=function(value) f.choice=value end,notify=function(code,data) f.notifications[#f.notifications+1]={code=code,data=data} end}
    sync.capture_local=function() return copy(f.position),nil,{book_id='900001',book=f.values.books['900001'],chapters=chapters} end
    sync.current_book_id='900001';sync.checkpoint_account=sync:_account_key();sync.local_position=copy(f.position);sync.dirty=true
    f.sync=sync
    function f.complete()
        f.values.cookies.wr_skey='synthetic-after'
        f.ready(Access.capture(settings))
    end
    return f
end
local f=fixture();expect(f.sync:sync_now())
expect(f.sync.pulling and not f.sync.verified and f.renewals==1 and #f.reads==2,'Web 401 silently used stale gateway position')
expect(f.values.books['900001'].pending_upload_position,'recovery did not park local movement')
f.complete()
expect(f.sync.verified and not f.sync.pulling and #f.reads==4,'recovery did not reread both sources')
expect(f.reads[2].cookie=='synthetic-before' and f.reads[4].cookie=='synthetic-after','fresh read reused old credentials')
expect(not f.values.books['900001'].pending_upload_position and not next(f.tasks),'confirmed read retained intent or timeout')
f=fixture();f.gateway=false;f.values.api_key='';f.sync:sync_now();f.complete()
expect(f.sync.verified and #f.reads==2 and f.reads[1].kind=='web','Web-only progress could not recover')
f=fixture();f.web=false;f.values.cookies={}
f.sync.client.get_progress=function() f.reads[#f.reads+1]={kind='gateway'};return copy(f.remote) end
f.sync:sync_now()
expect(f.sync.verified and #f.reads==1 and f.renewals==0,'gateway-only legacy access required Web credentials')
f=fixture({401,401});f.sync:sync_now();f.complete()
expect(f.renewals==1 and not f.sync.verified and not f.sync.pulling and f.sync.state=='error','second 401 repeated recovery')
expect(f.notifications[#f.notifications].data.error=='progress_authentication_unavailable','auth failure was not explained')
for _i,status in ipairs({403,429,'transport'}) do
    f=fixture({status});f.gateway=false;f.values.api_key='';f.sync:sync_now()
    expect(f.renewals==0 and not f.sync.verified and not f.sync.pulling,'non-401 or text triggered renewal')
end
f=fixture();f.pending=true;f.sync:sync_now()
expect(f.renewals==0 and not f.sync.verified and not f.sync.pulling,'pending reading dispatch renewed or retained a busy slot')
for _i,event in ipairs({'on_suspend','on_close_document','on_reader_ready','on_account_changed','begin_local_navigation'}) do
    f=fixture();f.sync:sync_now();f.sync[event](f.sync);f.complete()
    expect(f.cancelled==1 and not f.sync.pulling and #f.reads==2,'old recovery survived '..event)
end
f=fixture();f.sync:sync_now();f.marker='/synthetic/2';f.sync:on_page_update();f.complete()
expect(f.cancelled==1 and not f.sync.pulling and #f.reads==2,'page turn did not cancel recovery immediately')
f=fixture();f.live_marker='/synthetic/1';f.document.getXPointer=function() return f.live_marker end
f.sync:sync_now();f.live_marker='/synthetic/2';f.sync:on_page_update();f.complete()
expect(f.marker=='/synthetic/1' and f.cancelled==1 and not f.sync.pulling and #f.reads==2,
    'PageUpdate trusted the stale ReaderRolling cache rather than the live engine')
f=fixture();f.sync:sync_now();f.marker='/synthetic/silent';f.complete()
expect(not f.sync.pulling and not f.sync.pull_job and #f.reads==2,'silent marker change stranded a pull')
f=fixture();f.sync:sync_now();f.clock=136
for task in pairs(f.tasks) do task() end
expect(not f.sync.pulling and f.cancelled==1 and #f.reads==2,'expired recovery retained a pull')
f=fixture();f.defer_resumed=true;f.sync:sync_now();f.complete()
expect(#f.queue==1 and f.sync.pulling,'recovered reads did not re-enter the guarded online task')
f.values.api_key='changed-gateway';f.queue[1]()
expect(not f.sync.pulling and #f.reads==2,'changed credentials entered recovered reads')
f=fixture();f.values.sync.upload_interval_minutes=1
f.sync:_mark_verified('900001','synthetic',f.position,{book_id='900001',chapter_uid=11,chapter_idx=0,chapter_offset=1000,percent=37})
f.clock=160;local tick=assert(f.sync.interval.task);f.tasks[tick]=nil;tick()
expect(f.sync.interval.cycle and f.renewals==1,'timed preflight skipped recovery')
f.complete();expect(f.sync.verified and not f.sync.dirty and not f.sync.interval.cycle,'timed recovery did not finish read-only equality')
f=fixture();f.values.sync.upload_interval_minutes=1;f.sync:_mark_verified('900001','synthetic',f.position,{})
f.clock=160;tick=assert(f.sync.interval.task);f.tasks[tick]=nil;tick()
f.values.sync.upload_interval_minutes=0;f.sync.interval:reschedule();f.complete()
expect(f.cancelled==1 and not f.sync.interval.cycle and #f.reads==2,'disabled timer resumed a recovered request')
print(('progress_fetch_recovery_spec: %d checks'):format(checks))
