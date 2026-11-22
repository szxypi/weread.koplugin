package.path='./?.lua;'..package.path
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local Crypto=require('weread.lib.crypto')
local body='<html><body><p>Test source text.</p></body></html>'
local entry={book_id='42',chapter_uid='37',chapter_idx=2,book_version=7,source_sha256=Crypto.sha256_hex(body),
    file_id=string.rep('a',64),key=string.rep('b',64),copy=0,catalog_sha256=string.rep('c',64),
    catalog_order=2,catalog_count=3,catalog_prev='36',catalog_next='38'}
local scope={vid='123',epoch=1};local native={scope=scope};local web={web={cookies={wr_vid='123'}}}
local live=true;local source_changed=false;local file_changed=false;local web_error;local anchor_ok=true
local target_reversible=true;local source_requests=0;local web_requests=0
local anchor_text='valid target anchor';local anchor_offset=2
package.preload['weread.lib.source_dom']=function() return {normalize=function(s) return s end} end
package.preload['weread.lib.native_direct_cache']=function() return {
    valid_entry=function(e,id,account) return e==entry and id=='42' and account=='123' end,
    identify=function() if file_changed then return nil end;return entry end,
} end
package.preload['weread.lib.native_read_access']=function() return {matches=function() return live end} end
package.preload['weread.lib.native_chapter_source']=function() return {fetch=function()
    source_requests=source_requests+1
    return {is_text=false,book_version=7,reading_catalog_sha256=entry.catalog_sha256,body=source_changed and body..'x' or body}
end} end
package.preload['weread.lib.source_currentness']=function() return {
    matches=function() return live end,
    expected=function(value) return value end,
    fetch=function(_,expected) web_requests=web_requests+1;if web_error then error(web_error,0) end;return expected end,
    packet=function(actual,expected) return actual==expected end,
} end
package.preload['weread.lib.source_coordinates']=function() return {MAX_BYTES=2097152,build=function() return {
    anchor=function(_,co) return {co=co,text=anchor_text,point_offset=anchor_offset} end,
    locate_point=function() return target_reversible and {co=2000} or nil end,
} end} end
package.preload['weread.lib.source_position_worker']=function() return {MAX_CONTEXT_BYTES=8192,
    locate_verified_map=function() return anchor_ok and 1234 or nil end} end
local Position=require('weread.lib.native_direct_position')
local context={file='/tmp/a.epub',book_id='42',chapter_uid='37',render_path='OEBPS/text/chapter.xhtml',
    identity={book_id='42',book_version=7,file_id=entry.file_id},text='Test source text.',point_offset=3}
local function check() return Position.prepare({}, {},entry,context.file,context,native,web,function() return live end) end
local value=check();local reason
expect(value and value.chapter_offset==1234 and value.basis=='filtered_xhtml_utf16'
    and value.source_current and value.upload_verified==false,'matching source did not produce read-only position')
expect(source_requests==1 and web_requests==1,'position proof did not read each source')
anchor_text='前😀一二三四五六七八九十一二三四五六七八九十二三';anchor_offset=1
local candidate,_,_,summary=Position.prepare({}, {},entry,context.file,context,native,web,function() return live end,nil,{prepare_summary=true})
expect(candidate and summary=='😀一二三四五六七八九十一二三四五六七八九','summary was not bounded by Unicode scalars')
anchor_offset=100;candidate,reason=Position.prepare({}, {},entry,context.file,context,native,web,function() return live end,nil,{prepare_summary=true})
expect(not candidate and reason=='summary_unavailable','empty summary was accepted')
anchor_text='valid target anchor';anchor_offset=2
local _,_,target=Position.prepare({}, {},entry,context.file,context,native,web,function() return live end,2000)
expect(target and target.co==2000,'verified target anchor missing')
target_reversible=false;_,_,target=Position.prepare({}, {},entry,context.file,context,native,web,function() return live end,2000)
expect(not target,'non-reversible target anchor accepted');target_reversible=true
target=Position.prepare_target({}, {},entry,context.file,native,web,function() return live end,2000)
expect(target and target.co==2000,'cross-chapter target preparation failed')
target_reversible=false;target=Position.prepare_target({}, {},entry,context.file,native,web,function() return live end,2000)
expect(not target,'cross-chapter target accepted a non-reversible anchor');target_reversible=true
local previous_web_requests=web_requests
source_changed=true;value,reason=check();expect(not value and reason=='source_changed' and web_requests==previous_web_requests,'changed native source reached web proof')
source_changed=false;file_changed=true;value,reason=check();expect(not value and reason=='file_changed','unverified file accepted')
file_changed=false;web_error='source_currentness/source_changed';value,reason=check();expect(not value and reason=='source_changed','web mismatch accepted')
web_error='source_currentness/web_expired';value,reason=check();expect(not value and reason=='web_expired','expired web login lost its classification')
web_error=nil;anchor_ok=false;value,reason=check();expect(not value and reason=='anchor_unavailable','ambiguous anchor accepted')
anchor_ok=true;context.identity.file_id=string.rep('d',64);value,reason=check();expect(not value and reason=='invalid','different reader file accepted')
context.identity.file_id=entry.file_id;web.web.cookies.wr_vid='456';value,reason=check();expect(not value and reason=='invalid','different account accepted')
web.web.cookies.wr_vid='123';live=false;value,reason=check();expect(not value and reason=='invalid','stale session accepted')
print('PASS: native reader source proof stays read-only and identity-bound ('..checks..' checks)')
