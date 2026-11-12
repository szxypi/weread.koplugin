package.path='./?.lua;'..package.path
local Task=require('weread.lib.native_position_review_task')
local O=require('weread.lib.native_position_observation')
local Access=require('weread.lib.native_read_access')
local Shelf=require('weread.lib.shelf_flag_change_contract')
local F=require('spec.helpers.thought_edit_fixture')
local Fixture=require('spec.helpers.native_position_review_fixture')
local checks=0;local function expect(v,why) checks=checks+1;assert(v,why) end
local function fixture()
    local f=Fixture.new();f.reads=0
    local point=f.observation.point
    local raw={book={bookId=point.book_id,chapterUid=tonumber(point.chapter_uid),chapterIdx=point.chapter_idx,chapterOffset=point.chapter_offset,
        progress=point.raw_percent,summary=point.summary,readingTime=10,recordReadingTime=20,ttsTime=0}}
    local shelf={books={{bookId='41',secret=0}},archive={}}
    f.observation.shelf_sha256=Shelf.state_hash(shelf)
    f.queue={{bookId='41',version=0},F.clone(raw),F.clone(shelf),{bookId='41',version=0},F.clone(raw),F.clone(shelf)}
    local decode=f.client.json_decode;local response
    function f.client:json_decode(value) if value=='wire' then return F.clone(response) end;return decode(self,value) end
    function f.client:request(options)
        f.reads=f.reads+1
        expect(options.method=='GET' and options.body==nil,'review attempted a write')
        expect(options.skip_cookie and options.persist_response_cookies==false and options.sensitive,'shared Web state leaked')
        expect(options.headers.vid=='900000' and options.headers.accessToken=='synthetic-access' and not options.headers.Cookie)
        response=assert(table.remove(f.queue,1));if f.after then f.after(f.reads) end
        return 'wire',f.status or 200
    end
    function f:run() return Task.run(self.client,self.settings,Access.capture(self.settings,self.credentials),F.clone(self.row),self.journal,self.gate) end
    return f
end
local f=fixture();local out=f:run()
expect(out.kind=='observed' and out.readbacks==2 and f.reads==6 and O.same(out.observation,f.observation))
expect(f.row.phase=='pending' and f.archives==0,'read task changed durable state')
for _i,kind in ipairs({'point','counts','shelf','version'}) do
    f=fixture()
    if kind=='point' then f.queue[5].book.chapterOffset=99
    elseif kind=='counts' then f.queue[5].book.readingTime=11
    elseif kind=='shelf' then f.queue[6].books[1].secret=1
    else f.queue[4].version=2 end
    out=f:run();expect(out.kind=='changed' and not out.observation and f.reads==6,'unstable '..kind..' accepted')
end
f=fixture();f.queue[2].book.chapterOffset=99;f.queue[5].book.chapterOffset=99
f.queue[2].book.readingTime=55;f.queue[5].book.readingTime=55
out=f:run();expect(out.kind=='observed' and out.observation.point.chapter_offset==99 and out.observation.counts.readingTime==55,'new cloud state tied to old expected state')
for _i,when in ipairs({1,2,3,4,5,6}) do
    f=fixture();f.after=function(n) if n==when then f.row.revision=3 end end
    out=f:run();expect(out.kind=='unavailable' and not out.observation and f.reads==when,'stale record continued GETs')
end
f=fixture();f.status=401;out=f:run();expect(out.kind=='login' and f.reads==1 and f.row.phase=='pending','401 renewed or cleared pending')
f=fixture();f.gate_closed=true;out=f:run();expect(f.reads==0 and out.kind=='unavailable')
f=fixture();f.settings:get_auth_scope().epoch=2;out=f:run();expect(out.kind=='observed','same-owner renewed login could not inspect old record')
for _i,mutate in ipairs({function(o) o.point.extra=true end,function(o) o.counts.ttsTime=true end,
    function(o) o.version=-1 end,function(o) o.shelf_sha256='bad' end,function(o) o.extra='private' end}) do
    local value=F.clone(f.observation);mutate(value);expect(not O.valid(value),'invalid observation accepted')
end
f=fixture();out=Task.run(f.client,f.settings,nil,f.row,f.journal,f.gate);expect(out.kind=='unavailable' and f.reads==0)
out=Task.run(f.client,f.settings,{},nil,f.journal,f.gate);expect(out.kind=='unavailable' and f.reads==0)
print('native_position_review_task_spec: '..checks..' checks')
