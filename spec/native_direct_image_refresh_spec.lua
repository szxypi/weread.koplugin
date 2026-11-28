package.path='./?.lua;'..package.path
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local digest=string.rep('a',64);local source_hash=string.rep('b',64);local file_id=string.rep('c',64)
local entry={book_id='42',chapter_uid='7',chapter_idx=1,book_version=3,key=digest,copy=0,file_id=file_id,
    source_sha256=source_hash,missing_images=2,catalog_sha256=digest,catalog_order=1,catalog_count=2,catalog_next='8'}
local selected={scope={vid='123'},fingerprint=digest,credentials={vid='123'}}
local live,valid,source,source_error,fail_catalog,changed,publications,change_after_save=true,true,nil,nil,nil,false,0,false
local catalog={book_id='42',version=3,reading_digest=digest,chapters={
    {chapterUid='7',chapterIdx=1,downloadable=true,catalog_order=1,catalog_count=2,catalog_next='8'},
    {chapterUid='8',chapterIdx=2,downloadable=true,catalog_order=2,catalog_count=2,catalog_prev='7'}}}
package.preload['weread.lib.native_read_access']=function() return {matches=function(_,s) return valid and s==selected end} end
package.preload['weread.lib.native_direct_cache']=function() return {
    valid_entry=function(value,id,account) return value==entry and id=='42' and account=='123' end,
    identify=function() if changed then return {} end return entry end,
    publish=function(_,account,book,chapter,prepared,current)
        expect(account=='123' and book.book_id=='42' and chapter.chapterUid=='7' and current(),'publication lost scope')
        publications=publications+1
        if change_after_save then changed=true end
        return {path='/new.epub',book_version=prepared.book_version,source_sha256=prepared.source_sha256,
            missing_images=prepared.missing_images}
    end,
} end
package.preload['weread.lib.native_authorization']=function() return {new=function() return {cancel=function() end} end} end
package.preload['weread.lib.native_book_catalog']=function() return {read=function()
    if fail_catalog then error(fail_catalog,0) end
    return catalog
end} end
package.preload['weread.ui.native_direct_reading']=function() return {project=function(model) return model end} end
package.preload['weread.lib.native_direct_source']=function() return {fetch=function(_,_,book,uid,expected,options)
    expect(book=='42' and uid=='7' and expected.reading_catalog_sha256==digest and options.allow_missing_images
        and options.is_current(),'source preparation lost scope')
    return source,source_error
end} end
local Refresh=require('weread.lib.native_direct_image_refresh')
local function run() return Refresh.run({}, {},selected,entry,'/old.epub',{book_id='42'},function() return live end) end
source={book_version=3,source_sha256=source_hash,missing_images=0}
local result=run();expect(result.kind=='improved' and result.path=='/new.epub' and publications==1,'improved copy not saved')
source.missing_images=2;result=run();expect(result.kind=='unchanged' and publications==1,'unchanged copy was saved')
source.missing_images=3;result=run();expect(result.kind=='unchanged' and publications==1,'worse copy was saved')
source.missing_images=0;source.source_sha256=string.rep('d',64);result=run()
expect(result.error=='changed' and publications==1,'changed chapter was saved')
source.source_sha256=source_hash;changed=true;result=run();expect(result.error=='changed' and publications==1,'changed original accepted');changed=false
catalog.reading_digest=string.rep('d',64);result=run();expect(result.error=='catalog_changed' and publications==1,'changed catalog accepted')
catalog.reading_digest=digest;catalog.chapters[1].downloadable=false;result=run();expect(result.error=='catalog_changed','locked chapter fetched')
catalog.chapters[1].downloadable=true;fail_catalog='native_auth/native_catalog_info/http_401'
result=run();expect(result.error=='auth_expired','expired authorization not identified')
fail_catalog='native_auth/native_catalog_catalog/http_429';result=run();expect(result.error=='rate_limited','limit not identified')
fail_catalog=nil;source_error='rate_limited';source=nil;result=run();expect(result.error=='rate_limited','image limit not preserved')
source_error=nil;valid=false;result=run();expect(result.error=='invalid' and publications==1,'changed account accepted')
valid=true;live=false;result=run();expect(result.error=='invalid' and publications==1,'cancelled operation accepted')
live=true;source={book_version=3,source_sha256=source_hash,missing_images=0};change_after_save=true
result=run();expect(result.error=='changed' and publications==2,'source changed during publication but succeeded')
print('PASS: native chapter image refresh verifies source and only saves improvements ('..checks..' checks)')
