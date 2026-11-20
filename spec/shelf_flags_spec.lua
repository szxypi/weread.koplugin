package.path='./?.lua;'..package.path
local Flags=require('weread.lib.shelf_flags')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
for name,key in pairs(Flags.FIELDS) do
    for _,value in ipairs({true,false,0,1}) do
        expect(Flags.flag({[key]=value},key).value==(value==true or value==1),'valid binary state lost')
    end
    expect(Flags.flag({},key).reason=='missing' and Flags.display(nil,name)==nil,'missing state became false')
    for _,value in ipairs({2,-1,'true','false','1',{},math.huge}) do
        expect(Flags.flag({[key]=value},key).reason=='invalid','invalid protocol state became boolean')
    end
    expect(Flags.display({[key]='1'},name)==true and Flags.display({[key]='0'},name)==false,'legacy binary display regressed')
end
expect(Flags.project({finishReading=0,finished=1,progress=100}).finished.value==false,'independent metadata or percent marked book finished')
expect(Flags.project({finished=1,progress=100}).finished.reason=='missing','absent reading status guessed from metadata')
expect(Flags.project({secret=1}).pinned.reason=='missing','privacy or server order inferred pinned state')
local books={{bookId='one'},{bookId='two',isTop=false},{bookId='three',isTop=true},{bookId='four',isTop=1}}
local ordered=Flags.pinned_first(books)
expect(ordered[1]==books[3] and ordered[2]==books[4] and ordered[3]==books[1] and ordered[4]==books[2], 'pinned display partition was not stable')
expect(books[1].bookId=='one' and books[3].bookId=='three','pin display reordered original snapshot')
local missing={{bookId='one'},{bookId='two'}}
expect(Flags.pinned_first(missing)==missing,'missing pin flags reordered cloud shelf')
-- The reading filters distinguish an explicit false value from unknown.
for _,module in ipairs({'ui/widget/buttondialog','ui/widget/confirmbox','ui/widget/pathchooser','ui/uimanager',
    'weread.lib.content','weread.lib.scan','weread.lib.logger'}) do package.preload[module]=function() return {} end end
package.preload['weread.lib.plugin_util']=function() return {tr=function(text) return text end} end
local Cache=require('weread.ui.cache')
local host={shelf_filters={reading='unfinished'}}
expect(Cache.bookMatchesFilters(host,{finishReading=false}) and Cache.bookMatchesFilters(host,{finishReading='0'}),'explicit unfinished excluded')
expect(not Cache.bookMatchesFilters(host,{finished=1}) and not Cache.bookMatchesFilters(host,{progress=0}),'unknown status treated as unfinished')
host.shelf_filters.reading='finished'
expect(Cache.bookMatchesFilters(host,{finishReading=true}) and not Cache.bookMatchesFilters(host,{finishReading=0,finished=1,progress=100}),'finished filter used wrong field/type')
print('PASS: shelf binary states and filters ('..checks..' checks)')
