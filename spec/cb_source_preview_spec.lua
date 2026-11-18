package.path='./?.lua;'..package.path
local Candidate=require('weread.lib.source_upload_candidate')
local Worker=require('weread.lib.source_position_worker')
local Service=require('weread.lib.source_position')
local Source=require('weread.lib.position_source')
local Identity=require('weread.lib.book_file_identity')
local Crypto=require('weread.lib.crypto')
local Currentness=require('weread.lib.source_currentness')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message or ('check '..checks)) end
local function copy(value)
    if type(value)~='table' then return value end
    local out={};for key,item in pairs(value) do out[key]=copy(item) end;return out
end
local book,chapter={book_id='CB_Synthetic',bookVersion=1},{chapterUid=11,chapterIdx=0}
local chapters={chapter}
local raw='<html><body><p>ABCDEFG😀&amp;中文HIJKLMNOPQRSTUVWXYZ末尾。</p></body></html>'
local root=Identity.encode(book,chapters,Identity.capture(book),Crypto.sha256_hex(raw))
local identity=assert(Identity.decode(root))
local source=assert(Source.capture(book,chapter,raw,'web_xhtml'))
local path='OEBPS/text/chapter.xhtml'
local metadata=assert(Source.bind(source,identity,path,Crypto.sha256_hex(raw)))
local point={book_id=book.book_id,chapter_uid='11',chapter_offset=15,basis='filtered_xhtml_utf16',upload_verified=false,
    file_id=identity.file_id,book_version=1,raw_sha256=source.raw_sha256,render_path=path}
local members={[Identity.PATH]=root,[Source.path_meta_path(path)]=metadata,[Source.raw_path(source.raw_sha256)]=raw,[path]=raw}
local input={file='/synthetic.epub',book_id=book.book_id,chapter_uid='11',identity=identity,metadata=metadata,
    render_path=path,target=copy(point),chapters=chapters,percent=37,request_id=1}
local prepared=Worker.prepare_cb_preview(input,function() return members end)
expect(prepared.candidate and prepared.candidate.upload_verified==false,'CB source candidate missing')
expect(not Worker.prepare_upload(input,function() return members end).candidate,'ordinary worker accepted CB source')
expect(not Candidate.project(point,prepared.candidate.summary,chapters,37),'ordinary projection accepted CB')
expect(Candidate.project_cb(point,prepared.candidate.summary,chapters,37),'CB projection rejected')
local numeric=copy(point);numeric.book_id='12345'
expect(not Candidate.project_cb(numeric,prepared.candidate.summary,chapters,37),'CB projection accepted numeric book')
expect(not Candidate.project_cb(point,prepared.candidate.summary,{chapter,chapter},37),'duplicate chapter accepted')
expect(not Candidate.project_cb(point,'',chapters,37),'empty summary accepted')
local altered=copy(members);altered[path]=raw..'changed'
expect(not Worker.prepare_cb_preview(input,function() return altered end).candidate,'altered source accepted')
local location={page=1,pos=0,xpointer='synthetic-point',view_mode='page'}
local doc={file=input.file,getDocumentFileContent=function(_self,name)
    if name==Source.meta_path(11) then return metadata end
    return members[name]
end}
local account='owner-1'
local context={book_id=book.book_id,chapters=chapters,percent=37}
local worker={cancel=function() end}
function worker:start(task,callback) self.task,self.callback=task,callback;return true end
local clock=100
local cookies={wr_vid='900000',wr_skey='synthetic-cookie-value'}
local auth={vid='900000',epoch=1}
local settings={get_auth_scope=function() return auth end,auth_scope_matches=function(_self,value) return value==auth end,
    get=function(_self,key,default) return key=='cookies' and cookies or default end}
local service=Service:new{scheduler={unschedule=function() end,scheduleIn=function() end},worker={cancel=function() end},
    make_worker=function() return worker end,context={location=function() return location end},get_document=function() return doc end,
    get_book_id=function() return book.book_id end,get_account=function() return account end,get_upload_context=function() return context end,
    client={settings=settings},is_online=function() return true end,now=function() return clock end}
service.state='ready';service.result=copy(point);service.scope=service:_live()
local old_fetch=Currentness.fetch_cb
Currentness.fetch_cb=function(_client,expected)
    return {book_id=expected.book_id,chapter_uid=expected.chapter_uid,chapter_idx=expected.chapter_idx,
        raw_sha256=expected.raw_sha256,raw_bytes=expected.raw_bytes,catalog_stamp=string.rep('a',64),source_current=true,upload_verified=false}
end
local value,receipt,reason
local function fresh()
    value,receipt,reason=nil,nil,nil
    service:prepare_cb_current_preview(function(candidate,why,checked) value,reason,receipt=candidate,why,checked end)
    expect(service.preview_job~=nil,'local preparation missing')
    worker.callback({request_id=service.preview_job.request_id,candidate=prepared.candidate})
    expect(service.preview_job~=nil,'currentness worker missing')
    worker.callback(worker.task())
end
fresh()
expect(value and receipt and next(receipt)==nil and not reason,'checked candidate missing')
expect(service:is_current_cb_preview(receipt,value),'CB receipt rejected')
expect(not service:is_current_upload_preview(receipt,value),'CB receipt enabled ordinary upload')
expect(not service:upload_preview_deadline(receipt,value),'CB receipt exposed upload deadline')
expect(not service:current().summary and not service:current().receipt,'private preview entered saved position')
local changed=copy(value);changed.summary='changed'
expect(not service:is_current_cb_preview(receipt,changed),'different summary accepted')
context.percent=38;expect(not service:is_current_cb_preview(receipt,value),'changed percentage accepted');context.percent=37
cookies.wr_skey='synthetic-rotated-cookie';expect(not service:is_current_cb_preview(receipt,value),'changed credentials accepted')
cookies.wr_skey='synthetic-cookie-value'
clock=131;expect(not service:is_current_cb_preview(receipt,value),'expired receipt accepted');clock=100
account='owner-2';expect(not service:is_current_cb_preview(receipt,value),'changed account accepted');account='owner-1'
service:cancel_upload_preview();expect(not service:is_current_cb_preview(receipt,value),'cancelled receipt accepted')
local saved_upload=Currentness.fetch_cb_upload
Currentness.fetch_cb_upload=function(_client,expected,_selected,selected_remote)
    expect(selected_remote and selected_remote.chapter_offset==25,'selected remote missing')
    return {book_id=expected.book_id,chapter_uid=expected.chapter_uid,chapter_idx=expected.chapter_idx,
        raw_sha256=expected.raw_sha256,raw_bytes=expected.raw_bytes,catalog_stamp=string.rep('a',64),source_current=true,upload_verified=false}
end
local remote={book_id=book.book_id,source='web',chapter_uid='11',chapter_idx=0,chapter_offset=25,raw_percent=37,
    updated_at=123,has_chapter_index=true,has_chapter_offset=true}
service:prepare_cb_current_upload_preview(remote,function(candidate,why,checked) value,reason,receipt=candidate,why,checked end)
worker.callback({request_id=service.preview_job.request_id,candidate=prepared.candidate});worker.callback(worker.task())
expect(value and receipt and service:is_current_cb_upload_preview(receipt,value),'guarded CB upload receipt missing')
expect(service:cb_upload_preview_deadline(receipt,value)==130,'CB upload deadline invalid')
expect(not service:is_current_cb_preview(receipt,value) and not service:is_current_upload_preview(receipt,value),
    'guarded receipt escaped its dedicated CB path')
local old_receipt,old_value=receipt,value
service:prepare_cb_current_upload_preview(nil,function(candidate,why) expect(not candidate and why=='source_remote_changed') end)
expect(not service:is_current_cb_upload_preview(old_receipt,old_value),'invalid remote retained old receipt')
Currentness.fetch_cb_upload=function() error('source_currentness/remote_changed',0) end
service:prepare_cb_current_upload_preview(remote,function(candidate,why) value,reason=candidate,why end)
worker.callback({request_id=service.preview_job.request_id,candidate=prepared.candidate});worker.callback(worker.task())
expect(not value and reason=='source_remote_changed','changed remote did not reach caller')
local Native=require('weread.lib.native_read_access')
local native_capture,native_matches,first_fetch=Native.capture,Currentness.matches_cb_initial_access,Currentness.fetch_cb_initial
local native_available=true;local native={scope=auth}
Native.capture=function() return native_available and native or nil end
Currentness.matches_cb_initial_access=function(_settings,_selected,chosen) return native_available and chosen==native end
Currentness.fetch_cb_initial=function(_client,expected,_selected,initial,chosen)
    expect(initial.kind=='cb_no_chapter' and initial.book_id==book.book_id and chosen==native,'first-state binding lost')
    return {book_id=expected.book_id,chapter_uid=expected.chapter_uid,chapter_idx=expected.chapter_idx,
        raw_sha256=expected.raw_sha256,raw_bytes=expected.raw_bytes,catalog_stamp=string.rep('a',64),source_current=true,upload_verified=false}
end
local initial=assert(require('weread.lib.cb_initial_state').from({book={bookId=book.book_id,chapterUid=0,chapterOffset=0,progress=0}},book.book_id))
value,receipt,reason=nil,nil,nil
service:prepare_cb_initial_upload_preview(initial,function(candidate,why,checked) value,reason,receipt=candidate,why,checked end)
worker.callback({request_id=service.preview_job.request_id,candidate=prepared.candidate});worker.callback(worker.task())
expect(value and receipt and not reason and service:is_current_cb_initial_preview(receipt,value),'first-position source proof missing')
expect(service:cb_initial_preview_deadline(receipt,value)==130,'first-position proof deadline invalid')
expect(not service:is_current_cb_upload_preview(receipt,value) and not service:is_current_cb_preview(receipt,value)
    and not service:is_current_upload_preview(receipt,value),'first-position receipt escaped its own scope')
native_available=false
expect(not service:is_current_cb_initial_preview(receipt,value),'stale native credentials retained first-position proof')
native_available=true
service:prepare_cb_initial_upload_preview(nil,function(candidate,why) expect(not candidate and why=='source_remote_changed') end)
expect(not service:is_current_cb_initial_preview(receipt,value),'invalid first state retained old receipt')
local foreign_initial=copy(initial);foreign_initial.book_id='CB_Other'
service:prepare_cb_initial_upload_preview(foreign_initial,function(candidate,why) expect(not candidate and why=='source_remote_changed') end)
native_available=false
service:prepare_cb_initial_upload_preview(initial,function(candidate,why) value,reason=candidate,why end)
worker.callback({request_id=service.preview_job.request_id,candidate=prepared.candidate})
expect(not value and reason=='source_native_authentication_unavailable','missing native access not reported')
native_available=true
Native.capture,Currentness.matches_cb_initial_access,Currentness.fetch_cb_initial=native_capture,native_matches,first_fetch
Currentness.fetch_cb_upload=saved_upload
Currentness.fetch_cb=old_fetch
print(('cb_source_preview_spec: %d checks'):format(checks))
