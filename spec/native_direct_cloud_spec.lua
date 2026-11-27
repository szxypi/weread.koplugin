package.path='./?.lua;'..package.path
local n=0;local function expect(value,message) n=n+1;assert(value,message) end
local live=true;local fail_at,fail_reason,source_error,target_missing;local calls=0;local snapshots={}
local entry={book_id='42',chapter_uid='37',chapter_idx=2}
local native={scope={vid='123'},credentials={vid='123'}};local web={}
local function snapshot(uid,index,offset,progress)
    return {bookId='42',chapterUid=uid,chapterIdx=index,chapterOffset=offset,progress=progress,
        summary=uid==0 and '' or 'A sample cloud position',readingTime=100,recordReadingTime=0,ttsTime=0}
end
package.preload['weread.lib.native_read_access']=function() return {matches=function() return live end} end
package.preload['weread.lib.source_currentness']=function() return {matches=function() return live end} end
package.preload['weread.lib.native_authorization']=function() return {new=function(_,_,options) return {
    _request=function(_,stage,url,body,credentials)
        calls=calls+1;assert(stage=='direct_progress' and url=='https://i.weread.qq.com/book/getProgress?bookId=42'
            and body==nil and credentials==native.credentials and options.is_current())
        if calls==fail_at then error(fail_reason,0) end
        return assert(snapshots[calls])
    end,cancel=function() end} end} end
package.preload['weread.lib.native_direct_position']=function() return {prepare=function(_,_,e,file,context,ns,ws,active,target)
    assert(e==entry and file=='/native' and context=='context' and ns==native and ws==web and active())
    if source_error then return nil,source_error end
    local point={book_id='42',chapter_uid='37',chapter_idx=2,chapter_offset=20,upload_verified=false}
    return point,nil,target and not target_missing and {co=target,text='valid anchor text',point_offset=2,
        point_unit='unicode_scalars',basis='filtered_xhtml_utf16'} or nil
end,prepare_target=function(_,_,e,file,ns,ws,active,offset)
    assert(e.book_id=='42' and e.chapter_uid=='38' and file=='/target' and ns==native and ws==web and active())
    if source_error then return nil,source_error end
    return {co=offset,text='valid target anchor',point_offset=2,point_unit='unicode_scalars',basis='filtered_xhtml_utf16'}
end} end
local C=require('weread.lib.native_direct_cloud')
local function check(first,last)
    calls=0;snapshots={first,last or first}
    return C.prepare({}, {},entry,'/native','context',native,web,function() return live end)
end
local same=snapshot(37,2,20,4);local value=check(same);local why
expect(value and value.relation=='same' and calls==2,'same position was not compared twice')
local different=snapshot(37,2,25,4);value=check(different)
expect(value and value.relation=='different' and value.cloud_offset==25 and value.anchor.co==25,'same-chapter target lost')
local without_summary=snapshot(37,2,25,4);without_summary.summary=nil;value=check(without_summary)
expect(value and value.relation=='different','read-only cloud position required an optional summary')
local empty_summary=snapshot(37,2,25,4);empty_summary.summary='';value,why=check(without_summary,empty_summary)
expect(not value and why=='cloud_changed','changed summary presence was ignored')
target_missing=true;value=check(different);expect(value and value.relation=='target_unavailable' and not value.anchor,'unlocatable target exposed')
target_missing=false;local other=snapshot(38,3,25,5);value=check(other)
expect(value and value.relation=='other_chapter' and not value.anchor and C.valid_target(value.target),'foreign chapter target was not bound')
local wanted=value.target;local target_entry={book_id='42',chapter_uid='38',chapter_idx=3};calls=0;snapshots={other,other}
local destination=C.prepare_destination({}, {},target_entry,'/target',native,web,function() return live end,wanted)
expect(destination and destination.anchor.co==25 and calls==2,'destination did not verify cloud and source')
local altered=snapshot(38,3,26,5);calls=0;snapshots={altered,altered}
destination,why=C.prepare_destination({}, {},target_entry,'/target',native,web,function() return live end,wanted)
expect(not destination and why=='cloud_changed' and calls==1,'changed destination was accepted')
value=check(snapshot(0,0,0,0));expect(value and value.relation=='no_chapter','empty cloud not represented')
value,why=check(snapshot(37,3,25,4));expect(not value and why=='cloud_changed' and calls==1,'inconsistent chapter index accepted')
value,why=check(same,different);expect(not value and why=='cloud_changed' and calls==2,'changed remote position accepted')
local changed=snapshot(37,2,20,4);changed.readingTime=101;value,why=check(same,changed)
expect(not value and why=='cloud_changed','changed cloud counters accepted')
source_error='source_changed';value,why=check(same);expect(not value and why=='source_changed' and calls==1,'bad source reached second cloud read')
source_error=nil;fail_at=1;fail_reason='native_auth/direct_progress/http_401';value,why=check(same)
expect(not value and why=='auth_expired' and calls==1,'expired auth was not classified')
fail_reason='native_auth/direct_progress/http_429';value,why=check(same)
expect(not value and why=='rate_limited' and calls==1,'limited request was retried')
fail_at=nil;live=false;value,why=check(same);expect(not value and why=='invalid' and calls==0,'stale account reached network')

local checked={book_id='42',chapter_uid='38',book_version=7,source_sha256='raw',catalog_sha256='catalog',file_id='file'}
local raw
package.loaded['weread.lib.native_direct_cache']={identify=function() return checked end,
    read_raw_source=function() return raw end}
require('weread.lib.native_read_access').guard=function(_,current) return current end
local Resume=require('weread.lib.native_direct_resume')
local quote='A unique excerpt from the original chapter'
raw='<html><body><p>'..quote..'</p></body></html>'
local map=assert(require('weread.lib.source_coordinates').build(raw,{format='web_xhtml'}))
local point=assert(map:locate_point(quote,0))
local progress={bookId='42',chapterUid=38,chapterOffset=point.co,progress=25,summary=quote}
local hint=assert(Resume.hint(progress,'42'))
expect(hint.uid=='38' and not hint.idx and Resume.valid_target(hint.target),'native progress without an index did not provide a target')
expect(not Resume.hint(progress,'43'),'foreign book provided a resume hint')
progress.chapterIdx=3
local indexed=Resume.hint(progress,'42');local exact=assert(indexed.target)
expect(indexed.idx==3,'explicit chapter index was dropped')
expect(not Resume.matches_entry({book_id='42',chapter_uid='38',chapter_idx=2},exact),'conflicting chapter index could locate text')
progress.chapterIdx=nil
local function resume(target)
    calls=0;snapshots={progress}
    return Resume.prepare_destination({}, {},checked,'/native',native,function() return live end,target)
end
live=true;value=resume(hint.target)
expect(value and value.anchor.co==point.co and value.anchor.point_offset==0 and calls==1,
    'unique summary at its saved offset could not be located')
progress.chapterOffset=point.co+1;value,why=resume(hint.target)
expect(not value and why=='cloud_changed','a changed cloud point was used')
expect(not resume(Resume.hint(progress,'42').target),'a unique summary at a different offset was used')
progress.chapterOffset=point.co;raw='<html><body><p>'..quote..'</p><p>'..quote..'</p></body></html>'
expect(not resume(hint.target),'a repeated summary was used')
progress.summary=nil;progress.chapterTitle=quote
expect(not Resume.hint(progress,'42').target,'an inferred chapter title was used as the cloud summary')
print('PASS: native direct cloud comparison is stable and read-only ('..n..' checks)')
