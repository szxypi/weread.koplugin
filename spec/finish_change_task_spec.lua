package.path='./?.lua;'..package.path
local C=require('weread.lib.finish_change_contract');local Task=require('weread.lib.finish_change_task')
local Access=require('weread.lib.native_read_access');local F=require('spec.helpers.thought_edit_fixture')
local checks=0;local function expect(v,label) checks=checks+1;assert(v,label) end
local function shelf(finished) return {books={{bookId='41',title='Synthetic target',finishReading=finished,secret=0},{bookId='42',title='Synthetic other',finishReading=1}},archive={{archiveId=1,name='Synthetic',bookIds={'41'}}}} end
local function progress(offset) return {book={bookId='41',chapterUid=2,chapterIdx=2,chapterOffset=offset or 100,progress=37.5}} end
local function fixture(queue,before,desired)
    local f={requests={},posts=0,claims=0,phase='prepared',queue=queue,waits=0}
    local settings,store,state=F.access();f.auth=state;f.client=F.codec()
    f.record={metadata=C.make(shelf(before or 0),progress(),'41',desired==nil or desired).metadata}
    local journal={owns=function()
        f.owns_calls=(f.owns_calls or 0)+1
        if f.fail_owns_call==f.owns_calls or f.fail_owns_from and f.owns_calls>=f.fail_owns_from then return false,'storage' end
        return f.phase~='idle' and not f.revoked
    end,claim=function()
        if f.phase~='prepared' or f.fail_claim then return nil,f.fail_claim_reason end;f.phase='pending';f.claims=f.claims+1;return true
    end}
    local decode=f.client.json_decode;local response
    function f.client:json_decode(value) if value=='wire' then return F.clone(response.data or response) end;return decode(self,value) end
    function f.client:request(options)
        expect(options.skip_cookie and options.persist_response_cookies==false and options.sensitive,'request used shared Web state')
        expect(options.headers.vid=='900000' and options.headers.accessToken=='synthetic-access' and not options.headers.Cookie,'wrong owner/credentials')
        if options.method=='POST' then
            expect(f.phase=='pending' and f.claims==1,'POST preceded atomic claim')
            f.posts=f.posts+1;expect(f.posts==1 and options.url=='https://i.weread.qq.com/book/markstatus','unexpected/repeated POST')
            f.body=decode(self,options.body)
        else expect(options.url=='https://i.weread.qq.com/shelf/sync' or options.url=='https://i.weread.qq.com/book/getProgress?bookId=41','unrelated GET') end
        f.requests[#f.requests+1]=options;response=assert(table.remove(f.queue,1),'missing synthetic response')
        if response.raise then error('synthetic lost response',0) end
        if response.stream then options.sink(response.stream) end
        return response.raw or 'wire',response.status or 200
    end
    function f.run()
        return Task.run(f.client,settings,Access.capture(settings,store),{book_id='41',desired=f.record.metadata.desired},f.record,journal,{sleep=function() f.waits=f.waits+1 end})
    end
    return f
end
for _i,ack in ipairs({{}, {status=200,data={status=1}}, {raise=true}, {status=401},{status=429},{data={finishReading=1}}}) do
    local f=fixture({shelf(0),progress(),ack,shelf(1),progress()});local result=f.run()
    expect(result.kind=='confirmed' and result.attempted and f.posts==1 and f.claims==1 and #f.requests==5,'exact independent result not confirmed')
    expect(f.body.isCancel==0 and f.body.auto==0 and f.body.finishInfo==0 and f.body.status==4,'mark body differs from Python')
end
local f=fixture({shelf(1),progress(),{},shelf(0),progress()},1,false);local result=f.run()
expect(result.kind=='confirmed' and f.body.isCancel==1 and f.posts==1,'unmark not a single explicit operation')
f=fixture({shelf(0),progress(),{},shelf(0),progress(),shelf(0),progress(),shelf(0),progress()});result=f.run()
expect(result.kind=='unconfirmed' and result.attempted and f.posts==1 and #f.requests==9 and f.waits==2,'stale result retried writes or unbounded reads')
for _i,kind in ipairs({'member','other_mark','private','position'}) do
    local after=shelf(1);local point=progress()
    if kind=='member' then after.books[2]=nil elseif kind=='other_mark' then after.books[2].finishReading=0
    elseif kind=='private' then after.books[1].secret=1 else point=progress(101) end
    f=fixture({shelf(0),progress(),{},after,point});result=f.run()
    expect(result.kind=='unconfirmed' and #f.requests==5 and f.posts==1 and f.phase=='pending','unrelated change accepted or automatically restored')
end
for _i,status in ipairs({401,403,429,500,502,503,504}) do
    f=fixture({{status=status}});result=f.run()
    local kind=status==401 and 'login' or status==429 and 'rate_limited' or status>=500 and 'temporary' or 'unavailable'
    expect(not result.attempted and result.kind==kind and f.posts==0,'failed preflight dispatched')
end
f=fixture({shelf(0),{status=503}});result=f.run()
expect(not result.attempted and result.kind=='temporary' and f.posts==0,'temporary position read was not classified')
for _,reason in ipairs({'native_auth/finish_write/http_503','native_auth/shelf/http_501','unexpected',false}) do
    expect(Task.read_error(reason)=='unavailable','unknown or post-write failure was classified as retryable')
end
f=fixture({shelf(1),progress()});result=f.run()
expect(result.kind=='changed' and not result.attempted and f.posts==0,'state changed after confirmation dispatched')
local missing=shelf(0);missing.archive=nil
f=fixture({missing,progress()});result=f.run()
expect(result.kind=='unavailable' and not result.attempted and f.posts==0,'missing groups allowed finished-mark write')
f=fixture({shelf(0),progress()});f.fail_claim=true;result=f.run()
expect(result.kind=='unavailable' and not result.attempted and f.posts==0 and f.phase=='prepared',
    'unclassified claim failure dispatched or became retryable')
for _,at in ipairs({1,2,3,4}) do
    f=fixture({shelf(0),progress()});f.fail_owns_call=at;result=f.run()
    expect(result.kind=='temporary' and not result.attempted and f.posts==0 and f.phase=='prepared',
        'pre-dispatch storage failure did not remain safely retryable at check '..at)
end
f=fixture({shelf(0),progress()});f.fail_claim=true;f.fail_claim_reason='storage';result=f.run()
expect(result.kind=='temporary' and not result.attempted and f.posts==0 and f.phase=='prepared',
    'pre-dispatch claim storage failure was not safely retryable')
f=fixture({shelf(0),progress(),{}});f.fail_owns_from=5;result=f.run()
expect(result.kind=='unconfirmed' and result.attempted and f.posts==1 and f.phase=='pending',
    'post-dispatch storage failure was incorrectly made retryable')
f=fixture({});f.revoked=true;result=f.run()
expect(result.kind=='login' and not result.attempted and #f.requests==0,'cancelled state reached transport or became retryable')
f=fixture({shelf(0),progress(),{}, {status=401},{status=401},{status=401}});result=f.run()
expect(result.kind=='unconfirmed' and f.posts==1 and #f.requests==6 and f.phase=='pending','post-write401 renewed or replayed')
f=fixture({{raw=string.rep('x',4*1024*1024+1)}});result=f.run()
expect(result.kind=='unavailable' and f.posts==0,'oversized preflight dispatched')
print('PASS: single finished-mark preflight and readback ('..checks..' checks)')
