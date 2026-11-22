package.path='./?.lua;'..package.path
local n=0;local function expect(value,message) n=n+1;assert(value,message) end
local live=true;local mode;local reads,shelves,checks=0,0,0
local entry={book_id='42',chapter_uid='37',chapter_idx=2,book_version=7,
    source_sha256=string.rep('a',64),file_id=string.rep('b',64)}
local native={scope={vid='123'},credentials={vid='123'}};local web={}
local function point()
    return {bookId='42',chapterUid=37,chapterIdx=2,chapterOffset=20,progress=25,
        summary='existing summary',readingTime=10,recordReadingTime=5,ttsTime=0}
end
package.preload['weread.lib.native_read_access']=function() return {matches=function() return live end} end
package.preload['weread.lib.source_currentness']=function() return {matches=function() return live end} end
package.preload['weread.lib.shelf_flag_change_contract']=function() return {state_hash=function(s) return s.hash end} end
package.preload['weread.lib.native_authorization']=function() return {new=function(_,_,options) return {
    _request=function(_,stage)
        assert(options.is_current())
        if stage=='position_metadata' then return {bookId='42',version=mode=='version' and 8 or 7} end
        assert(stage=='position_progress');reads=reads+1;local p=point()
        if mode=='initial' or mode=='initial_counts' then
            p.chapterUid,p.chapterIdx,p.chapterOffset,p.progress,p.summary=0,0,0,0,''
            p.readingTime,p.recordReadingTime,p.ttsTime=mode=='initial_counts' and 1 or 0,0,0
        end
        if mode=='missing_summary' then p.summary=nil end
        if mode=='changed' and reads==2 then p.chapterOffset=21 end
        if mode=='counts' and reads==2 then p.readingTime=11 end
        return p
    end,
    read_shelf=function() shelves=shelves+1;return {hash=string.rep(mode=='shelf' and shelves==2 and 'd' or 'c',64)} end,
    cancel=function() end,
} end} end
package.preload['weread.lib.native_direct_position']=function() return {prepare=function(_,_,e,file,context,ns,ws,active,_,options)
    assert(e==entry and file=='/native' and context=='context' and ns==native and ws==web and active() and options.prepare_summary)
    if mode=='source' then return nil,'source_changed' end
    local p=point();p.summary=nil
    if mode=='initial' then p.chapterUid,p.chapterIdx,p.chapterOffset,p.progress=0,0,0,0 end
    if mode=='web' then p.chapterOffset=99 end
    for _i=1,mode=='one_web' and 1 or 2 do
        checks=checks+1;if not options.verify_progress(p) then return nil,'cloud_changed' end
    end
    return {chapter_offset=30},nil,nil,'new source summary'
end} end
local Preview=require('weread.lib.native_direct_upload_preview')
local function prepare(which)
    mode=which;reads,shelves,checks=0,0,0
    return Preview.prepare({}, {},entry,'/native','context',native,web,function() return live end)
end
local value=prepare();local why
expect(value and value.desired.chapter_offset==30 and value.desired.raw_percent==25 and value.desired.summary=='new source summary'
    and value.basis=='filtered_xhtml_utf16' and value.dispatch_authorized==false and reads==2 and checks==2 and shelves==2,
    'verified preview was not bound to both sources and stable cloud state')
local bound={};for key,item in pairs(value) do if key~='position' and key~='dispatch_authorized' then bound[key]=item end end
bound.book_id=entry.book_id
local Contract=require('weread.lib.native_position_contract')
expect(not Contract.valid(bound),'read-only XHTML preview was accepted as a dispatch grant')
bound.basis='raw_txt_utf16';expect(Contract.valid(bound),'dispatch test fixture was invalid independently of its basis')
value=prepare('initial');expect(value and value.before.kind=='no_chapter' and value.desired.raw_percent==0,
    'explicit empty cloud position with zero counters was rejected')
for _,case in ipairs({{'missing_summary','baseline_unavailable'},{'changed','cloud_changed'},{'counts','cloud_changed'},
    {'initial_counts','baseline_unavailable'},
    {'shelf','cloud_changed'},{'version','source_changed'},{'source','source_changed'},{'web','cloud_changed'},
    {'one_web','cloud_changed'}}) do
    value,why=prepare(case[1]);expect(not value and why==case[2],'invalid preview accepted: '..case[1])
end
live=false;value,why=prepare();expect(not value and why=='invalid' and reads==0,'stale account reached the network')
print('PASS: native direct upload preview is source-bound and read-only ('..n..' checks)')
