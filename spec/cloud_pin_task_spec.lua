package.path='./?.lua;'..package.path
local C=require('weread.lib.shelf_flag_change_contract');local Task=require('weread.lib.shelf_flag_change_task')
local Access=require('weread.lib.native_read_access');local F=require('spec.helpers.thought_edit_fixture')
local checks=0;local function expect(value,label) checks=checks+1;assert(value,label) end
local function shelf(pin)
    local row={bookId='41',title='Synthetic target',finishReading=0,secret=0}
    if pin~=nil then row.isTop=pin end
    return {books={row,{bookId='42',title='Synthetic other',finishReading=1}},
        archive={{archiveId='group',name='Synthetic',bookIds={'41','42'}}}}
end
local function progress(offset) return {book={bookId='41',chapterUid=2,chapterIdx=2,chapterOffset=offset or 100,progress=37.5}} end
local function fixture(before,desired,queue)
    local f={requests={},posts=0,claims=0,phase='prepared',queue=queue,waits=0}
    local settings,store,state=F.access();f.auth=state;f.client=F.codec()
    f.record={metadata=C.make_pin(shelf(before),progress(),'41',desired).metadata}
    local journal={owns=function()return f.phase~='idle' and not f.revoked end,claim=function()
        if f.phase~='prepared' or f.fail_claim then return nil end
        f.phase='pending';f.claims=f.claims+1;return true
    end}
    local encode,decode=f.client.json_encode,f.client.json_decode;local array_mt=getmetatable(decode(f.client,'[]'));local response
    function f.client:json_encode(value)
        if type(value)=='table' and getmetatable(value)==array_mt and next(value)==nil then return f.bad_array and '{}' or '[]' end
        return encode(self,value)
    end
    function f.client:json_decode(value) if value=='wire' then return F.clone(response.data or response) end;return decode(self,value) end
    function f.client:request(options)
        expect(options.skip_cookie and options.persist_response_cookies==false and options.sensitive,'request used shared Web state')
        expect(options.headers.vid=='900000' and options.headers.accessToken=='synthetic-access' and not options.headers.Cookie,'wrong owner')
        if options.method=='POST' then
            expect(f.phase=='pending' and f.claims==1,'POST preceded claim');f.posts=f.posts+1
            expect(f.posts==1 and options.url=='https://i.weread.qq.com/shelf/top','unexpected or repeated POST')
            f.body=decode(self,options.body)
        else expect(options.url=='https://i.weread.qq.com/shelf/sync' or options.url=='https://i.weread.qq.com/book/getProgress?bookId=41','unrelated GET') end
        f.requests[#f.requests+1]=options;response=assert(table.remove(f.queue,1),'missing synthetic response')
        if response.raise then error('synthetic lost response',0) end
        return response.raw or 'wire',response.status or 200
    end
    function f.run()return Task.run(f.client,settings,Access.capture(settings,store),
        {book_id='41',desired=f.record.metadata.desired},f.record,journal,{sleep=function()f.waits=f.waits+1 end})end
    return f
end
local f=fixture(nil,true,{shelf(),progress(),{succ=1},shelf(1),progress()});local result=f.run()
expect(result.kind=='confirmed' and result.attempted and f.posts==1,'pin not confirmed')
expect(f.body.isDel==0 and f.body.bookIds[1]=='41' and getmetatable(f.body.albumIds) and getmetatable(f.body.archiveIds),
    'pin body lost exact arrays or direction')
for _,after in ipairs({shelf(),shelf(0)}) do
    f=fixture(1,false,{shelf(1),progress(),{succ=1},after,progress()});result=f.run()
    expect(result.kind=='confirmed' and result.attempted and f.posts==1 and f.body.isDel==1,'unpin did not confirm readback')
end
for _,ack in ipairs({{}, {status=200,data={status=1}}, {raise=true}, {status=401},{status=429},{succ=0}}) do
    f=fixture(nil,true,{shelf(),progress(),ack});result=f.run()
    expect(result.kind=='unconfirmed' and result.attempted and f.posts==1 and #f.requests==3 and f.phase=='pending',
        'unknown receipt was accepted or replayed')
end
local unrelated=shelf(1);unrelated.books[2].finishReading=0
f=fixture(nil,true,{shelf(),progress(),{succ=1},unrelated,progress()});result=f.run()
expect(result.kind=='unconfirmed' and f.posts==1 and f.phase=='pending','unrelated change accepted')
f=fixture(nil,true,{shelf(),progress()});f.bad_array=true;result=f.run()
expect(result.kind=='unavailable' and not result.attempted and f.posts==0 and f.claims==0,'invalid empty arrays dispatched')
f=fixture(nil,true,{shelf(),progress()});f.fail_claim=true;result=f.run()
expect(not result.attempted and f.posts==0 and f.phase=='prepared','failed claim dispatched')
f=fixture(nil,true,{shelf(1),progress()});result=f.run()
expect(result.kind=='changed' and not result.attempted and f.posts==0,'changed preview dispatched')
f=fixture(nil,true,{});f.revoked=true;result=f.run();expect(not result.attempted and #f.requests==0,'revoked account dispatched')
print('PASS: cloud pin transport and readback ('..checks..' checks)')
