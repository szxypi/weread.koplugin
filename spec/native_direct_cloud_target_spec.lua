package.path='./?.lua;'..package.path
local Crypto=require('weread.lib.crypto')
local checks=0;local function expect(v,m) checks=checks+1;assert(v,m) end
local body='synthetic native chapter';local digest=Crypto.sha256_hex(body)
local stamp=string.rep('a',64);local catalog_sha=string.rep('c',64)
local entry={book_id='42',chapter_uid='37',chapter_idx=2,book_version=7,catalog_sha256=catalog_sha}
local target={book_id='42',chapter_uid='38',chapter_idx=3,chapter_offset=50,stamp=stamp}
local native={scope={vid='123'},credentials={vid='123'},fingerprint='synthetic'};local web={}
local row={chapterUid='38',chapterIdx=3,downloadable=true}
local catalog={book_id='42',version=7,reading_digest=catalog_sha,chapters={row}}
local cached={book_id='42',chapter_uid='38',chapter_idx=3,book_version=7,catalog_sha256=catalog_sha,source_sha256=digest}
local live=true;local cloud_count=0;local source_count=0;local build_count=0;local cache_hit=true
local target_identifications=0
local changed=false;local duplicate=false;local source_mismatch=false;local bad_target=false
package.preload['weread.lib.native_read_access']=function() return {matches=function() return live end} end
package.preload['weread.lib.source_currentness']=function() return {matches=function() return live end} end
package.preload['weread.lib.native_authorization']=function() return {new=function() return {cancel=function() end} end} end
package.preload['weread.lib.native_book_catalog']=function() return {read=function() return catalog end} end
package.preload['weread.ui.native_direct_reading']=function() return {project=function(model)
    if duplicate then return {book_id='42',version=7,reading_digest=catalog_sha,
        chapters={row,{chapterUid='39',chapterIdx=3,downloadable=true}}} end
    return model
end} end
package.preload['weread.lib.native_direct_cloud']=function() return {
    valid_target=function(v) return v==target end,
    same_target=function(a,b) return a==b end,
    prepare=function()
        cloud_count=cloud_count+1
        if changed and cloud_count>1 then return {relation='same',target=target} end
        return {relation='other_chapter',target=target}
    end,
    prepare_destination=function(_,_,e,path,_,_,active,wanted)
        assert(e==cached and path=='/target' and active() and wanted==target)
        if bad_target then return nil,'target_unavailable' end
        return {target=target,anchor={co=target.chapter_offset}}
    end,
} end
package.preload['weread.lib.native_chapter_source']=function() return {fetch=function()
    source_count=source_count+1
    return {is_text=false,book_version=7,reading_catalog_sha256=catalog_sha,body=source_mismatch and body..'x' or body}
end} end
package.preload['weread.lib.native_direct_cache']=function() return {
    list=function(_,owner,book,current,uid)
        assert(owner=='123' and book=='42' and uid==target.chapter_uid and current())
        return cache_hit and {cached} or {}
    end,
    open=function(_,_,_,candidate,current,with_entry)
        assert(candidate==cached and current() and with_entry)
        return {path='/target'},cached
    end,
    identify=function(_,_,path)
        target_identifications=target_identifications+1
        return path=='/target' and cached or nil
    end,
    valid_entry=function(value,id,owner) return value==cached and id=='42' and owner=='123' end,
} end
package.preload['weread.lib.native_direct_reader']=function() return {build=function(_,_,book,chapter,expected,options)
    build_count=build_count+1
    assert(book.book_id=='42' and chapter==row and expected.chapter_uid=='38' and options.is_current())
    return {path='/target',source_sha256=digest,book_version=7}
end} end
local Target=require('weread.lib.native_direct_cloud_target')
local function resolve()
    cloud_count,source_count,build_count,target_identifications=0,0,0,0
    return Target.resolve({}, {},entry,'/current',{},native,web,function() return live end,target,{book_id='42'})
end
local result=resolve();local reason
expect(result and result.reused and result.path=='/target' and cloud_count==2 and source_count==1 and build_count==0
    and target_identifications==0,
    'verified cached chapter was not selected')
cache_hit=false;result=resolve();expect(result and result.reused==false and build_count==1 and target_identifications==1,
    'uncached chapter was not prepared and identified')
cache_hit=true;row.downloadable=false;result,reason=resolve()
expect(not result and reason=='not_entitled' and source_count==0 and build_count==0,'unavailable chapter was downloaded')
row.downloadable=true;duplicate=true;result,reason=resolve()
expect(not result and reason=='catalog_changed' and source_count==0,'ambiguous catalog index was accepted')
duplicate=false;changed=true;result,reason=resolve()
expect(not result and reason=='cloud_changed' and cloud_count==2,'changed cloud target was handed off')
changed=false;bad_target=true;result,reason=resolve()
expect(not result and reason=='target_unavailable','unlocatable target was handed off')
bad_target=false
source_mismatch=true;cache_hit=false;result,reason=resolve()
expect(not result and reason=='source_changed','inconsistent prepared chapter source was accepted')
source_mismatch=false;live=false;result,reason=resolve()
expect(not result and reason=='invalid' and cloud_count==0,'stale account requested a chapter')
print('PASS: native cloud chapter resolution guards identity, entitlement and staleness ('..checks..' checks)')
