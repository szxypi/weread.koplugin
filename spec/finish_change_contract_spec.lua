package.path='./?.lua;'..package.path
local C=require('weread.lib.finish_change_contract');local F=require('spec.helpers.thought_edit_fixture')
local checks=0;local function expect(v,label) checks=checks+1;assert(v,label) end
local function shelf(finished) return {books={{bookId='41',finishReading=finished,secret=0},{bookId='42',finishReading=1,secret=0}}} end
local function position(offset) return {book={bookId='41',chapterUid=2,chapterIdx=2,chapterOffset=offset or 100,progress=37.5}} end
for _i,before in ipairs({0,1}) do
    local source=shelf(before);local desired=before==0;local plan=C.make(source,position(),'41',desired)
    expect(plan.body.bookId=='41' and plan.body.isCancel==before and plan.body.auto==0 and plan.body.finishInfo==0 and plan.body.status==4,'unverified request body')
    expect(not C.check(source,position(),plan.metadata),'old state confirmed')
    source.books[1].finishReading=1-before;expect(C.check(source,position(),plan.metadata),'exact target state rejected')
end
local original=shelf(0);local plan=C.make(original,position(),'41',true)
for _i,kind in ipairs({'member','other_finished','private','pinned','target_private','position'}) do
    local source=F.clone(original);source.books[1].finishReading=1;local progress=position()
    if kind=='member' then source.books[2]=nil
    elseif kind=='other_finished' then source.books[2].finishReading=0
    elseif kind=='private' then source.books[2].secret=1
    elseif kind=='pinned' then source.books[2].isTop=1
    elseif kind=='target_private' then source.books[1].secret=1
    else progress=position(101) end
    expect(not C.check(source,progress,plan.metadata),'unrelated change accepted: '..kind)
end
for _i,value in ipairs({'0','1',2,{}}) do expect(not pcall(C.make,shelf(value),position(),'41',true),'unknown flag guessed') end
for _i,id in ipairs({'0','CB_1','41/other',string.rep('1',21)}) do expect(not pcall(C.request,id,true),'unsupported target accepted') end
expect(not pcall(C.request,'41',1),'numeric confirmation accepted')
local duplicate=shelf(0);duplicate.books[2].bookId='41';expect(not pcall(C.flags,duplicate),'duplicate identity accepted')
local invalid=shelf(0);invalid.books[1].bookId=true;expect(not pcall(C.flags,invalid),'boolean identity accepted')
local foreign=position();foreign.book.bookId='42';expect(not pcall(C.make,shelf(0),foreign,'41',true),'foreign position accepted')
local changed=shelf(0);changed.books[2].isTop='0'
expect(C.flags_hash(C.flags(changed))~=C.flags_hash(C.flags(original)),'invalid and missing pinned flags collapsed')
expect(not pcall(C.make,changed,position(),'41',true),'malformed unrelated flag allowed preparation')
local expected={before_hash='def439a3839fd4230e5000a8ce8f9b8523ade2f5e603b694d35caf54915583b7',
    after_hash='f00bc9facf3147bcdc5e6c95c5488605b4ab5f05e49b5b1ee69202395a58f190',
    position_hash='0bd046e3f1e18f7ecf10f5b79e291c3f793fbedc244f96146d50873ab1596e52',
    request_hash='17ede1a783edb79b342cba8d41838f31afff55a22e7934f574a389d8ebb47c9b'}
-- Exact cross-language vectors from the independent Python model.
for _i,key in ipairs({'before_hash','after_hash','position_hash','request_hash'}) do
    expect(plan.metadata[key]==expected[key],'Python/Lua hash differs: '..key)
end
for _i,bad in ipairs({{errcode=1},{errCode=false},{succ=0}}) do
    local source=shelf(0);for k,v in pairs(bad) do source[k]=v end
    expect(not pcall(C.flags,source),'rejected response accepted')
end
print('PASS: single finished-mark planning ('..checks..' checks)')
