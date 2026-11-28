package.path='./?.lua;'..package.path
local Handoff=require('weread.lib.cloud_source_handoff')
local Cloud=require('weread.lib.source_cloud')
local Identity=require('weread.lib.book_file_identity')
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local id='900001'
local root=Identity.encode({book_id=id},{1},Identity.capture({book_id=id}),string.rep('a',64))
local identity=assert(Identity.decode(root))
local remote={book_id=id,chapter_uid='2',chapter_offset=10,percent=20,raw_sha256=string.rep('b',64),raw_bytes=200,
    basis='filtered_xhtml_utf16',upload_verified=false}
local function fixture()
    local state={now=100,calls=0,valid=true}
    local scope={vid='900000',epoch=1}
    local settings={get_auth_scope=function() return scope end,auth_scope_matches=function() return state.valid end,
        get=function(_self,key,default) return key=='cookies' and {wr_vid='900000',wr_skey='synthetic-transfer-cookie'} or default end}
    local sync={navigation_generation=4,generation=2,account_generation=1}
    local olddoc={file='/old.epub'}
    local host={settings=settings,_reader_session_gen=1,progress_sync=sync}
    local job={book_id=id,document=olddoc,file=olddoc.file,session=1,navigation_generation=4,access=Cloud.capture(settings)}
    host.cloud_source_request=job
    local doc={file='/next.epub',getDocumentFileContent=function() return root end}
    local next_host={settings=settings,ui={document=doc},progress_sync={navigation_generation=0},detectWeReadBook=function() return id end}
    local reader={document=doc,weread=next_host}
    local transfer=assert(Handoff.prepare(host,job,doc.file,identity,remote,function(next_value,packet,file_id,access)
        assert(next_value==next_host and packet~=remote and file_id==identity.file_id and access==job.access)
        state.calls=state.calls+1;return true
    end,function() return state.now end))
    host.cloud_source_request=nil;host._reader_session_gen=2;sync.generation=3
    return {host=host,job=job,reader=reader,next_host=next_host,state=state,scope=scope,transfer=transfer}
end
local f=fixture()
expect(f.transfer(f.reader) and f.state.calls==1,'verified target did not transfer across one document close')
expect(not f.transfer(f.reader) and f.state.calls==1,'handoff was reusable')
for _,kind in ipairs({'old_session','old_generation','old_account','old_navigation','new_navigation','account','time','clock',
    'path','document','book','identity','same_host','same_sync'}) do
    f=fixture()
    if kind=='old_session' then f.host._reader_session_gen=3
    elseif kind=='old_generation' then f.host.progress_sync.generation=4
    elseif kind=='old_account' then f.host.progress_sync.account_generation=2
    elseif kind=='old_navigation' then f.host.progress_sync.navigation_generation=5
    elseif kind=='new_navigation' then f.next_host.progress_sync.navigation_generation=1
    elseif kind=='account' then f.scope.epoch=2
    elseif kind=='time' then f.state.now=221
    elseif kind=='clock' then f.state.now=99
    elseif kind=='path' then f.reader.document.file='/other.epub'
    elseif kind=='document' then f.reader.document={file='/next.epub'}
    elseif kind=='book' then f.next_host.detectWeReadBook=function() return '900002' end
    elseif kind=='identity' then f.reader.document.getDocumentFileContent=function() return '' end
    elseif kind=='same_host' then f.reader.weread=f.host
    else f.next_host.progress_sync=f.host.progress_sync end
    expect(not f.transfer(f.reader) and f.state.calls==0,'stale handoff accepted: '..kind)
    expect(not f.transfer(f.reader),'rejected handoff was reusable: '..kind)
end
print(('cloud_source_handoff_spec: %d checks'):format(checks))
