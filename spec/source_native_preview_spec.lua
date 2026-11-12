package.path='./?.lua;'..package.path
local Service=require('weread.lib.source_position')
local Source=require('weread.lib.position_source')
local Identity=require('weread.lib.book_file_identity')
local Crypto=require('weread.lib.crypto')
local Currentness=require('weread.lib.source_currentness')
local Archive=require('weread.lib.source_archive')
local checks=0
local function expect(v,why) checks=checks+1;assert(v,why or ('check '..checks)) end
local function copy(v) if type(v)~='table' then return v end;local o={};for k,x in pairs(v) do o[k]=copy(x) end;return o end
local raw='\239\187\191A😀\r\n　 <tag>&amp;Raw native summary source remains unchanged.'
local book,chapters={book_id='900001',bookVersion=7},{{chapterUid=11,chapterIdx=0}}
local path='OEBPS/text/chapter.xhtml'
local rendered=require('weread.lib.content').txt_to_xhtml(raw)
local root=Identity.encode(book,chapters,Identity.capture(book),Crypto.sha256_hex(rendered));local identity=assert(Identity.decode(root))
local source=assert(Source.capture(book,chapters[1],raw,'web_txt'))
local meta=assert(Source.bind(source,identity,path,Crypto.sha256_hex(rendered)))
local members={[Identity.PATH]=root,[Source.path_meta_path(path)]=meta,[Source.raw_path(source.raw_sha256)]=raw,[path]=rendered}
local old_archive,old_run=Archive.read,Currentness.run_txt
Archive.read=function() return members end
local doc={file='/synthetic.epub',getDocumentFileContent=function(_self,name)
    expect(name==Identity.PATH or name==Source.meta_path('11') or name==Source.path_meta_path(path),'UI read whole source')
    return name==Source.meta_path('11') and meta or members[name]
end}
local point={book_id='900001',chapter_uid='11',chapter_offset=2,file_id=identity.file_id,book_version=7,raw_sha256=source.raw_sha256,
    render_path=path,basis='raw_txt_utf16',upload_verified=false}
local scope={vid='900000',epoch=1};local cookies={wr_vid='900000',wr_skey='synthetic-cookie-value'}
local settings={get_auth_scope=function() return scope end,auth_scope_matches=function(_self,v) return v==scope end,
    get=function(_self,key,default) return key=='cookies' and cookies or default end}
local worker={cancel=function() end};function worker:start(task,callback) self.task,self.callback=task,callback;return true end
local context={book_id='900001',chapters=chapters,percent=37};local clock,online=100,true
local service=Service:new{scheduler={scheduleIn=function() end,unschedule=function() end},client={settings=settings},
    make_worker=function() return worker end,get_upload_context=function() return context end,
    get_document=function() return doc end,get_book_id=function() return '900001' end,get_account=function() return '900000' end,
    context={location=function() return {page=1,pos=0,xpointer='synthetic',view_mode='page'} end},
    now=function() return clock end,is_online=function() return online end}
local returned,reason,receipt,calls
local function run_result(_client,expected)
    local check=copy(expected);check.catalog_stamp=string.rep('a',64);check.source_current=true;check.upload_verified=false;check.basis='raw_txt_utf16'
    return {check=check}
end
Currentness.run_txt=run_result
local function finish() local callback,task=worker.callback,worker.task;callback(task()) end
local function start()
    service.state='ready';service.result=copy(point);service.scope=service:_live()
    returned,reason,receipt,calls=nil,nil,nil,0
    service:prepare_current_native_preview(function(v,why,token) returned,reason,receipt=v,why,token;calls=calls+1 end)
    expect(service.preview_job~=nil);finish();expect(service.preview_job~=nil,'fresh read worker not started')
end
start();clock=110;finish()
expect(calls==1 and returned and receipt and next(receipt)==nil)
expect(returned.raw_percent==37 and returned.chapter_idx==0 and returned.upload_verified==false)
expect(service:is_current_native_preview(receipt,returned) and service:native_preview_deadline(receipt,returned)==130,'local deadline extended')
expect(not service:is_current_native_preview({},returned),'forged online receipt')
local modified=copy(returned);modified.summary='changed';expect(not service:is_current_native_preview(receipt,modified))
clock=131;expect(not service:is_current_native_preview(receipt,returned));clock=100
for _i,change in ipairs({'catalog','percent','auth','point','file','offline'}) do
    start()
    if change=='catalog' then chapters[1].chapterIdx=1 elseif change=='percent' then context.percent=38
    elseif change=='auth' then cookies.wr_skey='synthetic-rotated-cookie'
    elseif change=='point' then service.result.chapter_offset=4 elseif change=='file' then doc.file='/other.epub' else online=false end
    finish();expect(calls==0,'stale fresh result delivered')
    chapters[1].chapterIdx=0;context.percent=37;cookies.wr_skey='synthetic-cookie-value';doc.file='/synthetic.epub';online=true
end
for _i,change in ipairs({{basis='filtered_xhtml_utf16'},{raw_bytes=999},{catalog_stamp='bad'}}) do
    Currentness.run_txt=function(client,expected)
        local result=run_result(client,expected);for k,v in pairs(change) do result.check[k]=v end;return result
    end
    start();finish();expect(calls==1 and not returned and reason=='source_currentness_unavailable')
end
Currentness.run_txt=function() return {error='source_web_expired'} end
start();finish();expect(calls==1 and reason=='source_authentication_unavailable','401 requested no login handling')
local renewals=0
service.recovery={cancel=function() end,start=function(_self,_id,_access,_guard,callback) renewals=renewals+1;callback({});return true,{} end}
start();finish();expect(renewals==1 and service.preview_job,'fresh 401 did not restart after one recovery')
finish();finish();expect(calls==1 and reason=='source_authentication_unavailable' and renewals==1,'second401 renewed again')
online=false;calls=0;service:prepare_current_native_preview(function(v,why) expect(not v and why=='offline');calls=calls+1 end)
expect(calls==1 and not service.preview_job)
online=true;service.state='ready';service.result=copy(point);service.scope=service:_live();calls=0
service:prepare_current_native_preview(function(v,why) expect(not v and why=='offline');calls=calls+1 end)
online=false;finish();expect(calls==1 and not service.preview_job,'offline transition launched source HTTP worker')
Archive.read,Currentness.run_txt=old_archive,old_run
print(('source_native_preview_spec: %d checks'):format(checks))
