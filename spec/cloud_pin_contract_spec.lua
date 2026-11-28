package.path='./?.lua;'..package.path
local C=require('weread.lib.shelf_flag_change_contract');local F=require('spec.helpers.thought_edit_fixture')
local checks=0;local function expect(value,label) checks=checks+1;assert(value,label) end
local function shelf() return {books={{bookId='41',secret=0,finishReading=0},{bookId='42',secret=1,finishReading=1}},
    archive={{archiveId='group',name='Synthetic',bookIds={'41','42'}}}} end
local function position() return {book={bookId='41',chapterUid=2,chapterIdx=2,chapterOffset=20,progress=12.5}} end
local before=shelf();local plan=C.make_pin(before,position(),'41',true)
expect(plan.metadata.before=='missing' and plan.metadata.kind=='pinned' and C.valid_metadata(plan.metadata),'missing baseline lost')
expect(plan.body.isDel==0 and #plan.body.bookIds==1 and plan.body.bookIds[1]=='41'
    and #plan.body.albumIds==0 and #plan.body.archiveIds==0,'incorrect pin request')
expect(not C.check(before,position(),plan.metadata),'missing pin was treated as positive')
local pinned=shelf();pinned.books[1].isTop=1
expect(C.check(pinned,position(),plan.metadata),'explicit pin rejected')
local unpin=C.make_pin(pinned,position(),'41',false)
expect(unpin.metadata.before==true and unpin.body.isDel==1,'incorrect unpin request')
expect(C.check(before,position(),unpin.metadata),'observed missing marker after unpin rejected')
local explicit_false=shelf();explicit_false.books[1].isTop=0
expect(C.check(explicit_false,position(),unpin.metadata),'explicit false after unpin rejected')
expect(not pcall(C.make_pin,before,position(),'41',false),'unknown baseline guessed unpinned')
expect(not pcall(C.make_pin,explicit_false,position(),'41',false),'unpin from false accepted')
for _,kind in ipairs({'other_pin','private','finished','group','position','missing_target','invalid'}) do
    local value=F.clone(pinned);local point=position()
    if kind=='other_pin' then value.books[2].isTop=1
    elseif kind=='private' then value.books[1].secret=1
    elseif kind=='finished' then value.books[1].finishReading=1
    elseif kind=='group' then value.archive[1].bookIds[2]=nil
    elseif kind=='position' then point.book.chapterOffset=21
    elseif kind=='missing_target' then table.remove(value.books,1)
    else value.books[2].isTop='1' end
    expect(not C.check(value,point,plan.metadata),'unrelated change accepted: '..kind)
end
local bad=F.clone(plan.metadata);bad.kind='private';expect(not C.valid_metadata(bad),'pin record confused with private')
bad=F.clone(plan.metadata);bad.desired=false;expect(not C.valid_metadata(bad),'altered direction accepted')
bad=F.clone(plan.metadata);bad.alternate_hash=nil;expect(not C.valid_metadata(bad),'missing alternate hash accepted')
bad=F.clone(plan.metadata);bad.alternate_hash=string.rep('a',64);expect(not C.valid_metadata(bad),'pin accepted arbitrary alternate state')
expect(not pcall(C.make_pin,before,position(),'41',1),'invalid desired value accepted')
local imported={books={{bookId='CB_abc',secret=0,finishReading=0},{bookId='42',secret=1,finishReading=1}},
    archive={{archiveId='group',name='Synthetic',bookIds={'CB_abc','42'}}}}
local imported_point={timestamp=12,readingTime=14,recordReadingTime=3,ttsTime=0,
    book={bookId='CB_abc',chapterUid=2,chapterIdx=2,chapterOffset=20,progress=12.5,
        isStartReading=1,startReadingTime=123,summary='Synthetic',updateTime=10}}
local imported_plan=C.make_pin(imported,imported_point,'CB_abc',true)
expect(C.valid_metadata(imported_plan.metadata) and imported_plan.body.bookIds[1]=='CB_abc','imported pin plan rejected')
local imported_pinned=F.clone(imported);imported_pinned.books[1].isTop=1
expect(C.check(imported_pinned,imported_point,imported_plan.metadata),'imported pin readback rejected')
for _,field in ipairs({'readingTime','recordReadingTime','ttsTime'}) do
    local changed=F.clone(imported_point);changed[field]=changed[field]+1
    expect(not C.check(imported_pinned,changed,imported_plan.metadata),'changed imported counter accepted: '..field)
end
for _,field in ipairs({'summary','isStartReading','startReadingTime','readUpdateTime'}) do
    local changed=F.clone(imported_point);changed.book[field]=field=='summary' and 'Other' or 999
    expect(not C.check(imported_pinned,changed,imported_plan.metadata),'changed imported field accepted: '..field)
end
local volatile=F.clone(imported_point);volatile.timestamp=20;volatile.book.updateTime=20
expect(C.check(imported_pinned,volatile,imported_plan.metadata),'server clock or update time blocked imported pin')
local imported_restore=C.make_pin(imported_pinned,imported_point,'CB_abc',false)
expect(C.check(imported,imported_point,imported_restore.metadata),'imported restore missing marker rejected')
expect(not pcall(C.make,imported,imported_point,'CB_abc',true),'imported private-writing guard weakened')
for _,id in ipairs({'CB_','CB_a/b','MP_WXS_1','CB_abc?x=1',string.rep('1',21)}) do
    expect(not C.pin_id(id) and not pcall(C.pin_request,id,true),'invalid imported identity accepted')
end
print('PASS: cloud pin contract ('..checks..' checks)')
