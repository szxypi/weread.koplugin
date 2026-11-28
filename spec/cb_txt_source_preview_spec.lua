package.path='./?.lua;'..package.path
local Service=require('weread.lib.source_position')
local Source=require('weread.lib.position_source')
local Identity=require('weread.lib.book_file_identity')
local Crypto=require('weread.lib.crypto')
local Currentness=require('weread.lib.source_currentness')
local Native=require('weread.lib.native_read_access')
local Archive=require('weread.lib.source_archive')
local checks=0
local function expect(v,why) checks=checks+1;assert(v,why or ('check '..checks)) end
local function copy(v) if type(v)~='table' then return v end;local o={};for k,x in pairs(v) do o[k]=copy(x) end;return o end
local raw='\239\187\191A😀\r\n　 <tag>&amp;Raw imported source remains unchanged.'
local book,chapters={book_id='CB_Synthetic',bookVersion=7},{{chapterUid=11,chapterIdx=0}}
local path='OEBPS/text/chapter.xhtml'
local rendered=require('weread.lib.content').txt_to_xhtml(raw)
local root=Identity.encode(book,chapters,Identity.capture(book),Crypto.sha256_hex(rendered));local identity=assert(Identity.decode(root))
local source=assert(Source.capture(book,chapters[1],raw,'web_txt'))
local meta=assert(Source.bind(source,identity,path,Crypto.sha256_hex(rendered)))
local members={[Identity.PATH]=root,[Source.path_meta_path(path)]=meta,[Source.raw_path(source.raw_sha256)]=raw,[path]=rendered}
local old_archive=Archive.read;Archive.read=function() return members end
local doc={file='/synthetic.epub',getDocumentFileContent=function(_self,name)
    expect(name==Identity.PATH or name==Source.meta_path('11') or name==Source.path_meta_path(path),'UI read whole source')
    return name==Source.meta_path('11') and meta or members[name]
end}
local point={book_id=book.book_id,chapter_uid='11',chapter_offset=2,file_id=identity.file_id,book_version=7,raw_sha256=source.raw_sha256,
    render_path=path,basis='raw_txt_utf16',upload_verified=false}
local scope={vid='900000',epoch=1};local cookies={wr_vid='900000',wr_skey='synthetic-cookie-value'}
local settings={get_auth_scope=function() return scope end,auth_scope_matches=function(_self,v) return v==scope end,
    get=function(_self,key,default) return key=='cookies' and cookies or default end}
local worker={cancel=function() end};function worker:start(task,callback) self.task,self.callback=task,callback;return true end
local context={book_id=book.book_id,chapters=chapters,percent=37};local clock,online=100,true
local service=Service:new{scheduler={scheduleIn=function() end,unschedule=function() end},client={settings=settings},
    make_worker=function() return worker end,get_upload_context=function() return context end,
    get_document=function() return doc end,get_book_id=function() return book.book_id end,get_account=function() return '900000' end,
    context={location=function() return {page=1,pos=0,xpointer='synthetic',view_mode='page'} end},
    now=function() return clock end,is_online=function() return online end}
local old_initial,old_upload,old_capture,old_matches=Currentness.run_cb_txt_initial,Currentness.run_cb_txt_upload,
    Native.capture,Currentness.matches_cb_initial_access
local native={scope=scope};local native_available=true
Native.capture=function() return native_available and native or nil end
Currentness.matches_cb_initial_access=function(s,selected,value)
    return native_available and value==native and Currentness.matches(s,selected)
end
local initial=assert(require('weread.lib.cb_initial_state').from({book={bookId=book.book_id,chapterUid=0,chapterOffset=0,progress=0}},book.book_id))
local remote={book_id=book.book_id,source='web',chapter_uid='11',chapter_idx=0,chapter_offset=25,raw_percent=37,
    updated_at=123,has_chapter_index=true,has_chapter_offset=true}
local function result(_client,expected)
    local check=copy(expected);check.catalog_stamp=string.rep('a',64);check.source_current=true;check.upload_verified=false;check.basis='raw_txt_utf16'
    return {check=check}
end
Currentness.run_cb_txt_initial=function(client,expected,_selected,prior,chosen)
    expect(prior.kind=='cb_no_chapter' and chosen==native,'first state not bound');return result(client,expected)
end
Currentness.run_cb_txt_upload=function(client,expected,_selected,prior)
    expect(prior.chapter_offset==25 and prior.book_id==book.book_id,'selected position not bound');return result(client,expected)
end
local returned,reason,receipt,calls
local function finish() local callback,task=worker.callback,worker.task;callback(task()) end
local function start(first)
    service.state='ready';service.result=copy(point);service.scope=service:_live()
    returned,reason,receipt,calls=nil,nil,nil,0
    local callback=function(v,why,token) returned,reason,receipt=v,why,token;calls=calls+1 end
    if first then service:prepare_cb_initial_upload_preview(initial,callback,'raw_txt_utf16')
    else service:prepare_cb_current_upload_preview(remote,callback,'raw_txt_utf16') end
    expect(service.preview_job~=nil);finish();expect(service.preview_job~=nil,'online source check not started')
end
for _i,first in ipairs({true,false}) do
    start(first);clock=110;finish()
    local current=first and service.is_current_cb_initial_preview or service.is_current_cb_upload_preview
    local deadline=first and service.cb_initial_preview_deadline or service.cb_upload_preview_deadline
    expect(calls==1 and returned and receipt and next(receipt)==nil and returned.percent==37,'candidate missing')
    expect(current(service,receipt,returned) and deadline(service,receipt,returned)==130,'local receipt deadline was extended')
    expect(not service:is_current_upload_preview(receipt,returned) and not service:is_current_native_preview(receipt,returned),
        'imported TXT proof escaped its own scope')
    local modified=copy(returned);modified.summary='changed';expect(not current(service,receipt,modified),'changed summary accepted')
    context.percent=38;expect(not current(service,receipt,returned),'changed percent accepted');context.percent=37
    cookies.wr_skey='synthetic-rotated-cookie';expect(not current(service,receipt,returned),'changed session accepted')
    cookies.wr_skey='synthetic-cookie-value'
    clock=131;expect(not current(service,receipt,returned),'expired proof accepted');clock=100
    if first then native_available=false;expect(not current(service,receipt,returned),'changed native access accepted');native_available=true end
end
Currentness.run_cb_txt_initial=function() return {error='source_remote_changed'} end
start(true);finish();expect(calls==1 and not returned and reason=='source_remote_changed','changed first state not reported')
Currentness.run_cb_txt_upload=function() return {error='source_web_expired'} end
start(false);finish();expect(calls==1 and not returned and reason=='source_authentication_unavailable','401 not reported')
native_available=false
service.state='ready';service.result=copy(point);service.scope=service:_live();calls=0
service:prepare_cb_initial_upload_preview(initial,function(v,why) returned,reason=v,why;calls=calls+1 end,'raw_txt_utf16')
finish();expect(calls==1 and not returned and reason=='source_native_authentication_unavailable','missing native login accepted')
Archive.read,Currentness.run_cb_txt_initial,Currentness.run_cb_txt_upload=old_archive,old_initial,old_upload
Native.capture,Currentness.matches_cb_initial_access=old_capture,old_matches
print(('cb_txt_source_preview_spec: %d checks'):format(checks))
