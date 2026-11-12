package.path='./?.lua;'..package.path
local Close=require('weread.lib.source_close')
local Source=require('weread.lib.position_source')
local Currentness=require('weread.lib.source_currentness')
local Task=require('weread.lib.source_position_worker')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message or ('check '..checks)) end
local function copy(value)
    if type(value)~='table' then return value end
    local out={};for key,item in pairs(value) do out[key]=copy(item) end;return out
end
local clock,auth,alive=100,true,true
local calls,tasks={},{}
local scheduler={scheduleIn=function(_self,_delay,fn) tasks[fn]=true end,unschedule=function(_self,fn) tasks[fn]=nil end}
local point={book_id='900001',chapter_uid='11',chapter_offset=4000,basis='filtered_xhtml_utf16',upload_verified=false,
    file_id=string.rep('a',64),raw_sha256=string.rep('b',64),book_version=1,render_path='chapter.xhtml'}
local intent={book_id='900001',chapter_uid=22,chapter_idx=2,chapter_offset=17,percent=37,source_position=copy(point)}
local chapters={{chapterUid=11,chapterIdx=0}}
local function native() expect(alive,'closed native document was touched') end
local source={client={settings={data_dir='synthetic-close-profile'}},current=function() native();return copy(point) end,
    is_busy=function() native();return false end,can_prepare=function() native();return true end,
    _live=function() native();return {file='fixture.epub'} end,_current=function() native();return true end,
    get_document=function() native();return {} end,
    get_upload_context=function() native();return {book_id='900001',percent=37,chapters=copy(chapters)} end,
    make_worker=function()
        return {start=function(_self,task,callback) calls[#calls+1]={task=task,callback=callback};return true end,
            cancel=function() end}
    end}
Source.document_metadata=function() native();return {metadata='metadata',identity={file_id=point.file_id},record={raw_bytes=64}} end
Currentness.capture=function() return auth and {web={}} end
Currentness.matches=function() return auth end
Currentness.fetch=function(_client,expected) return {expected=expected} end
Currentness.packet=function(packet,expected) return packet and packet.expected.book_id==expected.book_id end
Task.prepare_upload=function(input)
    expect(input.file=='fixture.epub' and not input.document,'worker inherited native input')
    return {request_id=input.request_id,position=copy(input.target),
        candidate=assert(require('weread.lib.source_upload_candidate').project(input.target,'原文😀',input.chapters,input.percent))}
end
local function new() return Close:new{source=source,scheduler=scheduler,now=function() return clock end,get_catalog=function() return copy(chapters) end} end
local service=new()
local plan,reason,count
local function start()
    alive=true;clock=100;auth=true;chapters={{chapterUid=11,chapterIdx=0}}
    local token=assert(service:freeze(copy(intent)))
    alive=false;plan,reason,count=nil,nil,0
    expect(service:prepare(token,copy(intent),function(value,why) plan,reason,count=value,why,count+1 end))
    return token
end
local function finish()
    local call=calls[#calls];call.callback(call.task())
end
local token=start();finish()
expect(plan and plan.detached and plan.is_current() and count==1,'closed plan did not finish independently')
expect(plan.position.chapter_offset==4000 and plan.position.chapter_idx==0 and not plan.position.basis,'closed upload used word projection')
plan.position.chapter_offset=17;expect(not plan.is_current(),'wire mutation passed closed guard');plan.position.chapter_offset=4000
chapters[1].chapterIdx=2;expect(not plan.is_current(),'changed catalog passed closed guard');chapters[1].chapterIdx=0
clock=131;expect(not plan.is_current(),'closed plan expired late');clock=100
service:on_reader_ready('other');expect(plan.is_current(),'different book revoked closed plan')
new():on_reader_ready('900001');expect(not plan.is_current(),'new plugin reopened same book without revoking close')
local duplicate
expect(not service:prepare(token,intent,function(p) duplicate=p end) and not duplicate,'closed token was reusable')
start();auth=false;finish();expect(not plan and count==1 and reason=='source_currentness_unavailable','changed account kept closed plan')
start();local late=calls[#calls];service:cancel();late.callback(late.task())
expect(not plan and count==1,'cancelled worker called consumer again')
start();finish();plan.release();expect(not plan.is_current() and next(tasks)==nil,'released close retained active timer')
start();clock=136;local timeout=next(tasks);timeout();expect(not plan and count==1 and reason=='source_preparation_timeout','closed preparation was unbounded')
expect(next(tasks)==nil,'timeout leaked timer')
local success_fetch=Currentness.fetch
local expired,renewals,cancelled=0,0,0
local recover_guard,recover_ready
source.recovery={start=function(_self,_book,_access,guard,done)
    renewals=renewals+1;recover_guard,recover_ready=guard,done;return true,{}
end,cancel=function() cancelled=cancelled+1 end}
Currentness.fetch=function(...)
    if expired>0 then expired=expired-1;error('source_currentness/web_expired',0) end
    return success_fetch(...)
end
expired=1;start();local first_call=calls[#calls];finish()
expect(not plan and count==0 and recover_guard() and renewals==1,'closed HTTP 401 did not wait for recovery')
clock=125;recover_ready({web={}})
expect(calls[#calls]~=first_call and count==0,'closed recovery reused old archive/source proof')
first_call.callback(first_call.task());expect(count==0,'late pre-renewal proof replaced the retry')
finish();expect(plan and plan.is_current() and plan.deadline==135 and count==1,'closed recovery extended its overall deadline')
clock=136;expect(not plan.is_current(),'closed recovery sent beyond overall preparation window');plan.release()
expired=2;start();finish();recover_ready({web={}});finish()
expect(not plan and count==1 and reason=='source_authentication_unavailable' and renewals==2,'closed repeated 401 renewed twice')
expired=1;start();finish();local late_recovery=recover_ready;service:cancel();late_recovery({web={}})
expect(not plan and count==1 and cancelled>0,'cancelled closed recovery delivered a plan')
Currentness.fetch=success_fetch
print(('source_close_spec: %d checks'):format(checks))
