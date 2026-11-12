package.path='./?.lua;'..package.path
local Task=require('weread.lib.native_position_task');local Access=require('weread.lib.native_read_access')
local C=require('weread.lib.native_position_contract');local Shelf=require('weread.lib.shelf_flag_change_contract')
local F=require('spec.helpers.thought_edit_fixture')
local checks=0;local function expect(v,label) checks=checks+1;assert(v,label) end
local before={book_id='41',chapter_uid='2',chapter_idx=3,chapter_offset=12,raw_percent=17,summary='synthetic original full summary'}
local after=F.clone(before);after.chapter_offset=13;after.summary='synthetic desired full summary'
local shelf={books={{bookId='41',secret=0,finishReading=0}},archive={}}
local function progress(p,seconds)
    return {book={bookId=p.book_id,chapterUid=tonumber(p.chapter_uid),chapterIdx=p.chapter_idx,chapterOffset=p.chapter_offset,
        progress=p.raw_percent,summary=p.summary,readingTime=seconds or 10,recordReadingTime=20,ttsTime=0}}
end
local function fixture(reads,ack)
    local f={posts=0,waits=0,current=true,queue={{bookId='41',version=0},progress(before),shelf,{feature={}},ack or {succ=1}}}
    for _i,p in ipairs(reads or {after}) do f.queue[#f.queue+1]=p.book and p or progress(p);f.queue[#f.queue+1]=shelf end
    local settings,access_store,state=F.access();f.state=state
    local grant={vid='900000',deviceId='eink334691225'..string.rep('1',19),accessToken='synthetic-access',refreshToken='synthetic-refresh'}
    function access_store:read() return grant,state.revision,nil,state.pending end
    f.client=F.codec();local response
    local encode,decode=f.client.json_encode,f.client.json_decode;local mt=getmetatable(f.client:json_decode('[]'))
    function f.client:json_encode(value) if type(value)=='table' and next(value)==nil and getmetatable(value)==mt then return '[]' end;return encode(self,value) end
    function f.client:json_decode(value) if value=='wire' then return F.clone(response.data or response) end;return decode(self,value) end
    local metadata={book_id='41',before=before,desired=after,counts={readingTime=10,recordReadingTime=20,ttsTime=0},version=0,
        shelf_sha256=Shelf.state_hash(shelf),source_sha256=string.rep('b',64),file_id='synthetic-file',basis='raw_txt_utf16'}
    f.settings=settings
    f.record={id=string.rep('1',32),epoch=1,account=C.account_key('900000'),revision=1,phase='prepared',metadata=F.clone(metadata)};f.saved=F.clone(f.record)
    f.store={owns=function(_self,record,phase) return not f.revoked and f.saved.id==record.id and C.same(f.saved.metadata,record.metadata) and (not phase or f.saved.phase==phase) end,
        advance=function(_self,record,phase,next_phase)
            if f.fail_claim or next_phase=='acknowledged' and f.fail_ack or f.saved.phase~=phase or record.revision~=f.saved.revision then return nil end
            f.saved.phase,f.saved.revision=next_phase,f.saved.revision+1;return F.clone(f.saved)
        end}
    function f.client:request(options)
        expect(options.skip_cookie and options.persist_response_cookies==false and options.sensitive,'shared Web state')
        expect(options.headers.vid=='900000' and options.headers.accessToken=='synthetic-access' and options.headers.Cookie==nil,'credentials changed')
        if options.method=='POST' then
            f.posts=f.posts+1;expect(f.posts==1 and f.saved.phase=='pending','POST before claim or repeated')
            expect(options.url=='https://i.weread.qq.com/book/read','unexpected write');f.body=decode(self,options.body)
        elseif f.posts>0 and not f.unknown then expect(f.saved.phase=='acknowledged','read preceded durable ACK') end
        response=assert(table.remove(f.queue,1),'missing response')
        if response.cancel then f.current=false end
        if response.raise then error('synthetic lost response',0) end
        return 'wire',response.status or 200
    end
    f.options={is_current=function() return f.current end,now=function() return 1700000000 end,random=function() return 123 end,
        zone='+08:00',sleep=function() f.waits=f.waits+1 end}
    function f.run() return Task.run(f.client,settings,Access.capture(settings,access_store),f.record,f.store,f.options) end
    function f.resolve() return Task.resolve(f.client,settings,Access.capture(settings,access_store),F.clone(f.saved),f.store,f.options) end
    return f
end
local f=fixture();local out=f.run();expect(out.kind=='confirmed' and out.attempted and out.acknowledged and out.readbacks==1)
expect(f.saved.phase=='verified' and f.posts==1 and f.body.hours and next(f.body.hours)==nil)
expect(f.body.summary==after.summary and f.body.readingTime==0 and f.body.isResendReadingInfo==nil)
out=f.run();expect(f.posts==1 and not out.attempted,'old intent replayed')
f=fixture({before,before,after});out=f.run();expect(out.kind=='confirmed' and f.posts==1 and f.waits==2 and out.readbacks==3)
f=fixture({before,before,before,before});out=f.run();expect(out.kind=='unconfirmed' and f.posts==1 and f.waits==3 and f.saved.phase=='acknowledged')
f.queue={{bookId='41',version=0},progress(after),shelf,{bookId='41',version=0},progress(after),shelf};out=f.resolve()
expect(out.kind=='confirmed' and not out.attempted and f.saved.phase=='verified' and f.posts==1,'resolve resent or lost ACK')
f=fixture({before,before,before,before});f.run();f.settings:get_auth_scope().epoch=2
f.queue={{bookId='41',version=0},progress(after),shelf,{bookId='41',version=0},progress(after),shelf};out=f.resolve()
expect(out.kind=='confirmed' and not out.attempted and f.posts==1,'same-owner new login could not read-only resolve')
f=fixture();f.settings:get_auth_scope().epoch=2;out=f.run();expect(not out.attempted and f.posts==0,'old login dispatched')
for _i,ack in ipairs({{}, {succ='1'}, {raise=true}, {status=401}}) do
    f=fixture({after},ack);f.unknown=true;out=f.run()
    expect(out.kind=='unconfirmed' and out.authentication_expired~=true and out.attempted and not out.acknowledged and f.saved.phase=='pending' and f.posts==1 and f.waits==0)
    out=f.resolve();expect(out.kind=='unconfirmed' and not out.attempted and f.posts==1)
end
for _i,change in ipairs({{summary='unexpected'},{chapterOffset=99},{readingTime=11}}) do
    local raw=progress(after);for key,v in pairs(change) do raw.book[key]=v end
    f=fixture({raw});out=f.run();expect(out.kind=='unconfirmed' and f.posts==1 and f.waits==0 and f.saved.phase=='acknowledged')
end
f=fixture();f.fail_claim=true;out=f.run();expect(not out.attempted and f.posts==0 and f.saved.phase=='prepared')
f=fixture();f.fail_ack=true;out=f.run();expect(out.attempted and out.kind=='unconfirmed' and f.posts==1 and f.saved.phase=='pending')
f=fixture();f.queue[1]={status=401};out=f.run();expect(out.kind=='login' and out.authentication_expired==true and not out.attempted and f.posts==0)
f=fixture();f.queue[4]={feature={},cancel=true};out=f.run();expect(out.kind=='unavailable' and not out.attempted and f.posts==0)
f=fixture();f.queue[5]={succ=1,cancel=true};out=f.run();expect(out.kind=='unconfirmed' and f.posts==1 and f.saved.phase=='pending')
f=fixture();f.options.is_current=nil;out=f.run();expect(not out.attempted and f.posts==0 and #f.queue==7)
print('PASS native_position_task_spec '..checks)
