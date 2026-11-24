package.path='./?.lua;'..package.path
local C=require('weread.lib.reading_state_change_contract')
local Task=require('weread.lib.reading_state_change_task')
local Access=require('weread.lib.native_read_access')
local F=require('spec.helpers.thought_edit_fixture')
local function shelf(id)
    return {books={{bookId=id,title='Target',finishReading=0,secret=0},{bookId='42',title='Other',finishReading=1}},
        archive={{archiveId=1,name='Group',bookIds={id}}}}
end
local function progress(id,flag)
    return {book={bookId=id,isStartReading=flag,startReadingTime=flag==1 and 123 or 0,
        chapterUid=0,chapterIdx=0,chapterOffset=0,progress=0,summary='',readingTime=0,recordReadingTime=0,ttsTime=0}}
end
local function fixture(id,queue,before,desired)
    local f={requests={},posts=0,claims=0,phase='prepared',queue=queue,waits=0}
    local settings,store,state=F.access();f.auth=state;f.client=F.codec()
    f.record={metadata=C.make(shelf(id),progress(id,before),id,'900000',desired).metadata}
    local journal={owns=function() return f.phase~='idle' and not f.revoked end,claim=function()
        if f.phase~='prepared' or f.fail_claim then return nil,f.fail_claim and 'storage' end
        f.phase='pending';f.claims=f.claims+1;return true
    end}
    local decode=f.client.json_decode;local response
    function f.client:json_decode(value) if value=='wire' then return F.clone(response.data or response) end;return decode(self,value) end
    function f.client:request(options)
        assert(options.skip_cookie and options.persist_response_cookies==false and options.sensitive)
        assert(options.headers.vid=='900000' and options.headers.accessToken=='synthetic-access' and not options.headers.Cookie)
        if options.method=='POST' then
            assert(f.phase=='pending' and f.claims==1 and options.url=='https://i.weread.qq.com/book/markstatus')
            f.posts=f.posts+1;assert(f.posts==1);f.body=decode(self,options.body)
        else
            assert(options.url=='https://i.weread.qq.com/shelf/sync'
                or options.url=='https://i.weread.qq.com/book/getProgress?bookId='..id)
        end
        f.requests[#f.requests+1]=options;response=assert(table.remove(f.queue,1),'missing synthetic response')
        if response.raise then error('synthetic timeout',0) end
        return response.raw or 'wire',response.status or 200
    end
    function f.run()
        return Task.run(f.client,settings,Access.capture(settings,store),{book_id=id,desired=desired},f.record,journal,
            {sleep=function() f.waits=f.waits+1 end})
    end
    return f
end
for _,id in ipairs({'41','CB_abc'}) do
    for _,response in ipairs({{}, {data={status=1}}, {raise=true}, {status=401}}) do
        local f=fixture(id,{shelf(id),progress(id,0),response,shelf(id),progress(id,1)},0,true)
        local result=f.run()
        assert(result.kind=='confirmed' and result.attempted and f.posts==1 and f.claims==1)
        assert(f.body.bookId==id and f.body.status==2 and f.body.isCancel==0)
    end
    local f=fixture(id,{shelf(id),progress(id,1),{},shelf(id),progress(id,0)},1,false)
    assert(f.run().kind=='confirmed' and f.body.isCancel==1 and f.posts==1)
end
local id='41'
local f=fixture(id,{shelf(id),progress(id,0),{},shelf(id),progress(id,0),shelf(id),progress(id,0),shelf(id),progress(id,0)},0,true)
local result=f.run();assert(result.kind=='unconfirmed' and result.attempted and f.posts==1 and f.waits==2)
for _,kind in ipairs({'other_flag','group','position','counter','start_time'}) do
    local after,point=shelf(id),progress(id,1)
    if kind=='other_flag' then after.books[2].secret=1
    elseif kind=='group' then after.archive[1].bookIds={}
    elseif kind=='position' then point.book.chapterUid=3;point.book.chapterOffset=1
    elseif kind=='counter' then point.book.readingTime=1
    else point.book.startReadingTime=0 end
    f=fixture(id,{shelf(id),progress(id,0),{},after,point},0,true)
    result=f.run();assert(result.kind=='unconfirmed' and f.posts==1 and f.phase=='pending',kind)
end
f=fixture(id,{shelf(id),progress(id,1)},0,true);result=f.run()
assert(result.kind=='changed' and not result.attempted and f.posts==0)
f=fixture(id,{shelf(id),progress(id,0)},0,false);result=f.run()
assert(result.kind=='noop' and not result.attempted and f.posts==0)
f=fixture(id,{shelf(id),progress(id,0)},0,true);f.fail_claim=true;result=f.run()
assert(result.kind=='temporary' and not result.attempted and f.posts==0)
f=fixture(id,{{status=401}},0,true);result=f.run()
assert(result.kind=='login' and not result.attempted and f.posts==0)
f=fixture(id,{},0,true);f.revoked=true;result=f.run()
assert(result.kind=='login' and not result.attempted and f.posts==0)
assert(Task.read_error('native_auth/reading_change_progress/http_429')=='rate_limited')
assert(Task.read_error('native_auth/reading_change_write/http_503')=='unavailable')
print('PASS: started-reading change preflight, one-shot claim and independent readback')
