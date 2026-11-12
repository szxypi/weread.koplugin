package.path='./?.lua;'..package.path
local Face=require('weread.lib.native_close_source')
local Currentness=require('weread.lib.source_currentness')
local Task=require('weread.lib.source_position_worker')
local Coordinates=require('weread.lib.source_coordinates')
local F=require('spec.helpers.thought_edit_fixture')
local checks=0;local function expect(v,why) checks=checks+1;assert(v,why or ('check '..checks)) end
local active
Currentness.matches=function(_settings,access) return active.auth and access==active.access end
Currentness.run_txt=function(_client,expected)
    active.http=active.http+1
    if active.expired>0 then active.expired=active.expired-1;return {error='source_web_expired'} end
    return {check={expected=F.clone(expected),basis=active.wrong_basis and 'filtered_xhtml_utf16' or 'raw_txt_utf16'}}
end
Currentness.packet_txt=function(check,expected)
    return check and check.basis=='raw_txt_utf16' and check.expected.raw_sha256==expected.raw_sha256
end
Task.prepare_native_excerpt=function(input)
    expect(input.file=='synthetic.epub' and not input.document,'worker inherited native document')
    local position=F.clone(input.target);position.chapter_title='Synthetic title'
    if active.bad_point then position.chapter_offset=999 end
    return {request_id=input.request_id,position=position,excerpt=F.clone(active.excerpt)}
end
local function fixture()
    local f={clock=100,auth=true,owned=true,online=true,http=0,expired=0,callbacks=0,cancelled=0,renewals=0,scope=true}
    active=f;f.access={web={}};f.point={book_id='41',chapter_uid='2',chapter_offset=13,file_id=string.rep('a',64),
        raw_sha256=string.rep('b',64),book_version=7,render_path='OEBPS/text/chapter.xhtml',basis='raw_txt_utf16',upload_verified=false}
    f.excerpt=assert(Coordinates.build('Exact\r\n　literal 😀 source excerpt',{format='web_txt'})):literal_excerpt(0)
    f.excerpt.co=f.point.chapter_offset;f.excerpt.end_co=f.excerpt.end_co+f.point.chapter_offset
    f.chapters={{chapterUid=2,chapterIdx=3}};f.worker={cancel=function() f.cancelled=f.cancelled+1 end,
        start=function(_self,task,cb) f.task,f.ready=task,cb;return not f.worker_failure end}
    local settings={auth_scope_matches=function() return f.scope end}
    local source={client={settings=settings},is_online=function() return f.online end,make_worker=function() return f.worker end,
        get_document=function() error('closed document touched') end}
    source.recovery={start=function(_self,_book,_access,guard,done)
        f.renewals=f.renewals+1;f.guard,f.renewed=guard,done;return true,{}
    end,cancel=function() f.cancelled=f.cancelled+1 end}
    f.face=Face:new{source=source,input={file='synthetic.epub',book_id='41',chapter_uid='2',target=f.point,percent=18},
        expected={book_id='41',chapter_uid='2',chapter_idx=3,raw_sha256=f.point.raw_sha256,raw_bytes=500},access=f.access,
        account_scope={vid='900000',epoch=1},is_current=function() return f.owned end,get_catalog=function() return f.chapters end,
        now=function() return f.clock end,deadline=135}
    function f:start()
        return self.face:prepare_current_native_preview(function(candidate,reason,receipt)
            self.candidate,self.reason,self.receipt=candidate,reason,receipt;self.callbacks=self.callbacks+1
        end)
    end
    function f:finish() local cb,task=self.ready,self.task;cb(task()) end
    return f
end
local f=fixture();expect(f:start());f.point.chapter_offset=999;f:finish()
expect(f.candidate and f.candidate.chapter_offset==13 and f.http==1 and f.callbacks==1,'frozen input was mutated or TXT proof missing')
expect(f.candidate.raw_percent==18 and f.candidate.summary==f.excerpt.text and next(f.receipt)==nil)
expect(f.face:is_current_native_preview(f.receipt,f.candidate) and f.face:native_preview_deadline(f.receipt,f.candidate)==130)
expect(not f.face:is_current_native_preview({},f.candidate),'forged receipt accepted')
local changed=F.clone(f.candidate);changed.summary='changed';expect(not f.face:is_current_native_preview(f.receipt,changed))
f.chapters[1].chapterIdx=4;expect(not f.face:is_current_native_preview(f.receipt,f.candidate),'new catalog retained old plan')
for _i,change in ipairs({'auth','scope','offline','expired','owner','rollback'}) do
    f=fixture();f:start();f:finish()
    if change=='auth' then f.auth=false elseif change=='scope' then f.scope=false elseif change=='offline' then f.online=false
    elseif change=='expired' then f.clock=131 elseif change=='owner' then f.owned=false else f.clock=99 end
    expect(not f.face:is_current_native_preview(f.receipt,f.candidate),'closed guard ignored '..change)
end
f=fixture();f.bad_point=true;f:start();f:finish();expect(not f.candidate and f.http==0,'wrong archive point reached HTTP')
f=fixture();f.wrong_basis=true;f:start();f:finish();expect(not f.candidate and f.reason=='source_currentness_unavailable','XHTML proof enabled TXT')
f=fixture();f:start();local stale=f.ready;local work=f.task;f.face:cancel_upload_preview();stale(work())
expect(f.callbacks==0 and not f.face.receipt,'cancelled close delivered a late receipt')
f=fixture();f.worker_failure=true;expect(not f:start() and f.callbacks==1 and f.reason=='source_worker_unavailable')
f=fixture();f.online=false;expect(not f:start() and f.callbacks==1 and f.http==0,'offline source made HTTP')
f=fixture();f.expired=1;f:start();local old=f.ready;local work_old=f.task;f:finish()
expect(f.callbacks==0 and f.renewals==1 and f.guard(),'real source expiry did not wait for one recovery')
f.clock=125;f.access={web={new=true}};f.renewed(f.access);old(work_old());expect(f.callbacks==0,'old proof won after renewal')
f:finish();expect(f.candidate and f.face:native_preview_deadline(f.receipt,f.candidate)==135,'renewal exceeded overall bound')
f=fixture();f.expired=2;f:start();f:finish();f.renewed(f.access);f:finish()
expect(f.callbacks==1 and not f.candidate and f.renewals==1 and f.reason=='source_authentication_unavailable','second expiry renewed twice')
f=fixture();f.expired=1;f:start();f:finish();f.scope=false;expect(not f.guard(),'renewal permitted a different account')
print(('native_close_source_spec: %d checks'):format(checks))
