package.path='./?.lua;'..package.path
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local Crypto=require('weread.lib.crypto')
local body='<html><body><p>Test source text.</p></body></html>'
local entry={book_id='42',chapter_uid='37',chapter_idx=2,book_version=7,source_sha256=Crypto.sha256_hex(body),
    file_id=string.rep('a',64),key=string.rep('b',64),copy=0,catalog_sha256=string.rep('c',64),
    catalog_order=2,catalog_count=3,catalog_prev='36',catalog_next='38'}
local scope={vid='123',epoch=1};local native={scope=scope};local web={web={cookies={wr_vid='123'}}}
local live=true;local source_changed=false;local file_changed=false;local change_file_during_fetch=false;local web_error;local anchor_ok=true
local target_reversible=true;local source_requests=0;local web_requests=0
local txt,wrong_basis
local anchor_text='valid target anchor';local anchor_offset=2
package.preload['weread.lib.source_dom']=function() return {normalize=function(s) return s end} end
package.preload['weread.lib.native_direct_cache']=function() return {
    valid_entry=function(e,id,account) return e==entry and id=='42' and account=='123' end,
    identify=function() if file_changed then return nil end;return entry end,
} end
package.preload['weread.lib.native_read_access']=function() return {matches=function() return live end} end
package.preload['weread.lib.native_chapter_source']=function() return {fetch=function()
    source_requests=source_requests+1
    if change_file_during_fetch then file_changed=true end
    return {is_text=txt==true,book_version=7,reading_catalog_sha256=entry.catalog_sha256,body=source_changed and body..'x' or body}
end} end
package.preload['weread.lib.source_currentness']=function() return {
    matches=function() return live end,
    expected=function(value) return value end,
    fetch=function(_,expected,_selected,format,options)
        web_requests=web_requests+1;if web_error then error(web_error,0) end
        if options and options.verify_catalog then options.verify_catalog({version=7});options.verify_catalog({version=7}) end
        assert(format==(txt and 'web_txt' or 'web_xhtml'))
        if txt and not wrong_basis then
            local result={};for key,value in pairs(expected) do result[key]=value end
            result.basis='raw_txt_utf16';return result
        end
        return expected
    end,
    fetch_resolving_index=function(_,expected,_selected,options)
        assert(expected.chapter_idx==nil and options.resolve_index)
        if options.verify_catalog then options.verify_catalog({version=7});options.verify_catalog({version=7}) end
        local result={};for key,value in pairs(expected) do result[key]=value end
        result.chapter_idx=2;result.catalog_stamp=string.rep('e',64);return result
    end,
    packet=function(actual,expected)
        if not actual or not expected then return nil end
        for key,value in pairs(expected) do if actual[key]~=value then return nil end end
        return actual
    end,
    packet_txt=function(actual,expected)
        if actual and actual.basis=='raw_txt_utf16' and actual.raw_sha256==expected.raw_sha256 then return actual end
    end,
} end
package.preload['weread.lib.source_coordinates']=function() return {MAX_BYTES=2097152,build=function(_,options) return {
    basis=options.format=='web_txt' and 'raw_txt_utf16' or 'filtered_xhtml_utf16',
    anchor=function(_,co) return {co=co,text=anchor_text,point_offset=anchor_offset} end,
    locate_point=function(_,text) return target_reversible and {co=text=='different TXT summary' and 2001 or 2000} or nil end,
    literal_excerpt=function(_,co) assert(co==1234);return {text='原文😀\r\n\t字面 <tag>'} end,
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
live=true;local verified=Position.verified_source({}, {},entry,context.file,native,web,function() return live end)
expect(verified==body,'dual-source proof did not return verified raw bytes')
local catalog_checks=0
verified=Position.verified_source({}, {},entry,context.file,native,web,function() return live end,
    {verify_catalog=function(catalog) expect(catalog.version==7,'wrong catalog');catalog_checks=catalog_checks+1 end})
expect(verified==body and catalog_checks==2,'source proof did not check both catalog reads')
entry.chapter_idx=nil
expect(not Position.verified_source({}, {},entry,context.file,native,web,function() return live end),
    'index resolution bypassed the explicit time-only path')
local source_stamp,source_index
verified,_,source_stamp,source_index=Position.verified_source({}, {},entry,context.file,native,web,function() return live end,
    {resolve_index=true})
expect(verified==body and source_index==2 and source_stamp==string.rep('e',64) and entry.chapter_idx==nil,
    'read-only catalog index resolution failed or modified the cached entry')
entry.chapter_idx=2
source_changed=true;verified,reason=Position.verified_source({}, {},entry,context.file,native,web,function() return live end)
expect(not verified and reason=='source_changed','changed direct source was exposed');source_changed=false
web_error='source_currentness/web_expired';verified,reason=Position.verified_source({}, {},entry,context.file,native,web,function() return live end)
expect(not verified and reason=='web_expired','selection proof lost expired Web authorization');web_error=nil
file_changed=true;verified,reason=Position.verified_source({}, {},entry,context.file,native,web,function() return live end)
expect(not verified and reason=='file_changed','selection proof exposed an unverified cache');file_changed=false
change_file_during_fetch=true;verified,reason=Position.verified_source({}, {},entry,context.file,native,web,function() return live end)
expect(not verified and reason=='file_changed','selection proof missed a cache replaced during source read')
file_changed=false;change_file_during_fetch=false
txt=true
value,_,_,summary=Position.prepare({}, {},entry,context.file,context,native,web,function() return live end,nil,{prepare_summary=true})
expect(Position.matches_point(entry,value) and value.basis=='raw_txt_utf16' and summary=='原文😀\r\n\t字面 <tag>',
    'TXT position lost the literal summary or raw coordinate basis')
local function txt_target(quote)
    return Position.prepare_target({}, {},entry,context.file,native,web,function() return live end,2000,quote)
end
expect(txt_target('verified TXT summary') and not txt_target('different TXT summary') and not txt_target(),
    'TXT navigation used an offset without a matching cloud summary')
wrong_basis=true;value,reason=check();expect(not value and reason=='source_changed','XHTML packet passed TXT proof')
wrong_basis=false;verified,reason=Position.verified_source({}, {},entry,context.file,native,web,function() return live end)
expect(not verified and reason=='source_changed','TXT was exposed to XHTML-only reference capture')
live=false;expect(not Position.verified_source({}, {},entry,context.file,native,web,function() return live end),'stale selection exposed source')
print('PASS: native reader source proof stays read-only and identity-bound ('..checks..' checks)')
