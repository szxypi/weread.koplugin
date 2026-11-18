package.path='./?.lua;'..package.path
local Report=require('weread.lib.read_report')
local Protocol=require('weread.lib.protocol')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message or ('check '..checks)) end
local function clone(value)
    if type(value)~='table' then return value end
    local out={};for key,item in pairs(value) do out[key]=clone(item) end;return out
end
local id='CB_SyntheticPosition'
local position={book_id=id,chapter_uid='12',chapter_idx=3,chapter_offset=45,percent=42,
    summary='Synthetic long original summary preserved beyond twenty characters.'}
local point={book_id=id,chapter_uid='12',chapter_offset=45,basis='filtered_xhtml_utf16',upload_verified=false}
local function fixture(mode)
    local posts,reads,valid,prepares,persisted={},0,true,0,nil
    local book={book_id=id,psvts='synthetic-ps',pclts='synthetic-pc',token='synthetic-token',summary='persisted original'}
    local settings={get=function(_self,key) if key=='books' then return {[id]=book} end;return {} end}
    local client={}
    function client:report_read(payload,_referer,options)
        expect(options and options.sensitive==true,'private request lost sensitivity')
        posts[#posts+1]=clone(payload)
        if mode=='after_enter' and #posts==1 or mode=='after_report' and #posts==2 then valid=false end
        if mode=='noack' then return {},200 end
        if mode=='error' then error('synthetic transport failure') end
        return {succ=1},200
    end
    function client:get_web_progress(book_id,options)
        expect(options and options.sensitive==true and book_id==id,'wrong readback target')
        reads=reads+1
        return {book={bookId=id,chapterUid=12,chapterIdx=3,chapterOffset=45,
            progress=mode=='percent' and 43 or 42,summary=mode=='summary' and 'truncated' or position.summary}}
    end
    local report=Report:new{settings=settings,client=client,scheduler={scheduleIn=function() end,unschedule=function() end},
        get_document=function() return {} end,detect_book=function() return id end,subprocess=false}
    report._auth_fingerprint=function() return 'synthetic-auth' end
    report.ensure_context=function() if mode=='after_context' then valid=false end;return book end
    report._persist_context=function(_self,_id,snapshot) persisted=clone(snapshot) end
    local plan={position=clone(position),source_position=clone(point),basis='filtered_xhtml_utf16',transport='cb_web_position',
        is_current=function() return valid end,before_send=function() prepares=prepares+1;return valid end}
    return report,plan,posts,function() return reads,prepares,persisted,book end
end
local report,plan,posts,state=fixture('normal')
local ok,outcome=report:upload_cb_position(id,position,plan)
expect(ok and outcome.acknowledged and outcome.position_confirmed,'valid CB send did not confirm')
expect(#posts==2 and posts[1].rt==nil and posts[2].rt==0,'wrong enter or report sequence')
for _i,body in ipairs(posts) do
    expect(body.sm==position.summary and body.co==45 and body.b==Protocol.e(id),'summary or position changed')
    local signature=body.s;body.s=nil;expect(signature==Protocol.sign(Protocol.sorted_query(body)),'invalid signature');body.s=signature
end
local reads,prepared,persisted,book=state()
expect(reads==1 and prepared==2,'readback or dispatch gate count changed')
expect(book.summary=='persisted original' and persisted.summary=='persisted original','private summary persisted')
for _i,mode in ipairs({'after_context','after_enter','after_report','noack','error','summary','percent'}) do
    report,plan,posts,state=fixture(mode)
    ok,outcome=report:upload_cb_position(id,position,plan)
    reads=state()
    expect(not ok,'invalid/unknown operation accepted')
    expect(#posts==(mode=='after_context' and 0 or (mode=='after_enter' or mode=='noack' or mode=='error') and 1 or 2),'send repeated or wrong phase')
    if mode=='after_report' then expect(outcome.acknowledged and reads==0 and outcome.error_kind=='unconfirmed',
        'changed scope confirmed a sent CB position') end
    if mode=='summary' or mode=='percent' then
        expect(outcome.acknowledged and not outcome.position_confirmed and reads==1,'invalid readback confirmed')
        local receipt=outcome.confirmation
        local first=select(1,report:confirm_position(receipt));local second=select(1,report:confirm_position(receipt))
        expect(not first and not second and select(1,state())==3,'readback retries exceeded bound')
    end
end
report,plan,posts=fixture('normal')
local regular=clone(plan);regular.transport=nil
expect(not report:upload_position(id,position,0,regular) and #posts==0,'regular path accepted imported book')
local bad=clone(plan);bad.transport='other'
expect(not report:upload_cb_position(id,position,bad) and #posts==0,'missing imported authority accepted')
bad=clone(plan);bad.source_position.book_id='CB_Foreign'
expect(not report:upload_cb_position(id,position,bad) and #posts==0,'foreign source accepted')
bad=clone(plan);bad.source_position.chapter_offset=46
expect(not report:upload_cb_position(id,position,bad) and #posts==0,'different source point accepted')
bad=clone(plan);bad.before_send=nil
expect(not report:upload_cb_position(id,position,bad) and #posts==0,'missing pre-dispatch check accepted')
report,plan,posts=fixture('normal')
expect(report:upload_position(id,position,0,plan) and #posts==2,'guarded CB transport was not routed')
report,plan,posts=fixture('normal')
expect(not report:upload_position(id,position,1,plan) and #posts==0,'nonzero elapsed time reached CB route')
local fractional=clone(position);fractional.percent=42.5;plan.position=clone(fractional)
expect(not report:upload_cb_position(id,fractional,plan) and #posts==0,'fractional CB position was dispatched')
print(('cb_read_report_position_spec: %d checks'):format(checks))
