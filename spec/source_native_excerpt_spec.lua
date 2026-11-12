package.path='./?.lua;'..package.path
local Service=require('weread.lib.source_position')
local Worker=require('weread.lib.source_position_worker')
local Source=require('weread.lib.position_source')
local Identity=require('weread.lib.book_file_identity')
local Crypto=require('weread.lib.crypto')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message or ('check '..checks)) end
local function copy(v) if type(v)~='table' then return v end;local out={};for k,x in pairs(v) do out[k]=copy(x) end;return out end
local book,chapter={book_id='900001',bookVersion=7},{chapterUid=11}
local raw='\239\187\191A\r\n　 <tag>&amp;😀é末尾'
local path='OEBPS/text/chapter.xhtml'
local rendered=require('weread.lib.content').txt_to_xhtml(raw)
local root=Identity.encode(book,{chapter},Identity.capture(book),Crypto.sha256_hex(rendered))
local identity=assert(Identity.decode(root))
local source=assert(Source.capture(book,chapter,raw,'web_txt'))
local metadata=assert(Source.bind(source,identity,path,Crypto.sha256_hex(rendered)))
local members={[Identity.PATH]=root,[Source.path_meta_path(path)]=metadata,
    [Source.raw_path(source.raw_sha256)]=raw,[path]=rendered}
local location={page=1,pos=0,xpointer='synthetic',view_mode='page'}
local doc={file='/synthetic.epub',getDocumentFileContent=function(_self,name)
    expect(name==Identity.PATH or name==Source.meta_path('11') or name==Source.path_meta_path(path),'UI read a body member')
    return name==Source.meta_path('11') and metadata or members[name]
end}
local point={book_id='900001',chapter_uid='11',chapter_offset=6,file_id=identity.file_id,book_version=7,
    raw_sha256=source.raw_sha256,render_path=path,basis='raw_txt_utf16',upload_verified=false}
local worker={cancel=function(self) self.cancelled=true end}
local failed=false
function worker:start(task,callback) self.task,self.callback=task,callback;return not failed end
local account,clock,busy,available='owner',100,false,true
local service=Service:new{scheduler={scheduleIn=function() end,unschedule=function() end},
    worker={cancel=function() end},make_worker=function() return worker end,
    context={location=function() return copy(location) end},get_document=function() return doc end,
    get_book_id=function() return '900001' end,get_account=function() return account end,
    now=function() return clock end,is_busy=function() return busy end,can_prepare=function() return available end}
local function reset()
    service.pauses={};service.state='ready';service.result=copy(point);service.scope=service:_live()
end
local packet,reason,receipt,calls
local function start()
    reset();packet,reason,receipt,calls=nil,nil,nil,0
    expect(service:prepare_native_excerpt(function(value,why,token) packet,reason,receipt=value,why,token;calls=calls+1 end))
end
local function outcome()
    return Worker.prepare_native_excerpt({file=doc.file,book_id=point.book_id,chapter_uid=point.chapter_uid,
        identity=identity,metadata=metadata,render_path=path,target=copy(point),request_id=service.preview_job.request_id},
        function() return members end)
end
start();worker.callback(outcome())
expect(calls==1 and packet and receipt and next(receipt)==nil,'owned preparation failed')
expect(packet.excerpt.text=='<tag>&amp;😀é末尾' and packet.position.book_version==7,'literal bytes or local version changed')
expect(service:is_current_native_excerpt(receipt,packet),'live opaque receipt rejected')
expect(not service:is_current_native_excerpt({},packet),'forged receipt accepted')
expect(not service:current().excerpt and not service:current().summary,'text entered retained source state')
local pinned,token=copy(packet),receipt
packet.excerpt.text='mutated';expect(not service:is_current_native_excerpt(token,packet))
expect(service:is_current_native_excerpt(token,pinned),'caller mutated receipt-owned packet')
clock=131;expect(not service:is_current_native_excerpt(token,pinned),'expired receipt accepted')
clock=99;expect(not service:is_current_native_excerpt(token,pinned),'backwards clock accepted')
clock=100
for _i,change in ipairs({{text='A\0B'},{text='\237\160\128'},{text=string.rep('a',31)},
    {co=7},{end_co=999},{scalars=999},{basis='filtered_xhtml_utf16'},{upload_verified=true},{raw='private'}}) do
    start();local result=outcome();for k,v in pairs(change) do result.excerpt[k]=v end
    worker.callback(result);expect(calls==1 and not packet and reason=='candidate_unavailable','malformed excerpt accepted')
end
for _i,key in ipairs({'request_id','book_id','chapter_uid','chapter_offset','file_id','book_version','raw_sha256','basis','upload_verified'}) do
    start();local result=outcome()
    if key=='request_id' then result.request_id=0 else result.position[key]='foreign' end
    worker.callback(result);expect(not packet and calls==1,'foreign worker result accepted')
end
start();local cb,result=worker.callback,outcome();clock=131;cb(result)
expect(not packet and reason=='candidate_unavailable','slow worker accepted');clock=100
for _i,change in ipairs({'account','page','point','file','busy','memory'}) do
    start();cb,result=worker.callback,outcome()
    if change=='account' then account='other'
    elseif change=='page' then location.page=2
    elseif change=='point' then service.result.chapter_offset=7
    elseif change=='file' then doc.file='/other.epub'
    elseif change=='busy' then busy=true
    else available=false end
    cb(result);expect(calls==0 and not packet,'stale reader result delivered')
    account='owner';location.page=1;doc.file='/synthetic.epub';busy=false;available=true
end
start();cb,result=worker.callback,outcome();service:pause('suspend');cb(result)
expect(calls==0 and worker.cancelled and not service.preview_job,'suspended scope survived')
start();worker.callback(outcome());pinned,token=packet,receipt
service:stop();expect(not service:is_current_native_excerpt(token,pinned),'closed receipt survived')
start();cb,result=worker.callback,outcome();service:cancel_upload_preview();cb(result)
expect(calls==0,'cancelled worker delivered')
failed=true;start();expect(calls==1 and reason=='worker_unavailable' and not service.preview_job);failed=false
reset();service.result.basis='filtered_xhtml_utf16';calls=0
service:prepare_native_excerpt(function(value,why) expect(not value and why=='source_unsupported');calls=calls+1 end)
expect(calls==1,'XHTML entered native TXT preparation')
local pending
service.check=function(_self,callback) pending=callback;return true end
service:prepare_native_excerpt(function() error('cancelled deferred callback delivered') end)
service:cancel_upload_preview();pending(copy(point));expect(not service.preview_job)
print(('source_native_excerpt_spec: %d checks'):format(checks))
