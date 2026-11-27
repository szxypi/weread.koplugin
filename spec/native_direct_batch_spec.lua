package.path='./?.lua;'..package.path
local rows,usable,room,failed,downloads,live,progress,cache_selection
package.preload['weread.lib.native_direct_cache']=function() return {
    list=function(_,_,_,_,selection) cache_selection=selection;return rows end,
    open=function(_,_,_,entry) return usable[entry.chapter_uid] and {missing_images=entry.missing_images} end,
    remaining=function() return room end,
} end
package.preload['weread.lib.native_direct_path']=function() return {contains=function(_,path) return path=='/valid' end} end
package.preload['weread.lib.native_position_protocol']=function() return {integer=function(n,a,b)
    return type(n)=='number' and n%1==0 and n>=a and n<=b end} end
package.preload['weread.lib.native_direct_reader']=function() return {build=function(_,_,book,chapter,expected,options)
    assert(options.is_current() and options.allow_missing_images and book.book_id=='42')
    assert(expected.reading_catalog_sha256=='digest' and expected.access_fingerprint=='fingerprint')
    downloads[#downloads+1]=chapter.chapterUid
    if failed==chapter.chapterUid then return nil,'rate_limited' end
    return {path='/valid',book_version=1,missing_images=chapter.chapterUid=='3' and 1 or 0}
end} end
local Batch=require('weread.lib.native_direct_batch')
local book={book_id='42'};local selected={scope={vid='123'},fingerprint='fingerprint'}
local catalog={book_id='42',version=1,reading_digest='digest',chapters={
    {chapterUid='1',downloadable=true,catalog_next='2'},
    {chapterUid='2',downloadable=false,catalog_prev='1',catalog_next='3'},
    {chapterUid='3',downloadable=true,catalog_prev='2'},
}}
local function setup()
    rows={{chapter_uid='1',book_version=1,catalog_sha256='digest',catalog_order=1,catalog_count=3,
        catalog_next='2',missing_images=0}}
    usable={['1']=true};room=1;failed=nil;downloads={};live=true;progress={};cache_selection=nil
end
local function run(range)
    return Batch.run({}, {},book,catalog,selected,function() return live end,function(value) progress[#progress+1]=value end,range)
end
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
setup();local result=run()
expect(result.ok and result.saved==1 and result.downloaded==1 and result.unavailable==1 and result.missing==1,
    'batch did not distinguish verified, downloaded and unavailable chapters')
expect(#downloads==1 and downloads[1]=='3' and #progress==3 and progress[3]==99 and cache_selection==nil,
    'full batch limited its lookup or downloaded a locked or cached chapter')
setup();usable['1']=false;result=run()
expect(result.ok and result.downloaded==2 and downloads[1]=='1','damaged copy was treated as usable')
setup();rows[1].catalog_sha256='old';result=run()
expect(result.ok and result.downloaded==2,'different catalog was treated as current')
setup();failed='3';result=run()
expect(not result.ok and result.error=='rate_limited' and result.saved==1 and #downloads==1,'failure did not stop batch')
setup();room=0;result=run()
expect(not result.ok and result.error=='storage' and #downloads==0,'full cache did not stop before download')
setup();live=false;result=run();expect(result.error=='invalid' and #downloads==0,'stale account started a batch')
setup();result=run({first=2,last=3})
expect(result.ok and result.downloaded==1 and result.saved==0 and result.unavailable==1
    and #downloads==1 and downloads[1]=='3' and progress[1]==50 and progress[2]==99 and cache_selection=='3',
    'range with one readable chapter did not use its targeted lookup')
setup();result=run({first=1,last=3})
expect(result.ok and result.saved==1 and result.downloaded==1 and type(cache_selection)=='table'
    and cache_selection['1'] and cache_selection['3'] and not cache_selection['2'],
    'range with multiple readable chapters searched the wrong cache entries')
setup();rows[2]={chapter_uid='3',book_version=1,catalog_sha256='digest',catalog_order=3,catalog_count=3,
    catalog_prev='2',missing_images=1};usable['3']=true
result=run({first=3,last=3})
expect(result.ok and result.saved==1 and result.missing==1 and #downloads==0 and #progress==1 and progress[1]==99,
    'range did not verify the cached chapter against its full catalog position')
for _,range in ipairs({{},false,{first=3,last=2},{first=0,last=3},{first=1,last=4},{first=1.5,last=3}}) do
    setup();result=run(range);expect(result.error=='invalid' and #downloads==0 and #progress==0,'invalid range started a batch')
end
print('PASS: native chapter batch preserves completed chapters and skips inaccessible ones ('..checks..' checks)')
