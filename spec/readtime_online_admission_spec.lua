package.path='./?.lua;./?/init.lua;'..package.path
local H=require('spec.helpers.annotation_test_store')
package.preload['lua-ljsqlite3/init']=function() return {open=H.connect} end
package.preload['weread.lib.content']=function() return {} end
package.preload['weread.lib.logger']=function() return {scoped=function() return {info=function() end,warn=function() end} end} end
local Coverage=require('weread.lib.readtime_coverage')
local ReadReport=require('weread.lib.read_report')
local Crypto=require('weread.lib.crypto')
local Protocol=require('weread.lib.protocol')
local enter,read=Protocol.make_enter_read_payload,Protocol.make_read_payload
local now=1000
Protocol.make_enter_read_payload=function(options) options.now=now;return enter(options) end
Protocol.make_read_payload=function(options) options.now=now;return read(options) end
local checks=0;local function eq(a,b) checks=checks+1;assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local root=os.tmpname()..'-online-admission';os.execute('mkdir -p '..string.format('%q',root))
local account=Crypto.sha256_hex('weread-library:123'):sub(1,20)
local coverage=Coverage:new(root,function() return 100 end);assert(coverage:initialize())
local db=H.connect(coverage.path)
local statement=db:prepare('INSERT INTO offline_time_seals VALUES(?,?,?,?)')
statement:bind(account,'consumed',965,995):step();statement:close();db:close()
local calls,renewals,context_calls,delay=0,0,0,nil
local scheduler={scheduleIn=function(_self,seconds) delay=seconds end,unschedule=function() end}
local settings={get=function(_self,key,default)
    if key=='cookies' then return {wr_vid='123'} end
    if key=='read_report' then return {enabled=true,interval_seconds=30} end
    return default
end}
local client={report_read=function(_self,payload)
    calls=calls+1
    if not payload.rt or payload.rt==0 then
        local view=assert(coverage:preview(account,{{id=1,start_time=995,duration=30}}))
        eq(view.covered,30) -- committed before even entering the reading session
        now=1032
    else
        eq(payload.ct,1025);eq(payload.rt,30)
        eq(payload.ct-payload.rt,995) -- touches, never overlaps, offline end
    end
    return {succ=1}
end,renew_cookie=function() renewals=renewals+1 end}
local reporter=ReadReport:new{settings=settings,client=client,scheduler=scheduler,now=function() return now end,
    coverage=coverage,get_document=function() end,detect_book=function() end,subprocess=false}
local book={book_id='42',chapter_uid=1,chapter_idx=1,chapter_offset=1,progress=1,pclts='1'}
reporter.ensure_context=function() context_calls=context_calls+1;return book end
local outcome=reporter:_run_pipeline('42',{source_deadline=1030})
eq(outcome.deferred_until,1025);eq(calls,0);eq(renewals,0);eq(context_calls,1)
eq(outcome.enter_attempted,false);eq(outcome.report_attempted,false);eq(outcome.source_unconfirmed,nil)
eq(reporter:_apply_outcome(outcome),false);eq(reporter.failure_count,0);eq(reporter.state,'waiting_for_offline_time')
local task=function() end;reporter.generation,reporter.task=7,task
reporter:_schedule_next(7,task);eq(delay,25)
now=1026
eq(reporter:_apply_outcome(outcome),false);eq(reporter.state,'waiting_for_offline_time')
reporter:_schedule_next(7,task);eq(delay,.1);eq(reporter.failure_count,0)
now=1025
outcome=reporter:_run_pipeline('42',{})
eq(outcome.accepted,true);eq(calls,2);eq(renewals,0);eq(context_calls,2)
-- Zero-time progress work never asks the coverage database for admission.
coverage.reserve=function() error('unexpected positive reservation') end
local before=calls
assert(pcall(reporter._send,reporter,'42',book,nil,0));eq(calls,before+1)
Protocol.make_enter_read_payload,Protocol.make_read_payload=enter,read
os.execute('rm -rf '..string.format('%q',root))
print('readtime_online_admission_spec: '..checks..' checks')
