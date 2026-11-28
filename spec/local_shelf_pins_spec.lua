package.path='./?.lua;'..package.path
local Pins=require('weread.lib.local_shelf_pins')
local Flags=require('weread.lib.shelf_flags')
local n=0
local function expect(value,label) n=n+1;assert(value,label) end
local one,two,three={bookId='101'},{bookId='102'},{bookId='103',isTop=1}
local empty=Pins.empty();expect(Pins.valid(empty),'empty state invalid')
local pinned=assert(Pins.toggle(empty,two));expect(#empty.books==0 and Pins.contains(pinned,two),'pin mutated original or was lost')
expect(not Pins.contains(pinned,one) and Pins.index(pinned)['102']==true,'pin index wrong')
expect(Pins.same(pinned,{version=1,books={'102'}}) and not Pins.same(empty,pinned)
    and not Pins.same(pinned,{version=1,books={'102','102'}}),'pin snapshot comparison failed')
local sorted=Flags.pinned_first({one,two,three},Pins.index(pinned))
expect(sorted[1]==two and sorted[2]==three and sorted[3]==one,'local and cloud pins are not stable')
expect(one.isTop==nil and two.isTop==nil and three.isTop==1,'local pin changed cloud state')
local removed=assert(Pins.toggle(pinned,two));expect(#removed.books==0 and Pins.contains(pinned,two),'unpin mutated original')
expect(not Pins.toggle(empty,{bookId='101',book_id='102'}),'conflicting identity accepted')
for _,bad in ipairs({{version=1,books={'101','101'}},{version=1,books={[2]='102'}},
    {version=1,books={'101'},unexpected=true},{version=2,books={}}, {version=1,books={'0'}}}) do
    expect(not Pins.valid(bad),'invalid saved state accepted')
end
local max=Pins.empty();for i=1,5000 do max.books[i]=tostring(i) end
expect(Pins.valid(max) and not Pins.toggle(max,{bookId='5001'}),'pin limit not enforced')
expect(Pins.toggle(max,{bookId='1'}) and #Pins.toggle(max,{bookId='1'}).books==4999,'unpin at limit failed')
print('PASS: local shelf pin model ('..n..' checks)')
