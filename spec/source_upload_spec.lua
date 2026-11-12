package.path='./?.lua;'..package.path
local Upload=require('weread.lib.source_upload')
local Readback=require('weread.lib.progress_readback')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message or ('check '..checks)) end
local function copy(value)
    if type(value)~='table' then return value end
    local out={};for k,v in pairs(value) do out[k]=copy(v) end;return out
end
local point={book_id='900001',chapter_uid='11',chapter_offset=4000,basis='filtered_xhtml_utf16',upload_verified=false,
    file_id=string.rep('a',64),book_version=1,raw_sha256=string.rep('b',64),render_path='chapter.xhtml'}
local intent={book_id='900001',chapter_uid=22,chapter_idx=2,chapter_offset=17,percent=37,source_position=copy(point)}
local candidate={book_id='900001',chapter_uid='11',chapter_idx=0,chapter_offset=4000,percent=37,
    summary='原文😀ABCDEFGHIJKLMNOP',basis='filtered_xhtml_utf16',upload_verified=false}
local clock,valid,current=100,true,copy(point)
local callbacks,tasks={},{}
local source={current=function() return current end,cancel_upload_preview=function() end,
    prepare_current_upload_preview=function(_self,callback) callbacks[#callbacks+1]=callback end,
    is_current_upload_preview=function() return valid end,upload_preview_deadline=function() return 130 end}
local scheduler={scheduleIn=function(_self,_delay,fn) tasks[fn]=true end,unschedule=function(_self,fn) tasks[fn]=nil end}
local upload=Upload:new{source=source,scheduler=scheduler,now=function() return clock end}
local plan,reason,count
local function begin(value)
    plan,reason,count=nil,nil,0
    return upload:prepare(value or copy(intent),function(p,why) plan,reason,count=p,why,count+1 end)
end
local function finish(value) callbacks[#callbacks](value or copy(candidate),nil,{}) end
expect(begin() and not plan and count==0,'preparation was not asynchronous')
finish()
expect(plan and plan.is_current() and count==1,'fresh source plan missing')
expect(plan.position.chapter_offset==4000 and plan.position.chapter_uid=='11' and plan.position.chapter_idx==0,'wire used word position or guessed chapter')
expect(plan.position.summary==candidate.summary and plan.position.percent==37,'summary or display percent changed')
expect(not plan.position.basis and plan.position.upload_verified==nil and not plan.position.source_position,'local metadata entered wire')
expect(Readback.expected('900001',plan.position),'explicit plan did not cross the wire boundary')
expect(not Readback.expected('900001',candidate),'raw candidate crossed without adapter')
expect(intent.chapter_offset==17 and intent.source_position.chapter_offset==4000 and not intent.source_position.summary,'intent was mutated')
local original=copy(plan.position);plan.position.chapter_offset=17
expect(not plan.is_current(),'caller changed plan coordinates')
plan.position=original;plan.deadline=999
expect(not plan.is_current(),'caller extended source expiry')
plan.deadline=130;expect(plan.is_current(),'original plan no longer valid')
valid=false;expect(not plan.is_current(),'revoked source receipt accepted');valid=true
for _i,key in ipairs({'chapter_offset','raw_sha256','file_id','chapter_uid'}) do
    begin();current=copy(point);current[key]='changed';finish()
    expect(not plan and count==1,'changed native source was accepted: '..key)
    current=copy(point)
end
begin();local changed=copy(candidate);changed.percent=38;finish(changed)
expect(not plan and reason=='source_position_changed','changed projection was accepted')
begin();changed=copy(candidate);changed.chapter_offset=17;finish(changed)
expect(not plan,'candidate crossed a different source point')
local starts=#callbacks
expect(not begin({book_id='900001',percent=37,source_position={basis='raw_txt_utf16'}}) and not plan,'TXT silently used XHTML units')
expect(#callbacks==starts,'unsupported format dispatched reads')
local old_count=0
upload:prepare(copy(intent),function(p,why) old_count=old_count+1;expect(not p and why=='source_cancelled','superseded preparation was not cancelled') end)
local late=callbacks[#callbacks]
begin();late(copy(candidate),nil,{})
expect(old_count==1 and count==0,'late old callback affected new preparation')
finish();expect(plan and count==1,'new preparation was lost')
begin();local timeout=upload.job.timeout
clock=101;timeout();expect(upload.job and count==0,'accelerated scheduler expired a fresh job')
clock=136;timeout();expect(not upload.job and not plan and reason=='source_preparation_timeout','bounded preparation did not expire')
callbacks[#callbacks](copy(candidate),nil,{})
expect(count==1,'timed-out worker called consumer again')
expect(next(tasks)==nil,'completed preparation retained timer')
current=copy(point);begin();upload:on_view_changed()
expect(upload.job and count==0,'unchanged repaint cancelled source preparation')
current.chapter_offset=4001;upload:on_view_changed()
expect(not upload.job and count==1 and reason=='source_position_changed','movement waited for preparation timeout')
current=copy(point)
clock=100
local check_ready,frame_current
source._live=function() return {book_id='900001',generation=1} end
source.generation=1
source._current=function() return frame_current end
source.check=function(_self,callback) check_ready=callback;return true end
local initial={book_id='900001',percent=37}
frame_current=true;begin(initial)
expect(not plan and count==0,'missing initial source did not wait for capture')
check_ready(copy(point));finish()
expect(plan and plan.source_position.chapter_offset==4000 and not initial.source_position,'capture did not bind its original frame without mutating intent')
frame_current=false;begin(initial);check_ready(copy(point))
expect(not plan and count==1 and reason=='source_position_unavailable','changed initial frame was adopted')
frame_current=true;begin(initial);check_ready(nil,'no_visible_text')
expect(not plan and reason=='source_no_visible_text','native failure escaped as a raw implementation code')
local routed,cancelled,views=0,0,0
upload.native={job={},cancel=function(self) cancelled=cancelled+1;self.job=nil;return true end,
    on_view_changed=function() views=views+1 end,prepare=function(_self,value,cb)
        routed=routed+1;expect(value.native_position_only==true);cb({transport='native_position'});return true
    end}
local raw_intent={book_id='900001',percent=37,source_position={basis='raw_txt_utf16'}}
local before_cancel=cancelled
begin(raw_intent)
expect(not plan and reason=='source_format_unsupported' and cancelled==before_cancel,'time reporter cancelled native position upload')
raw_intent.native_position_only=true;begin(raw_intent)
expect(plan.transport=='native_position' and routed==1,'explicit zero-time request did not route natively')
upload:on_view_changed();expect(views==1)
local previous_callbacks=#callbacks
local unsupported=copy(intent);unsupported.book_id='CB_SyntheticOnly';unsupported.source_position.book_id=unsupported.book_id
expect(not begin(unsupported) and reason=='source_book_sync_unsupported','CB upload masqueraded as temporary source failure')
expect(#callbacks==previous_callbacks and not upload.job and not plan,'CB upload performed source preparation')
print(('source_upload_spec: %d checks'):format(checks))
