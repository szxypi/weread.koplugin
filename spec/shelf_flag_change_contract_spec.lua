package.path='./?.lua;'..package.path
local C=require('weread.lib.shelf_flag_change_contract');local F=require('spec.helpers.thought_edit_fixture')
local checks=0;local function expect(v,label) checks=checks+1;assert(v,label) end
local function shelf() return {books={{bookId='41',secret=0,finishReading=0},{bookId='42',secret=1,finishReading=1}},
    archive={{archiveId='group',name='Synthetic',bookIds={'41','42'}}}} end
local function position() return {book={bookId='41',chapterUid=2,chapterIdx=2,chapterOffset=20,progress=12.5}} end
local original=shelf();local plan=C.make(original,position(),'41',true)
local expected={before_hash='4191d5f266995c00b9e6efe5b33d3b52af7caf1ae4d58fda362426c0758e2872',
    after_hash='b535d22b07eada0beda726de047779cebd9f1d3d433a7c5b83a8f9b776a0bb34',
    position_hash='66b6ab05ecac8a6a6b2c621b9bc5da9ec4fc87ad24baa8f2b1c2646c8ad0f595',
    request_hash='208a2497d57a851388b226a8566d5a6b92a21de9e2d997930dcdfe139eb4f952'}
for key,value in pairs(expected) do expect(plan.metadata[key]==value,'Python/Lua vector differs: '..key) end
expect(plan.body.private==1 and #plan.body.bookIds==1 and plan.body.bookIds[1]=='41' and plan.body.albumIds==nil,'wrong request')
expect(not C.check(original,position(),plan.metadata),'original state accepted as changed')
local changed=shelf();changed.books[1].secret=1
expect(C.check(changed,position(),plan.metadata),'desired state rejected')
local restore=C.make(changed,position(),'41',false)
expect(restore.body.private==0 and C.check(original,position(),restore.metadata),'separate restoration differs')
for _i,kind in ipairs({'member','finished','other_private','pin','group_name','group_member','group_pin','offset','percent'}) do
    local value=F.clone(changed);local point=position()
    if kind=='member' then value.books[2]=nil
    elseif kind=='finished' then value.books[1].finishReading=1
    elseif kind=='other_private' then value.books[2].secret=0
    elseif kind=='pin' then value.books[2].isTop=1
    elseif kind=='group_name' then value.archive[1].name='Changed'
    elseif kind=='group_member' then value.archive[1].bookIds[2]=nil
    elseif kind=='group_pin' then value.archive[1].isTop=1
    elseif kind=='offset' then point.book.chapterOffset=21 else point.book.progress=12.50001 end
    expect(not C.check(value,point,plan.metadata),'unrelated change accepted: '..kind)
end
local reordered=shelf();reordered.books={reordered.books[2],reordered.books[1]};reordered.archive[1].bookIds={'42','41'}
expect(C.state_hash(reordered)==C.state_hash(original),'ordering changed meaning')
for _i,kind in ipairs({'missing','string','invalid','other_invalid','group_invalid','group_duplicate','position'}) do
    local value=shelf();local point=position()
    if kind=='missing' then value.books[1].secret=nil
    elseif kind=='string' then value.books[1].secret='0'
    elseif kind=='invalid' then value.books[1].secret=2
    elseif kind=='other_invalid' then value.books[2].isTop='0'
    elseif kind=='group_invalid' then value.archive[1].isTop='0'
    elseif kind=='group_duplicate' then value.archive[2]=F.clone(value.archive[1])
    else point.book.bookId='42' end
    expect(not pcall(C.make,value,point,'41',true),'malformed/unknown state guessed: '..kind)
end
for _i,id in ipairs({'0','CB_1','41/other',string.rep('1',21)}) do expect(not pcall(C.request,id,true),'invalid target') end
expect(not pcall(C.request,'41',1),'numeric desired state')
local zero={book={bookId='41',chapterUid=0,chapterIdx=0,chapterOffset=0,progress=0}}
expect(C.make(original,zero,'41',true),'exact unstarted position rejected')
zero.book.chapterOffset=1;expect(not pcall(C.make,original,zero,'41',true),'nonzero unstarted position')
local bad=F.clone(plan.metadata);bad.kind='pinned';expect(not C.valid_metadata(bad),'unverified pin writer accepted')
bad=F.clone(plan.metadata);bad.extra=true;expect(not C.valid_metadata(bad),'metadata widened')
bad=F.clone(plan.metadata);bad.desired=false;expect(not C.valid_metadata(bad),'request binding lost')
print('PASS: private-reading full-state contract ('..checks..' checks)')
