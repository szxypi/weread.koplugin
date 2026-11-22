package.path='./?.lua;'..package.path
local live=true;local source_error;local file_ok=true;local calls=0
local settings={data_dir='/synthetic'};local file='/synthetic/native-reader-v1/chapter.epub'
local native={scope={vid='123'}};local web={web={cookies={wr_vid='123'}}};local entry={book_id='42',book_version=7}
local row={selection=true};local input={first={},last={},text='quote'}
package.preload['weread.lib.native_read_access']=function() return {matches=function() return live end} end
package.preload['weread.lib.source_currentness']=function() return {capture=function() return web end,matches=function() return live end} end
package.preload['weread.lib.native_direct_cache']=function() return {identify=function(_,account,path,current)
    assert(account=='123' and path==file and current());return file_ok and entry or nil end} end
package.preload['weread.lib.native_direct_position']=function() return {verified_source=function(_,_,e,path,n,w,current)
    assert(e==entry and path==file and n==native and w==web and current());calls=calls+1
    if source_error then return nil,source_error end;return 'verified source'
end} end
package.preload['weread.lib.selection_reference']=function() return {
    capture_direct=function(value,e,path,raw) assert(value==input and e==entry and path==file and raw=='verified source');return row end,
    verify_direct=function(value,e,path,raw) assert(value==row and e==entry and path==file and raw=='verified source');return row end,
    restore_direct=function(e,path,key,raw) assert(e==entry and path==file and key=='draft' and raw=='verified source');return row end,
} end
local Direct=require('weread.lib.native_direct_reference');local checks=0
local function expect(v,label) checks=checks+1;assert(v,label) end
local function current() return live end
expect(Direct.capture({},settings,entry,file,input,native,web,current)==row,'verified selection unavailable')
local verified,_,version=Direct.verify({},settings,native,row,file,current)
expect(verified==row and version==7,'verified source version missing')
expect(Direct.restore({},settings,entry,file,'draft',native,web,current)==row,'verified draft unavailable')
local previous=calls
expect(not Direct.capture({},settings,entry,'/outside',input,native,web,current) and calls==previous,'outside path read source')
file_ok=false;expect(not Direct.verify({},settings,native,row,file,current) and calls==previous,'invalid cache read source');file_ok=true
web.web.cookies.wr_vid='456';local result,why=Direct.verify({},settings,native,row,file,current)
expect(not result and why=='web_expired' and calls==previous,'foreign Web account read source');web.web.cookies.wr_vid='123'
source_error='source_changed';result,why=Direct.capture({},settings,entry,file,input,native,web,current)
expect(not result and why=='source_changed','changed source produced a selection')
source_error=nil;live=false;expect(not Direct.restore({},settings,entry,file,'draft',native,web,current),'changed account restored a draft')
print('PASS: native selection and draft bind both source channels to the account ('..checks..' checks)')
