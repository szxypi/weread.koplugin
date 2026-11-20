package.path='./?.lua;'..package.path
local Report=require('weread.lib.read_report')
local State=require('weread.lib.cb_initial_state')
local Initial=require('weread.lib.cb_initial_progress')
local Protocol=require('weread.lib.protocol')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message or ('check '..checks)) end
local function copy(value)
    if type(value)~='table' then return value end
    local result={};for key,item in pairs(value) do result[key]=copy(item) end;return result
end
local id='CB_SyntheticFirst'
local point={book_id=id,chapter_uid='12',chapter_offset=45,basis='filtered_xhtml_utf16',upload_verified=false}
local position={book_id=id,chapter_uid='12',chapter_idx=3,chapter_offset=45,percent=42,summary='Synthetic original summary'}
local no_chapter=assert(State.from({book={bookId=id,chapterUid=0,chapterOffset=0,progress=0}},id))
local old_capture,old_current,old_before,old_target=Initial.capture,Initial.current,Initial.before,Initial.target
local function fixture(mode)
    local posts,reads,prepared,persisted={},0,0,nil
    local valid=true
    local book={book_id=id,psvts='synthetic-ps',pclts='synthetic-pc',token='synthetic-token',summary='saved summary'}
    local settings={get=function(_self,key) return key=='books' and {[id]=book} or {} end}
    local access={}
    Initial.capture=function() return access end
    Initial.current=function(_settings,selected,current) return selected==access and valid and current() end
    local baseline_reads=0
    Initial.before=function(_client,_settings,selected,expected,current,allow_time)
        baseline_reads=baseline_reads+1
        if selected~=access or not current() or mode=='baseline_changed'
            or mode=='prior_time' and not allow_time then return nil end
        local result=copy(expected)
        if mode=='native_changed' and baseline_reads==2 then result.updated_present=true;result.updated_at=9 end
        local seconds=mode=='prior_time' and 2 or 0
        if mode=='counts_changed' and baseline_reads==2 then seconds=1 end
        return result,{readingTime=seconds,recordReadingTime=0,ttsTime=0}
    end
    Initial.target=function(_client,_settings,selected,target,summary,current,counts)
        reads=reads+1
        if selected~=access or not current() or summary~=position.summary
            or not counts or counts.readingTime~=(mode=='prior_time' and 2 or 0) or mode=='no_target' or mode=='delayed' and reads==1 then return nil end
        return {book_id=id,chapter_uid=target.chapter_uid,chapter_idx=target.chapter_idx,chapter_offset=target.chapter_offset,
            percent=target.percent,raw_percent=target.percent,source='web',has_chapter_index=true,has_chapter_offset=true}
    end
    local client={report_read=function(_self,payload,_referer,options)
        expect(options and options.sensitive==true,'first request lost private mode')
        posts[#posts+1]=copy(payload)
        if mode=='stale_after_send' then valid=false end
        if mode=='no_ack' then return {},200 end
        if mode=='transport_error' then error('synthetic failure') end
        return {succ=1},200
    end}
    local report=Report:new{settings=settings,client=client,scheduler={scheduleIn=function() end,unschedule=function() end},
        get_document=function() return {} end,detect_book=function() return id end,subprocess=false}
    report._auth_fingerprint=function() return 'synthetic-auth' end
    report.ensure_context=function() return book end
    report._persist_context=function(_self,_id,value) persisted=copy(value) end
    local plan={position=copy(position),source_position=copy(point),basis='filtered_xhtml_utf16',transport='cb_web_initial',
        initial_remote=copy(no_chapter),is_current=function() return valid end,before_send=function()
            prepared=prepared+1;if mode=='stale_after_claim' then valid=false end;return true
        end}
    return report,plan,posts,function() return reads,prepared,persisted,book end
end
local report,plan,posts,stats=fixture('normal')
local ok,result=report:upload_position(id,position,0,plan)
expect(ok and result.acknowledged and result.position_confirmed and result.enter_attempted and not result.report_attempted,
    'first enter did not confirm')
expect(#posts==1 and posts[1].rt==nil and posts[1].sm==position.summary and posts[1].co==45,'wrong first request')
local signature=posts[1].s;posts[1].s=nil
expect(signature==Protocol.sign(Protocol.sorted_query(posts[1])),'first request signature invalid')
local reads,prepared,persisted,book=stats()
expect(reads==1 and prepared==1,'unexpected readback or claims')
expect(book.summary=='saved summary' and persisted.summary=='saved summary','source summary persisted')
for _,mode in ipairs({'baseline_changed','native_changed','counts_changed','stale_after_claim','stale_after_send','no_ack','transport_error','no_target'}) do
    report,plan,posts,stats=fixture(mode);ok,result=report:upload_position(id,position,0,plan)
    expect(not ok,'unsafe first request was accepted')
    local expected=(mode=='baseline_changed' or mode=='native_changed' or mode=='counts_changed' or mode=='stale_after_claim') and 0 or 1
    expect(#posts==expected,'unexpected first request count')
    if expected==1 then expect(result.enter_attempted and not result.report_attempted,'possible send was lost') end
    if mode=='no_target' then
        expect(result.acknowledged and result.error_kind=='confirmation_pending','unconfirmed success was discarded')
        local receipt=result.confirmation
        expect(not report:confirm_position(receipt),'unconfirmed target accepted')
        expect(not report:confirm_position(receipt),'unconfirmed target accepted after retry')
        expect(select(1,stats())==3 and #posts==1,'readback retried the first POST')
    end
end
report,plan,posts=fixture('delayed');ok,result=report:upload_position(id,position,0,plan)
expect(not ok and result.acknowledged and result.confirmation,'delayed readback lost receipt')
ok,result=report:confirm_position(result.confirmation)
expect(ok and result.position_confirmed and result.enter_attempted and result.report_attempted==false and #posts==1,
    'delayed dual readback lost its first-request proof or resent the POST')
report,plan,posts=fixture('normal');plan.initial_remote.book_id='CB_Foreign'
expect(not report:upload_position(id,position,0,plan) and #posts==0,'foreign initial state accepted')
report,plan,posts=fixture('normal')
expect(not report:upload_position(id,position,1,plan) and #posts==0,'time upload entered first-position path')
local original_summary=position.summary;position.summary='raw\r\nTXT summary'
report,plan,posts=fixture('normal');plan.basis='raw_txt_utf16';plan.source_position.basis=plan.basis
ok,result=report:upload_position(id,position,0,plan)
expect(ok and result.position_confirmed and #posts==1 and posts[1].sm==position.summary,'TXT first position lost raw summary')
report,plan,posts=fixture('prior_time')
ok,result=report:upload_position(id,position,0,plan)
expect(ok and result.position_confirmed and #posts==1,'XHTML first position did not preserve prior reading time')
report,plan,posts=fixture('prior_time');plan.basis='raw_txt_utf16';plan.source_position.basis=plan.basis
ok,result=report:upload_position(id,position,0,plan)
expect(ok and result.position_confirmed and #posts==1,'TXT first position did not preserve prior reading time')
report,plan,posts=fixture('no_ack');plan.basis='raw_txt_utf16';plan.source_position.basis=plan.basis
ok,result=report:upload_position(id,position,0,plan)
expect(not ok and result.enter_attempted and #posts==1,'unknown TXT first write was not retained')
report,plan,posts=fixture('normal');plan.source_position.basis='raw_txt_utf16'
expect(not report:upload_position(id,position,0,plan) and #posts==0,'mismatched TXT source units accepted')
position.summary=original_summary
Initial.capture,Initial.current,Initial.before,Initial.target=old_capture,old_current,old_before,old_target
print(('cb_initial_read_report_spec: %d checks'):format(checks))
