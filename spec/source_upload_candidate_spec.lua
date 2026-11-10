package.path='./?.lua;'..package.path
local Candidate=require('weread.lib.source_upload_candidate')
local Worker=require('weread.lib.source_position_worker')
local Service=require('weread.lib.source_position')
local Source=require('weread.lib.position_source')
local Identity=require('weread.lib.book_file_identity')
local Crypto=require('weread.lib.crypto')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message or ('check '..checks)) end
local function copy(value)
    if type(value)~='table' then return value end
    local result={};for key,item in pairs(value) do result[key]=copy(item) end;return result
end
local book,chapter={book_id='900001',bookVersion=1},{chapterUid=11,chapterIdx=0}
local chapters={chapter}
local raw='<html><body><p>ABCDEFG😀&amp;中文HIJKLMNOPQRSTUVWXYZ末尾。</p></body></html>'
local root=Identity.encode(book,chapters,Identity.capture(book),Crypto.sha256_hex(raw))
local identity=assert(Identity.decode(root))
local source=assert(Source.capture(book,chapter,raw,'web_xhtml'))
local path='OEBPS/text/chapter.xhtml'
local metadata=assert(Source.bind(source,identity,path,Crypto.sha256_hex(raw)))
local point={book_id='900001',chapter_uid='11',chapter_offset=15,basis='filtered_xhtml_utf16',upload_verified=false,
    file_id=identity.file_id,book_version=1,raw_sha256=source.raw_sha256,render_path=path}
local members={[Identity.PATH]=root,[Source.path_meta_path(path)]=metadata,[Source.raw_path(source.raw_sha256)]=raw,[path]=raw}
local input={file='/synthetic.epub',book_id='900001',chapter_uid='11',identity=identity,metadata=metadata,
    render_path=path,target=copy(point),chapters=chapters,percent=37,request_id=1}
local prepared=Worker.prepare_upload(input,function() return members end)
expect(prepared.candidate and prepared.candidate.chapter_offset==15,'source co became catalog words')
expect(prepared.candidate.summary=='ABCDEFG😀&中文HIJKLMNOP','twenty-scalar source summary changed')
expect(prepared.candidate.chapter_idx==0 and prepared.candidate.percent==37,'zero index or viewport percent changed')
expect(not prepared.position.summary and not prepared.position.candidate and not prepared.raw,'transient text entered persisted position')
for _i,bad in ipairs({{chapterUid=11},{chapterUid=11,chapterIdx=true},{chapterUid=11,chapterIdx=1,chapter_idx=2},
    {chapterUid=11,chapterId=22,chapterIdx=1}}) do
    expect(not Candidate.project(point,'ABCDEFGHIJKLMNOPQRST',{bad},37),'ambiguous catalog accepted')
end
expect(not Candidate.project(point,'ABCDEFGHIJKLMNOPQRST',{chapter,chapter},37),'duplicate UID accepted')
for _i,percent in ipairs({-1,101,.5,0/0,math.huge,'37',true}) do
    expect(not Candidate.project(point,'ABCDEFGHIJKLMNOPQRST',chapters,percent),'invalid percent accepted')
end
for _i,summary in ipairs({'',string.rep('A',21),'A B','A\nB','\237\160\128'}) do
    expect(not Candidate.project(point,summary,chapters,37),'unbounded/invalid summary accepted')
end
for _i,co in ipairs({0,23,25,999}) do
    local frame=copy(input);frame.target.chapter_offset=co
    expect(not Worker.prepare_upload(frame,function() return members end).candidate,'invalid source boundary guessed')
end
local changed=copy(members);changed[path]=raw..'changed'
expect(not Worker.prepare_upload(input,function() return changed end).candidate,'archive tampering accepted')
-- A separate preparation worker can never cancel or contaminate the capture
-- worker. No candidate is retained in current() or in the source change event.
local location={page=1,pos=0,xpointer='synthetic-point',view_mode='page'}
local doc={file=input.file,getDocumentFileContent=function(_self,name)
    if name==Source.meta_path(11) then return metadata end
    return members[name]
end}
local account='owner-1'
local context={book_id='900001',chapters=chapters,percent=37}
local worker={cancel=function(self) self.cancelled=true end}
function worker:start(task,callback) self.task,self.callback=task,callback;return true end
local service=Service:new{scheduler={unschedule=function() end},worker={cancel=function() end},
    make_worker=function() return worker end,context={location=function() return location end},
    get_document=function() return doc end,get_book_id=function() return '900001' end,
    get_account=function() return account end,get_upload_context=function() return context end}
service.state='ready';service.result=copy(point);service.scope=service:_live()
local callback_count,value=0,nil
local function start()
    service:prepare_upload_preview(function(candidate) callback_count=callback_count+1;value=candidate end)
    expect(service.preview_job~=nil,'preview worker not launched')
    prepared.request_id=service.preview_job.request_id
end
start();worker.callback(prepared)
expect(callback_count==1 and value and value.summary==prepared.candidate.summary,'current candidate was not delivered')
expect(not service:current().summary and not service:current().candidate,'summary entered public position')
value.summary='mutated';expect(not service:current().summary,'callback mutated persisted position')
for _i,bad in ipairs({true,4,'private worker diagnostic',{request_id=999,candidate=prepared.candidate},
    {request_id=1,candidate={summary='bad'}}}) do
    start();worker.callback(bad)
    expect(not value,'malformed or unowned worker result accepted')
end
local accepted_count=callback_count
start();local old_callback=worker.callback;context.percent=38;old_callback(prepared)
expect(callback_count==accepted_count+1 and not value,'changed display progress accepted stale candidate')
accepted_count=callback_count
context.percent=37
start();old_callback=worker.callback;account='owner-2';old_callback(prepared)
expect(callback_count==accepted_count,'old account committed candidate')
account='owner-1'
start();old_callback=worker.callback;point.chapter_offset=16;service.result=copy(point);old_callback(prepared)
expect(callback_count==accepted_count,'same-page source point movement accepted stale candidate')
point.chapter_offset=15;service.result=copy(point)
start();old_callback=worker.callback;service:stop();old_callback(prepared)
expect(callback_count==accepted_count and worker.cancelled and not service.preview_job,'closed scope retained candidate worker')
local pending_callback
service.check=function(_self,callback) pending_callback=callback;return true end
service:prepare_upload_preview(function() error('cancelled preparation callback resumed') end)
service:cancel_upload_preview();pending_callback(point)
expect(not service.preview_job,'cancelled preview launched after a deferred source check finished')
-- Explicit fresh reads remain separate from the local preparation and do not
-- make a receipt portable across time, scope, account or reader movement.
local Currentness=require('weread.lib.source_currentness')
local online,clock,reads=true,100,0
local cookies={wr_vid='900000',wr_skey='synthetic-cookie-value'}
local auth={vid='900000',epoch=1}
local settings={get_auth_scope=function() return auth end,auth_scope_matches=function(_self,value_) return value_==auth end,
    get=function(_self,key,default) return key=='cookies' and cookies or default end}
service=Service:new{scheduler={unschedule=function() end,scheduleIn=function() end},worker={cancel=function() end},make_worker=function() return worker end,
    context={location=function() return location end},get_document=function() return doc end,get_book_id=function() return '900001' end,
    get_account=function() return account end,get_upload_context=function() return context end,
    client={settings=settings},is_online=function() return online end,now=function() return clock end}
service.state='ready';service.result=copy(point);service.scope=service:_live()
local fetch=Currentness.fetch
Currentness.fetch=function(_client,expected)
    reads=reads+1
    return {book_id=expected.book_id,chapter_uid=expected.chapter_uid,chapter_idx=expected.chapter_idx,
        raw_sha256=expected.raw_sha256,raw_bytes=expected.raw_bytes,catalog_stamp=string.rep('a',64),source_current=true,upload_verified=false}
end
local receipt,reason,received
local function fresh()
    value,receipt,reason,received=nil,nil,nil,false
    service:prepare_current_upload_preview(function(candidate,why,checked) value,reason,receipt,received=candidate,why,checked,true end)
    expect(service.preview_job~=nil,'freshness did not first prepare a local candidate')
    worker.callback({request_id=service.preview_job.request_id,candidate=prepared.candidate})
    expect(service.preview_job~=nil,'freshness did not launch its separate read worker')
end
local function finish() worker.callback(worker.task()) end
fresh();finish()
expect(received and value and receipt and next(receipt)==nil and reads==1,'fresh checked candidate was not delivered')
expect(service:is_current_upload_preview(receipt,value),'owned fresh receipt was rejected')
expect(not service:is_current_upload_preview({},value),'forged receipt was accepted')
local changed_candidate=copy(value);changed_candidate.summary='changed'
expect(not service:is_current_upload_preview(receipt,changed_candidate),'receipt granted a different summary')
expect(not service:current().summary and not service:current().receipt,'fresh source content entered public state')
clock=131;expect(not service:is_current_upload_preview(receipt,value),'expired receipt remained current')
clock=99;expect(not service:is_current_upload_preview(receipt,value),'backwards clock accepted receipt')
clock=100;context.percent=38;expect(not service:is_current_upload_preview(receipt,value),'changed percent accepted receipt')
context.percent=37;chapters[1].chapterIdx=1;expect(not service:is_current_upload_preview(receipt,value),'changed chapter index accepted receipt')
chapters[1].chapterIdx=0
cookies.wr_skey='synthetic-rotated-cookie';expect(not service:is_current_upload_preview(receipt,value),'changed credentials accepted receipt')
cookies.wr_skey='synthetic-cookie-value'
online=false;local previous_reads=reads
service:prepare_current_upload_preview(function(candidate,why) expect(not candidate and why=='offline','offline request was not refused') end)
expect(reads==previous_reads and not service.preview_job,'offline request dispatched reads')
online=true;expect(not service:is_current_upload_preview(receipt,value),'cancelled receipt survived')
fresh();clock=131;finish()
expect(received and not value and reason=='source_currentness_unavailable','slow fresh check accepted an expired snapshot')
clock=100;fresh();cookies.wr_skey='synthetic-rotated-cookie';finish()
expect(not received,'late changed-account check called its consumer')
cookies.wr_skey='synthetic-cookie-value';fresh();local callback=worker.callback
service:pause('suspend');callback({request_id=service.sequence,check={}})
expect(not received and not service.preview_job,'suspend retained a fresh worker')
service.pauses={};service.state='ready';service.result=copy(point);service.scope=service:_live()
fresh();worker.callback({request_id=service.sequence,check={source_current=true}})
expect(received and not value and reason=='source_currentness_unavailable','malformed remote proof was accepted')
fresh();finish();local old_receipt,old_candidate=receipt,value
service.result.chapter_offset=16
expect(not service:is_current_upload_preview(old_receipt,old_candidate),'same-page point change retained receipt')
service.result=copy(point);fresh();finish()
service.get_retained=function() local held=copy(point);held.retained_source_target=true;return held end
service:on_view_changed(true)
expect(not service:is_current_upload_preview(receipt,value),'held-target event revived a previous receipt')
service.get_retained=nil;service.task=nil
service.result=copy(point);fresh();finish();service:stop()
expect(not service:is_current_upload_preview(receipt,value),'closed reader retained fresh receipt')
Currentness.fetch=fetch
print(('source_upload_candidate_spec: %d checks'):format(checks))
