package.path='./?.lua;'..package.path
local Report=require('weread.lib.read_report')
local Protocol=require('weread.lib.protocol')
local n=0;local function expect(value,message) n=n+1;assert(value,message or ('check '..n)) end
local id='CB_SyntheticTime'
local position={book_id=id,chapter_uid='12',chapter_idx=3,chapter_offset=45,percent=42,
    summary='Synthetic long original summary preserved beyond twenty characters.'}
local function fixture(mode)
    local posts,reads,coverage,auth={},0,{},'A'
    local book={book_id=id,psvts='synthetic-ps',pclts='synthetic-pc',token='synthetic-token',summary='saved context'}
    local settings={get=function(_self,key)
        if key=='books' then return {[id]=book} end
        if key=='read_report' then return {enabled=true,mode='auto',interval_seconds=30} end
        if key=='cookies' then return {wr_vid='900000'} end
        return {}
    end,is_cookie_configured=function() return true end}
    local client={}
    function client:report_read(payload,_referer,options)
        expect(options and options.sensitive==true,'time request lost sensitive handling')
        posts[#posts+1]=payload
        if mode=='after_enter' and #posts==1 then auth='B' end
        if mode=='transport' then error('synthetic transport') end
        if mode=='noack' then return {},200 end
        return {succ=1},200
    end
    function client:get_web_progress(book_id,options)
        expect(book_id==id and options.sensitive,'wrong time readback')
        reads=reads+1
        return {book={bookId=id,chapterUid=12,chapterIdx=3,chapterOffset=45,progress=42,
            summary=mode=='bad_summary' and 'different' or position.summary}}
    end
    local report=Report:new{settings=settings,client=client,scheduler={scheduleIn=function() end,unschedule=function() end},
        get_document=function() return {} end,detect_book=function() return id end,subprocess=false,
        now=function() return mode=='expired' and 200 or 100 end,
        coverage={reserve=function(_self,account,endpoint,seconds)
            coverage[#coverage+1]={account=account,endpoint=endpoint,seconds=seconds}
            if mode=='overlap' then return nil,'offline_overlap',130 end
            return true
        end}}
    report._auth_fingerprint=function() return auth end
    report.ensure_context=function() return book end
    return report,posts,coverage,function() return reads end
end
for _,mode in ipairs({'normal','noack','transport','after_enter','expired','bad_summary','overlap'}) do
    local report,posts,coverage,reads=fixture(mode)
    local outcome=report:_run_pipeline(id,{position=position,source_deadline=130,cb_source=true,elapsed_seconds=2})
    if mode=='normal' then
        expect(outcome.accepted and outcome.position_confirmed and outcome.acknowledged,'CB time was not confirmed')
        expect(#posts==2 and posts[1].rt==nil and posts[2].rt==2,'CB time sent wrong duration or enter sequence')
        expect(posts[2].sm==position.summary and posts[2].b==Protocol.e(id),'CB time lost exact summary or identity')
        expect(#coverage==1 and coverage[1].seconds==2 and reads()==1,'CB time skipped coverage or readback')
    elseif mode=='expired' then expect(#posts==0 and #coverage==0 and not outcome.accepted,'expired CB proof sent')
    elseif mode=='overlap' then expect(#posts==0 and #coverage==1 and outcome.deferred_until==130,'offline overlap did not defer')
    elseif mode=='after_enter' then expect(#posts==1 and outcome.source_unconfirmed,'changed session continued after enter')
    elseif mode=='bad_summary' then expect(#posts==2 and reads()==3 and outcome.source_unconfirmed,'wrong CB summary confirmed or retried a write')
    else expect(#posts==1 and outcome.source_unconfirmed and reads()==0,'unknown CB time write was retried') end
    expect(not outcome.renew_attempted,'CB time attempted credential renewal')
end
local saved_summary=position.summary;position.summary='raw\r\nTXT synthetic summary'
for _,mode in ipairs({'normal','noack','transport','after_enter','expired','bad_summary','overlap'}) do
    local timed,posts,coverage,reads=fixture(mode)
    local outcome=timed:_run_pipeline(id,{position=position,source_deadline=130,cb_source=true,elapsed_seconds=2})
    if mode=='normal' then
        expect(outcome.accepted and outcome.position_confirmed and #posts==2 and posts[2].rt==2
            and posts[2].sm==position.summary and #coverage==1 and reads()==1,'raw TXT time lost its summary or confirmation')
    elseif mode=='expired' then expect(#posts==0 and #coverage==0 and not outcome.accepted,'expired TXT proof sent')
    elseif mode=='overlap' then expect(#posts==0 and #coverage==1 and outcome.deferred_until==130,'TXT overlap did not defer')
    elseif mode=='after_enter' then expect(#posts==1 and outcome.source_unconfirmed,'changed TXT session continued after enter')
    elseif mode=='bad_summary' then expect(#posts==2 and reads()==3 and outcome.source_unconfirmed,'wrong TXT summary confirmed')
    else expect(#posts==1 and outcome.source_unconfirmed and reads()==0,'unknown TXT time write was retried') end
    expect(not outcome.renew_attempted,'TXT time attempted credential renewal')
end
position.summary=saved_summary
local report,posts=fixture('normal')
expect(not report:_run_pipeline(id,{position=position,source_deadline=130}).accepted and #posts==0,'CB bypassed dedicated source gate')
expect(not report:_run_pipeline(id,{position=position,cb_source=true}).accepted and #posts==0,'CB bypassed proof deadline')
report.coverage=nil
local uncovered=report:_run_pipeline(id,{position=position,source_deadline=130,cb_source=true})
expect(not uncovered.accepted and uncovered.enter_attempted==false and uncovered.report_attempted==false and #posts==0,
    'CB time sent without durable coverage')
local stale=fixture('normal');local started=0
stale._start_job=function() started=started+1 end
stale:_dispatch_tick(1,function() end,id,position,130,{transport='cb_web_position',is_current=function() return true end})
expect(started==0,'CB time started without a dispatch journal')
for _,changed in ipairs({false,true}) do
    local timed=fixture('normal');local ready,sends=nil,0
    local baseline={book_id=id,source='web',chapter_uid='12',chapter_idx=3,chapter_offset=45,
        raw_percent=42,updated_at=123,has_chapter_index=true,has_chapter_offset=true}
    local first={expected_remote=baseline};local second={expected_remote={}}
    for key,value in pairs(baseline) do second.expected_remote[key]=value end
    if changed then second.expected_remote.updated_at=124 end
    local checks=0;timed._precheck=function() checks=checks+1;return true,id,checks==1 and first or second end
    timed.position_preparer=function(_value,callback) ready=callback end
    timed._dispatch_tick=function() sends=sends+1 end
    timed.generation=1;timed.task=function() end;timed:_tick(1,timed.task)
    ready({transport='cb_web_position',is_current=function() return true end})
    expect(sends==(changed and 0 or 1),'changed CB baseline reached timed dispatch')
end
print('cb_readtime_report_spec: '..n..' checks')
