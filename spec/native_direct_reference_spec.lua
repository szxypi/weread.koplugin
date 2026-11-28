package.path='./?.lua;'..package.path
local live=true;local source_error;local file_ok=true;local calls=0
local settings={data_dir='/synthetic'};local file='/synthetic/native-reader-v1/chapter.epub'
local native={scope={vid='123'}};local web={web={cookies={wr_vid='123'}}};local entry={book_id='42',book_version=7}
local original_web=web
local scope=native.scope
local row={selection=true};local input={first={},last={},text='quote'}
local identified=entry;local library={};local cached='verified source';local reads,writes=0,0
local switch_on_read
local downloaded,chapter_opens,opened_account={},0
function settings:auth_scope_matches(candidate) return live and candidate==scope end
package.preload['weread.lib.native_read_access']=function() return {matches=function() return live end} end
package.preload['weread.lib.source_currentness']=function() return {capture=function() return web end,matches=function() return live end} end
package.preload['weread.lib.native_direct_cache']=function() return {identify=function(_,account,path,current)
    assert(account=='123' and path==file and current());return file_ok and identified or nil end,
    list=function(_,account,book,current,chapter)
        assert(book=='42' and chapter=='7' and current())
        opened_account=account;return downloaded
    end,
    open=function(_,account,book,candidate,current,with_entry)
        assert(account=='123' and book=='42' and candidate==entry and current() and with_entry)
        chapter_opens=chapter_opens+1
        if file_ok then return {path=file},entry end
    end,
} end
package.preload['weread.lib.native_direct_mark_source_store']=function() return {new=function(_,db)
    assert(db==library);return {read=function(_,e)
        assert(e==identified);reads=reads+1
        if switch_on_read then live=false end
        return cached
    end,
        write=function(_,e,raw) assert(e==entry and raw=='verified source');writes=writes+1;return true end}
end} end
package.preload['weread.lib.native_direct_position']=function() return {verified_source=function(_,_,e,path,n,w,current)
    assert(e==entry and path==file and n==native and w==web and current());calls=calls+1
    if source_error then return nil,source_error end;return 'verified source'
end} end
package.preload['weread.lib.selection_reference']=function() return {
    parse=function(key) if key=='draft' then return {chapter_uid='7',raw_sha256=string.rep('a',64)} end end,
    capture_direct=function(value,e,path,raw) assert(value==input and e==entry and path==file and raw=='verified source');return row end,
    verify_direct=function(value,e,path,raw) assert(value==row and e==entry and path==file and raw=='verified source');return row end,
    restore_direct=function(e,path,key,raw) assert(e==entry and path==file and key=='draft' and raw=='verified source');return row end,
} end
package.preload['weread.lib.bookmark_reference']=function() return {
    capture_direct=function(value,e,path,raw) assert(value==input and e==entry and path==file and raw=='verified source');return row end,
    verify_direct=function(value,e,path,raw) assert(value==row and e==entry and path==file and raw=='verified source');return row end,
} end
local Direct=require('weread.lib.native_direct_reference');local checks=0
local function expect(v,label) checks=checks+1;assert(v,label) end
local function current() return live end
expect(Direct.capture({},settings,entry,file,input,native,web,current)==row,'verified selection unavailable')
local verified,_,version=Direct.verify({},settings,native,row,file,current)
expect(verified==row and version==7,'verified source version missing')
expect(Direct.capture({},settings,entry,file,input,native,web,current,true)==row,'verified bookmark unavailable')
verified,_,version=Direct.verify({},settings,native,row,file,current,true)
expect(verified==row and version==7,'bookmark source version missing')
expect(Direct.restore({},settings,entry,file,'draft',native,web,current)==row,'verified draft unavailable')
expect(Direct.capture({},settings,entry,file,input,native,web,current,false,library)==row and writes==1,
    'verified online selection did not populate the offline source cache')
expect(Direct.restore({},settings,entry,file,'draft',native,web,current,library)==row and writes==2,
    'verified online draft did not populate the offline source cache')
local previous=calls
web=nil
expect(Direct.capture_cached(settings,library,entry,file,input,scope)==row and calls==previous and reads==1,
    'offline selection did not use cached verified source')
expect(Direct.restore_cached(settings,library,entry,file,'draft',scope)==row and calls==previous and reads==2,
    'offline draft did not use cached verified source')
cached=nil;local no_cache,no_cache_reason=Direct.capture_cached(settings,library,entry,file,input,scope)
expect(not no_cache and no_cache_reason=='offline_source_unavailable' and calls==previous,'missing cache triggered a source request')
cached='verified source';identified={book_id='42',book_version=8}
expect(not Direct.capture_cached(settings,library,entry,file,input,scope) and calls==previous and reads==3,
    'changed chapter was matched to an old cached source')
identified=entry
switch_on_read=true
local switched,switch_reason=Direct.capture_cached(settings,library,entry,file,input,scope)
expect(not switched and switch_reason=='session_changed' and calls==previous,
    'account switch during a local chapter read produced a usable quote')
live=true;switch_on_read=false
web=original_web
expect(not Direct.capture({},settings,entry,'/outside',input,native,web,current) and calls==previous,'outside path read source')
file_ok=false;expect(not Direct.verify({},settings,native,row,file,current) and calls==previous,'invalid cache read source');file_ok=true
web.web.cookies.wr_vid='456';local result,why=Direct.verify({},settings,native,row,file,current)
expect(not result and why=='web_expired' and calls==previous,'foreign Web account read source');web.web.cookies.wr_vid='123'
expect(not Direct.capture_cached(settings,library,entry,file,input,{vid='456'}) and calls==previous,
    'foreign account used cached source')
source_error='source_changed';result,why=Direct.capture({},settings,entry,file,input,native,web,current)
expect(not result and why=='source_changed','changed source produced a selection')
source_error=nil;live=false;expect(not Direct.restore({},settings,entry,file,'draft',native,web,current),'changed account restored a draft')
expect(not Direct.capture_cached(settings,library,entry,file,input,scope)
    and not Direct.restore_cached(settings,library,entry,file,'draft',scope),'changed account used offline source')
live=true;entry.source_sha256=string.rep('a',64);entry.file_id=string.rep('b',64)
downloaded={{source_sha256=string.rep('c',64)},entry}
previous=calls
local restored,pinned=Direct.restore_downloaded(settings,library,native.scope,'42','draft')
expect(restored==row and pinned.path==file and pinned.file_id==entry.file_id and opened_account=='123'
    and chapter_opens==1 and calls==previous,'downloaded lookup did not select the exact saved chapter')
file_ok=false
expect(not Direct.restore_downloaded(settings,library,native.scope,'42','draft') and calls==previous,
    'unverified downloaded chapter restored a draft')
expect(not Direct.restore_downloaded(settings,library,{vid='456'},'42','draft') and chapter_opens==2,
    'foreign account opened the selected chapter')
print('PASS: native selection and draft bind both source channels to the account ('..checks..' checks)')
