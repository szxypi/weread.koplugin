package.path='./?.lua;'..package.path
local rows,usable,room,failed,downloads,live,progress,cache_selection
local capacity_mode,reserved,acquires,scans,releases
local opened_copies
local repair_attempts,repair_results,published
package.preload['weread.lib.native_direct_cache']=function() return {
    list=function(_,_,_,_,selection) cache_selection=selection;return rows end,
    open=function(_,_,_,entry)
        opened_copies[#opened_copies+1]=entry.missing_images
        return usable[entry.chapter_uid] and not entry.damaged and {missing_images=entry.missing_images}
    end,
    begin_capacity=function()
        acquires=acquires+1
        if capacity_mode~='ready' then return nil,capacity_mode end
        scans=scans+1
        reserved={room=room,lease={release=function() releases=releases+1 end}}
        return reserved
    end,
    remaining=function(_,_,_,_,capacity)
        if capacity then assert(capacity==reserved);return capacity.room end
        scans=scans+1;return room
    end,
    publish=function(_,account,_,chapter,prepared,current,capacity)
        assert(account=='123' and current() and capacity==reserved)
        published[#published+1]=chapter.chapterUid
        return {missing_images=prepared.missing_images}
    end,
} end
package.preload['weread.lib.native_direct_image_refresh']=function() return {
    prepare=function(_,_,_,entry,current)
        assert(current());repair_attempts[#repair_attempts+1]=entry.chapter_uid
        local value=repair_results[entry.chapter_uid]
        if type(value)=='number' then return {missing_images=value} end
        return nil,value
    end,
} end
package.preload['weread.lib.native_direct_path']=function() return {contains=function(_,path) return path=='/valid' end} end
package.preload['weread.lib.native_position_protocol']=function() return {integer=function(n,a,b)
    return type(n)=='number' and n%1==0 and n>=a and n<=b end} end
package.preload['weread.lib.native_direct_reader']=function() return {build=function(_,_,book,chapter,expected,options)
    assert(options.is_current() and options.allow_missing_images and book.book_id=='42')
    assert(expected.reading_catalog_sha256=='digest' and expected.access_fingerprint=='fingerprint')
    downloads[#downloads+1]=chapter.chapterUid
    if failed==chapter.chapterUid then return nil,'rate_limited' end
    if options.capacity then
        assert(options.capacity==reserved and reserved.room>0)
        reserved.room=reserved.room-1
    end
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
    opened_copies={}
    repair_attempts,repair_results,published={},{},{}
    capacity_mode,reserved,acquires,scans,releases='absent',nil,0,0,0
end
local function run(range,on_progress)
    return Batch.run({}, {},book,catalog,selected,function() return live end,function(value)
        progress[#progress+1]=value
        if on_progress then on_progress() end
    end,range)
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
setup();rows[1].missing_images=2
local complete={chapter_uid='1',book_version=1,catalog_sha256='digest',catalog_order=1,catalog_count=3,
    catalog_next='2',missing_images=0}
rows[2]=complete
result=run({first=1,last=1})
expect(result.ok and result.saved==1 and result.missing==0 and #downloads==0
    and #opened_copies==1 and opened_copies[1]==0,'batch preferred a copy with missing images over a complete copy')
complete.damaged=true;opened_copies={}
result=run({first=1,last=1})
expect(result.ok and result.saved==1 and result.missing==1 and #downloads==0
    and #opened_copies==2 and opened_copies[1]==0 and opened_copies[2]==2,'invalid complete copy prevented fallback')
complete.damaged=false;complete.catalog_next='3';opened_copies={}
result=run({first=1,last=1})
expect(result.ok and result.saved==1 and result.missing==1 and #downloads==0
    and #opened_copies==1 and opened_copies[1]==2,'wrong catalog position passed cache matching')
setup();capacity_mode='ready';room=2;usable={};result=run()
expect(result.ok and result.downloaded==2 and acquires==1 and scans==1 and releases==1,
    'batch did not reuse and release its capacity reservation')
setup();capacity_mode='ready';usable={};result=run()
expect(not result.ok and result.error=='storage' and result.downloaded==1 and #downloads==1 and releases==1,
    'full reservation allowed another download or was not released')
setup();capacity_mode='ready';failed='3';result=run()
expect(result.error=='rate_limited' and releases==1,'failed download kept the reservation')
setup();capacity_mode='ready';usable={};result=run(nil,function() live=false end)
expect(result.error=='session_changed' and #downloads==1 and releases==1,'session change kept the reservation')
setup();capacity_mode='ready';usable={}
local ok=pcall(run,nil,function() error('synthetic callback error') end)
expect(not ok and releases==1,'unexpected callback failure kept the reservation')
setup();capacity_mode='unsupported';usable={};result=run()
expect(result.ok and result.downloaded==2 and acquires==1 and scans==2 and releases==0,
    'unsupported leases did not fall back to fresh capacity checks')
for _,range in ipairs({{},false,{first=3,last=2},{first=0,last=3},{first=1,last=4},{first=1.5,last=3}}) do
    setup();result=run(range);expect(result.error=='invalid' and #downloads==0 and #progress==0,'invalid range started a batch')
end
local function repair_fixture()
    setup();capacity_mode='ready';rows[1].missing_images=2
    rows[2]={chapter_uid='3',book_version=1,catalog_sha256='digest',catalog_order=3,catalog_count=3,
        catalog_prev='2',missing_images=2}
    usable['3']=true;repair_results['1']=0;repair_results['3']=1
end
local function repair(on_progress)
    return Batch.repair({}, {},book,catalog,selected,function() return live end,function(value)
        progress[#progress+1]=value
        if on_progress then on_progress() end
    end)
end
repair_fixture();result=repair()
expect(result.ok and result.improved==2 and result.remaining==1 and result.unverified==0
    and table.concat(published,',')=='1,3' and progress[2]==99 and acquires==1 and releases==1,
    'image repair lost chapter order, partial improvement or the shared reservation')
repair_fixture();complete.catalog_next='2';rows[3]=complete;repair_results['3']='unchanged'
result=repair()
expect(result.ok and result.improved==0 and result.remaining==1 and #published==0 and acquires==0
    and table.concat(repair_attempts,',')=='3','repair refetched a complete chapter or saved an unimproved copy')
repair_fixture();rows[1].damaged=true;rows[2].catalog_sha256='obsolete';result=repair()
expect(result.ok and result.unverified==1 and #repair_attempts==0 and #published==0,
    'repair attempted a damaged or obsolete chapter')
repair_fixture();repair_results['3']='rate_limited';result=repair()
expect(result.error=='rate_limited' and table.concat(published,',')=='1' and releases==1,
    'rate limit lost completed image recovery or held the reservation')
repair_fixture();result=repair(function() live=false end)
expect(result.error=='session_changed' and table.concat(repair_attempts,',')=='1' and releases==1,
    'cancelled repair attempted a second chapter or held the reservation')
print('PASS: native chapter batch preserves completed chapters and skips inaccessible ones ('..checks..' checks)')
