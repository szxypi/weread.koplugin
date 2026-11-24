package.path='./?.lua;'..package.path
local C=require('weread.lib.reading_state_change_contract')
local F=require('spec.helpers.thought_edit_fixture')
local function shelf(id)
    return {books={{bookId=id,title='Test',finishReading=0,secret=0},{bookId='42',finishReading=1,secret=0}},
        archive={{archiveId=7,name='Test group',bookIds={id},albumIds={}}}}
end
local function reading(id,flag,uid)
    return {book={bookId=id,isStartReading=flag,startReadingTime=flag==1 and 42 or 0,
        chapterUid=uid or 0,chapterIdx=uid and 1 or 0,chapterOffset=uid and 20 or 0,progress=uid and 12.5 or 0,
        summary=uid and 'test' or '',readingTime=4,recordReadingTime=0,ttsTime=0}}
end
for _,id in ipairs({'41','CB_abc'}) do
    for _,uid in ipairs({0,8}) do
        local raw=reading(id,0,uid~=0 and uid or nil)
        local plan=C.make(shelf(id),raw,id,'900000',true)
        assert(plan.body.bookId==id and plan.body.status==2 and plan.body.isCancel==0 and C.valid_metadata(plan.metadata))
        assert(C.unchanged(shelf(id),raw,plan.metadata,'900000'))
        assert(not C.check(shelf(id),raw,plan.metadata,'900000'))
        local changed=F.clone(raw);changed.book.isStartReading=1;changed.book.startReadingTime=123
        assert(C.check(shelf(id),changed,plan.metadata,'900000'))
        assert(not C.unchanged(shelf(id),changed,plan.metadata,'900000'))
        local restore=C.make(shelf(id),changed,id,'900000',false)
        assert(restore.body.status==2 and restore.body.isCancel==1 and C.check(shelf(id),raw,restore.metadata,'900000'))
        assert(C.same(plan.metadata,F.clone(plan.metadata)))
    end
end
local id='41';local original=shelf(id);local raw=reading(id,0,8);local plan=C.make(original,raw,id,'900000',true)
for _,kind in ipairs({'member','group','other_flag','position','counter','summary','presence','foreign'}) do
    local changed_shelf,changed=F.clone(original),F.clone(raw);changed.book.isStartReading=1
    if kind=='member' then changed_shelf.books[2]=nil
    elseif kind=='group' then changed_shelf.archive[1].bookIds={}
    elseif kind=='other_flag' then changed_shelf.books[2].secret=1
    elseif kind=='position' then changed.book.chapterOffset=21
    elseif kind=='counter' then changed.book.readingTime=5
    elseif kind=='summary' then changed.book.summary='other'
    elseif kind=='presence' then changed.book.chapterIdx=nil
    else changed.book.bookId='43' end
    local ok,value=pcall(C.check,changed_shelf,changed,plan.metadata,'900000')
    assert(not ok or not value,'accepted changed '..kind)
end
for _,bad in ipairs({true,'1',-1,math.huge}) do
    local changed=F.clone(raw);changed.book.readingTime=bad
    assert(not pcall(C.make,original,changed,id,'900000',true),'accepted invalid counter')
end
local missing=F.clone(raw);missing.book.isStartReading=nil
assert(not pcall(C.make,original,missing,id,'900000',true),'missing state became false')
missing=F.clone(raw);missing.book.startReadingTime=nil
assert(not pcall(C.make,original,missing,id,'900000',true),'missing start time accepted')
local stale=reading(id,1,8);local stale_plan=C.make(original,stale,id,'900000',false)
stale.book.startReadingTime=stale.book.startReadingTime+1
assert(not C.unchanged(original,stale,stale_plan.metadata,'900000'),'changed start time retained old preview')
local contradictory=F.clone(raw);contradictory.book.startReadingTime=1
assert(not pcall(C.make,original,contradictory,id,'900000',true),'contradictory start state accepted')
local zero=reading(id,0);zero.book.chapterOffset=1
assert(not pcall(C.make,original,zero,id,'900000',true),'contradictory zero chapter accepted')
local foreign=F.clone(raw);foreign.book.bookId='42'
assert(not pcall(C.make,original,foreign,id,'900000',true),'foreign progress accepted')
local removed=F.clone(original);removed.books[1]=nil
assert(not pcall(C.make,removed,raw,id,'900000',true),'missing target accepted')
local bad=F.clone(plan.metadata);bad.request_hash=string.rep('a',64)
assert(not C.valid_metadata(bad),'unbound request accepted')
for _,bad_id in ipairs({'0','CB_','MP_test','41/x',string.rep('1',21)}) do
    assert(not pcall(C.request,bad_id,true),'invalid target accepted')
end
print('PASS: start-status change planning and independent readback')
