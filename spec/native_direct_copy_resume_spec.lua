package.path='./?.lua;'..package.path
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local source={book_id='42',chapter_uid='7',book_version=3,file_id=string.rep('a',64),source_sha256=string.rep('b',64),missing_images=2}
local target={book_id='42',chapter_uid='7',book_version=3,file_id=string.rep('c',64),source_sha256=source.source_sha256,missing_images=0}
local context={file='/old.epub',book_id='42',chapter_uid='7',render_path='OEBPS/text/chapter.xhtml',
    identity={book_id='42',book_version=3,file_id=source.file_id},text='beforeABCDEFGHIJKLMN之后abcdefghijklmnopqrstuvwx',point_offset=6}
local current=true;local changed=false;local hit={file_id=target.file_id,anchor={co=77}}
package.preload['weread.lib.native_direct_cache']=function() return {
    identify=function(_,_,path) if changed then return nil end return path=='/old.epub' and source or target end,
    open=function() return {path='/new.epub',file_id=target.file_id} end} end
package.preload['weread.lib.native_direct_position']=function() return {same=function(a,b) return a==b end} end
package.preload['weread.lib.source_coordinates']=function() return {MAX_BYTES=1024,build=function() return {} end} end
local offset=77
package.preload['weread.lib.source_position_worker']=function() return {locate_verified_map=function(_,text,at)
    expect(text==context.text and at==context.point_offset,'context was not preserved');return offset end} end
local hits={hit}
package.preload['weread.lib.native_direct_search']=function() return {scan=function(_,_,entry,keyword,from,ignore,current_fn)
    expect(entry==target and keyword:sub(1,14)=='ABCDEFGHIJKLMN' and from==1 and not ignore and current_fn(),'search lost its source')
    return {hits=hits}
end} end
package.preload['weread.lib.source_archive']=function() return {read=function() return {['OEBPS/text/chapter.xhtml']='data'} end} end
local Resume=require('weread.lib.native_direct_copy_resume')
local function run() return Resume.prepare({},'123',source,'/old.epub','/new.epub',context,function() return current end) end
local result=run();expect(result.entry==target and result.hit==hit and result.keyword:sub(1,14)=='ABCDEFGHIJKLMN','exact local point did not match')
offset=nil;result=run();expect(result.error=='unmatched','unmatched point was accepted');offset=77
hits={{file_id=target.file_id,anchor={co=78}}};result=run();expect(result.error=='unmatched','different point was accepted')
hits={hit,hit};result=run();expect(result.error=='ambiguous','duplicate hit was accepted')
hits={hit};target.source_sha256=string.rep('d',64);result=run();expect(result.error=='changed','different source was accepted')
target.source_sha256=source.source_sha256;target.missing_images=2;result=run();expect(result.error=='changed','non-improved copy was accepted')
target.missing_images=0;changed=true;result=run();expect(result.error=='changed','changed original was accepted')
changed=false;current=false;result=run();expect(result.error=='invalid','cancelled context was accepted')
current=true;context.point_offset=1000;result=run();expect(result.error=='unmatched','short suffix was guessed')
print('PASS: improved chapter copy resumes only at a verified local text point ('..checks..' checks)')
