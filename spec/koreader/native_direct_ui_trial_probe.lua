-- Private, supervised ReaderUI round trip. No screenshots or private logs.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
assert(os.getenv('WEREAD_DIRECT_OWNER_TMPFS')=='1')
package.path=assert(arg[1])..'/?.lua;'..package.path
G_reader_settings=require('luasettings'):wrap({});G_defaults=require('luadefaults'):open()
local Device=require('device');require('document/canvascontext'):init(Device)
local json=require('json');local size=assert(tonumber(io.stdin:read('*l')))
assert(size>0 and size<=262144);local input=json.decode(assert(io.stdin:read(size)));local trial=assert(input.trial)
local txt=input.plain_text==true
assert(not txt or input.book_version==0)
_G._direct_trial_error_token=trial.rpc_token
local ffi=require('ffi');local parent=tonumber(ffi.C.getpid());local sequence=1
local function rpc(kind,seq,extra)
    local value=extra or {};value.kind,value.seq=kind,seq
    local raw=json.encode(value);assert(#raw<16000)
    io.stdout:write('\nWEREAD_NATIVE_THOUGHT_'..trial.rpc_token..'_STEP='..raw..'\n');io.stdout:flush()
    local line=assert(io.stdin:read('*l'));assert(#line<=16384);local answer=json.decode(line)
    assert(answer.kind==kind and answer.seq==seq and answer.ok==true,'direct_ui_trial/rejected')
end
local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/'))
local scope={vid=input.credentials.vid,epoch=1}
local settings={data_dir=home,cache_dir=home,mock_endpoint=input.mock_endpoint,get=function(_,key,default)
    if key=='cookies' then return input.web_cookies end
    if key=='account' then return {user_vid=scope.vid} end
    if key=='sync' and (trial.timed or trial.closed) then return {upload_interval_minutes=1,upload_on_close=trial.closed==true} end
    return default
end,get_book=function() return nil end,get_auth_scope=function() return scope end,
    auth_scope_matches=function(_,value) return value==scope end}
local store={read=function() return input.credentials,1,nil,false end}
local Access=require('weread.lib.native_read_access');local capture=Access.capture
Access.capture=function(s,existing) return capture(s,existing or store) end
local client=require('weread.lib.client'):new(settings);local request=client.request
local service,metadata,anchor
local P=require('weread.lib.native_position_protocol');local Contract=require('weread.lib.native_position_contract')
local function diagnostic(value)
    local file=assert(io.open(home..'/trial-diagnostic','ab'));file:write(value..'\n');file:close()
end
local State=require('weread.lib.native_cloud_state');local original_snapshot=State.snapshot
State.snapshot=function(...)
    local ok,value=pcall(original_snapshot,...)
    if not ok then
        local reason=type(value)=='string' and value:match('^native_position/([a-z_]+)$')
        diagnostic(({response=true,point=true,counts=true})[reason] and 'snapshot_'..reason or 'snapshot_error')
        if reason=='point' then
            local raw,id=...;local Remote=require('weread.lib.remote_progress')
            local p=Remote.project(raw,id,'native');local node=Remote.node(raw,id)
            if not node or not P.summary(node.summary) then diagnostic('point_summary')
            elseif not p or not P.id(p.book_id) or not P.id(p.chapter_uid) then diagnostic('point_identity')
            elseif not P.integer(p.chapter_idx,0,1000000) then diagnostic('point_index')
            elseif not P.integer(p.chapter_offset,0,2147483647) then diagnostic('point_offset')
            elseif type(p.raw_percent)~='number' or p.raw_percent<0 or p.raw_percent>100 then diagnostic('point_percent')
            else diagnostic('point_other') end
        end
        error('direct_ui_trial/snapshot',0)
    end
    return value
end
local Shelf=require('weread.lib.shelf_flag_change_contract');local original_shelf_hash=Shelf.state_hash
Shelf.state_hash=function(...)
    local ok,value=pcall(original_shelf_hash,...)
    if not ok then diagnostic('shelf_error');error('direct_ui_trial/shelf',0) end
    if metadata and value~=metadata.shelf_sha256 then diagnostic('shelf_changed') end
    return value
end
local Auth=require('weread.lib.native_authorization');local original_native_request=Auth._request
Auth._request=function(self,stage,...)
    local ok,value=pcall(original_native_request,self,stage,...)
    if not ok then
        local allowed={position_metadata=true,position_progress=true,position_feature=true,position_write=true,shelf=true}
        diagnostic(allowed[stage] and 'auth_'..stage or 'auth_other');error('direct_ui_trial/native_request',0)
    end
    return value
end
client.request=function(self,options)
    local url,headers=options.url,options.headers or {};local native='https://i.weread.qq.com';local web='https://weread.qq.com'
    assert(options.skip_cookie and options.persist_response_cookies==false and options.sensitive)
    local writing=url==native..'/book/read' and options.method=='POST'
    if writing then
        assert(tonumber(ffi.C.getpid())~=parent and service and metadata and (sequence==1 or sequence==2))
        assert(headers.vid==scope.vid and headers.accessToken==input.credentials.accessToken and not headers.Cookie)
        local row=assert(service.journal:read());assert(row.phase=='pending' and Contract.valid(row.metadata))
        local wanted=sequence==1 and metadata.desired or metadata.before
        assert(P.equal(row.metadata.desired,wanted) and row.metadata.source_sha256==input.source_sha256)
        local payload=json.decode(options.body)
        assert(payload.bookId==input.book_id and payload.chapterUid==tonumber(input.uid) and payload.readingTime==0
            and payload.chapterOffset==wanted.chapter_offset and payload.summary==wanted.summary)
        rpc(trial.armed and 'claim' or 'dry_body',sequence,{body=payload})
        if not trial.armed then error('direct_ui_trial/blocked',0) end
        local sink,chunks,total=options.sink,{},0
        options.sink=function(chunk)
            if chunk then total=total+#chunk;if total<=65536 then chunks[#chunks+1]=chunk end end
            return sink(chunk)
        end
        local a,b,c=request(self,options)
        local raw=type(a)=='string' and a or table.concat(chunks)
        local ok,ack=pcall(json.decode,raw)
        if ok and type(b)=='number' and b>=200 and b<300 and P.confirmed(ack) then rpc('ack',sequence) end
        return a,b,c
    elseif url==native..'/book/info?bookId='..input.book_id or url==native..'/book/getProgress?bookId='..input.book_id
        or url==native..'/shelf/sync' or url==native..'/feature?synckey=0' then assert(options.method=='GET')
    elseif url==native..'/book/chapterInfos' then
        local value=json.decode(options.body);assert(options.method=='POST' and #value.bookIds==1 and value.bookIds[1]==input.book_id
            and value.synckeys[1]==0 and value.updateTimes[1]==0 and value.maxfreeIdx[1]==0)
    elseif url:find(native..'/book/chapterdownload?',1,true)==1 then
        local chapter=txt and 'chapters='..input.uid..'&bookType=txt&bookVersion=0&'
            or 'chapters=0%2C'..input.uid..'&'
        assert(options.method=='GET' and url:find('bookId='..input.book_id..'&',1,true)
            and url:find(chapter,1,true) and url:find('stopAutoPayWhenBNE=1',1,true) and url:find('preview=0',1,true))
    elseif url==web..'/api/userInfo?userVid='..scope.vid then assert(options.method=='GET')
    elseif url==web..'/web/book/chapterInfos' then
        local value=json.decode(options.body);assert(options.method=='POST' and #value.bookIds==1 and value.bookIds[1]==input.book_id)
        for key in pairs(value) do assert(key=='bookIds') end
    elseif url:find(web..'/web/book/getProgress?',1,true)==1 then
        assert(options.method=='GET' and url:find('bookId='..input.book_id..'&',1,true))
    elseif url==require('weread.lib.protocol').reader_url(input.book_id,input.uid) then assert(options.method=='GET')
    elseif url==web..'/web/book/chapter/e_0'
        or txt and (url==web..'/web/book/chapter/t_0' or url==web..'/web/book/chapter/t_1')
        or not txt and (url==web..'/web/book/chapter/e_1' or url==web..'/web/book/chapter/e_3') then
        local value=json.decode(options.body);local proto=require('weread.lib.protocol')
        assert(options.method=='POST' and value.b==proto.e(input.book_id) and value.c==proto.e(input.uid)
            and value.sc==1 and value.prevChapter==false and value.st==0)
    else error('direct_ui_trial/unexpected_request',0) end
    if url:find(native,1,true)==1 then assert(headers.vid==scope.vid and headers.accessToken==input.credentials.accessToken) end
    return request(self,options)
end
local UI=require('ui/uimanager');local socket=require('socket');local Reader=require('apps/reader/readerui')
if trial.closed then UI:show(require('ui/widget/widget'):new{}) end
local function wait(predicate)
    local deadline=socket.gettime()+150
    while not predicate() do assert(socket.gettime()<deadline,'direct_ui_trial/timeout');UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01) end
end
Reader:showReader(input.path);wait(function() return Reader.instance and Reader.instance.document end)
local reader=Reader.instance;local doc=reader.document
if input.start_page>1 then
    assert(reader.rolling and doc:getPageCount()>=input.start_page)
    reader.rolling:onGotoPage(input.start_page);UI:forceRePaint()
end
local entry=assert(require('weread.lib.native_direct_cache').identify(settings,scope.vid,input.path,function() return true end))
assert(entry.book_id==input.book_id and entry.chapter_uid==input.uid and entry.source_sha256==input.source_sha256)
local library=require('weread.lib.library_db'):new(settings)
local host={ui=reader,settings=settings,client=client,library_db=library,_reader_session_gen=1,isNetworkConnected=function() return true end,
    showBusy=function(self,label,cancel) self.busy_message=require('ui/widget/infomessage'):new{text=label,callback=cancel};UI:show(self.busy_message) end,
    closeBusy=function(self) UI:close(self.busy_message);self.busy_message=nil end,
    showInfo=function(self,message) self.checked_message=message end,
    showTransientInfo=function(self,message) self.transient_message=message end}
local worker=require('weread.lib.memory_worker'):new{scheduler=UI,codec=client,max_bytes=65536,timeout=140}
local preview
host._native_direct_position_worker={cancel=function() worker:cancel() end,start=function(_,task,callback)
    local ctx=assert(host._native_direct_position);anchor={text=ctx.input.text,point_offset=ctx.input.point_offset}
    return worker:start(task,function(value)
        if (trial.timed or trial.closed) and value.preview and not ctx.automatic then preview=value.preview end
        callback(value)
    end)
end}
local Service=require('weread.lib.native_position_service');local start=Service.start
local trial_finished=false
Service.start=function(self,value,guard,callback)
    assert(sequence==1 and Contract.valid(value) and anchor)
    assert(not trial.closed or not reader.document,'direct_ui_trial/reader_still_open')
    service,metadata=self,value;self.task_options.zone=trial.time_zone
    rpc('plan',1,{metadata=value,anchor=anchor})
    return start(self,value,guard,function(result,token)
        _G._direct_trial_outcome=result.kind;_G._direct_trial_readbacks=result.readbacks
        callback(result,token)
        trial_finished=true
    end)
end
assert(require('weread.ui.reader_navigation').onShowWeReadQuickMenu(host))
local upload_button
wait(function()
    local top=UI:getTopmostVisibleWidget()
    upload_button=top and type(top.getButtonById)=='function' and top:getButtonById('native_upload_position')
    return upload_button or host.checked_message~=nil
end)
assert(upload_button and upload_button.enabled~=false,'direct_ui_trial/menu')
upload_button:onTapSelectButton()
wait(function() return host.checked_message~=nil or host._native_direct_position and host._native_direct_position.confirm end)
assert(host._native_direct_position and host._native_direct_position.confirm,'direct_ui_trial/confirmation')
if trial.timed or trial.closed then
    local ctx=host._native_direct_position;local p=assert(preview)
    local initial={book_id=entry.book_id,before=p.before,desired=p.desired,counts=p.counts,version=p.version,
        shelf_sha256=p.shelf_sha256,source_sha256=p.source_sha256,file_id=p.file_id,basis=p.basis}
    -- The real manual confirmation path is covered separately. Seed only the
    -- independently checked cloud baseline here so this trial needs two writes.
    ctx.confirm.cancel_callback()
    local Interval=require('weread.lib.native_direct_interval')
    assert(Interval.arm_session(host,entry,ctx,initial,'before'))
    local timer=assert(host._native_direct_interval)
    -- Route real ReaderUI events to WeRead's installed lifecycle. The
    -- ordinary reader's unrelated services are inactive in this isolated host.
    local Lifecycle=require('weread.lib.reader_lifecycle')
    local function inactive() end
    host.progress_sync={on_page_update=inactive,prepare_close=inactive,on_close_document=inactive}
    host.downloader={cancelPrefetch=inactive}
    host.read_report={on_close_document=inactive}
    host._removeReaderHighlightTapGuard=Lifecycle._removeReaderHighlightTapGuard
    host._teardownThoughtInterception=inactive
    host._teardownXPointerOverlayPrototype=inactive
    local page_event,close_event=false,false
    reader:registerModule(nil,require('ui/widget/container/inputcontainer'):new{
        onPageUpdate=function()
            Lifecycle.onPageUpdate(host)
            page_event=true
        end,
        onPosUpdate=function()
            Lifecycle.onPosUpdate(host)
            page_event=true
        end,
        onCloseDocument=function()
            Lifecycle.onCloseDocument(host)
            close_event=true
        end,
    })
    assert(reader.rolling and doc:getPageCount()>input.start_page)
    reader.rolling:onGotoPage(input.start_page+1);UI:forceRePaint()
    assert(page_event and timer.dirty and timer.task and timer.due,'direct_ui_trial/page_event')
    if trial.closed then
        local Context=require('weread.lib.source_context');local original_capture=Context.capture
        Context.capture=function(...)
            local value=original_capture(...)
            if value and not value.error then anchor={text=value.text,point_offset=value.point_offset} end
            return value
        end
        local closed=false
        for _,name in ipairs({'getCurrentPage','getCurrentPos','getXPointer','getPageXPointer','getNormalizedXPointer',
            'getDocumentFileContent','getNextVisibleChar','getPrevVisibleChar','getTextFromXPointers'}) do
            local original=doc[name]
            if original then doc[name]=function(self,...)
                assert(not closed,'direct_ui_trial/closed_document');return original(self,...)
            end end
        end
        reader:onClose(false);closed=true;Context.capture=original_capture
        assert(close_event and not reader.document and not host._native_direct_interval
            and host._reader_session_gen==2,'direct_ui_trial/close_event')
        wait(function() return trial_finished or host.transient_message~=nil end)
        assert(trial_finished,'direct_ui_trial/close_incomplete')
        if trial.armed then assert(not host.transient_message) else assert(host.transient_message) end
    else
        if not trial.natural then
            local due=timer.due;timer.now=function() return due end
            local fire=timer.task;UI:unschedule(fire);fire()
        end
        wait(function() return not timer.task and not timer.attempt end)
        if trial.armed then assert(host._native_direct_interval==timer and not timer.dirty)
        else assert(not host._native_direct_interval and host.transient_message) end
    end
else
    host._native_direct_position.confirm.ok_callback()
    wait(function() return host.checked_message~=nil end)
end
local tr=require('weread.lib.plugin_util').tr
if not trial.armed then
    if not trial.timed and not trial.closed then assert(host.checked_message==tr('The sync result could not be confirmed. Choose sync again to review it.')) end
    local pending=assert(service:pending());assert(pending.phase=='pending')
    print('WEREAD_NATIVE_THOUGHT_'..trial.rpc_token..'_RESULT='..json.encode{result='PASS',steps=0,posts=0,blocked=true})
    return
end
if not trial.timed and not trial.closed then assert(host.checked_message==tr('Cloud reading position synced and checked.'),'direct_ui_trial/not_confirmed') end
assert(not service:pending(),'direct_ui_trial/not_retired')
rpc('verified',1);sequence=2
local Context=require('weread.lib.source_context');local Identity=require('weread.lib.book_file_identity')
local Currentness=require('weread.lib.source_currentness');local native=assert(Access.capture(settings));local web=assert(Currentness.capture(settings))
local location=not trial.closed and assert(Context.location(doc,reader.view and reader.view.view_mode or 'page')) or nil
local lfs=require('libs/libkoreader-lfs');local stat=trial.closed and assert(lfs.attributes(input.path)) or nil
local function guard()
    if trial.closed then
        local now=lfs.attributes(input.path)
        return now and now.mode=='file' and now.dev==stat.dev and now.ino==stat.ino and now.size==stat.size
            and now.modification==stat.modification and now.change==stat.change
            and Access.matches(settings,native) and Currentness.matches(settings,web)
    end
    local now=Context.location(doc,reader.view and reader.view.view_mode or 'page');local id=Identity.read_document(doc,entry.book_id)
    return reader.document==doc and Context.same_location(location,now) and id.file_id==entry.file_id
        and id.book_id==entry.book_id and id.book_version==entry.book_version
        and Access.matches(settings,native) and Currentness.matches(settings,web)
end
local restore={book_id=metadata.book_id,before=metadata.desired,desired=metadata.before,counts=metadata.counts,version=metadata.version,
    shelf_sha256=metadata.shelf_sha256,source_sha256=metadata.source_sha256,file_id=metadata.file_id,basis=metadata.basis}
assert(Contract.valid(restore) and guard())
local outcome,token,done
assert(start(service,restore,guard,function(value,handle) outcome,token,done=value,handle,true end))
wait(function() return done end)
assert(outcome.kind=='confirmed' and outcome.acknowledged and token)
rpc('verified',2);assert(service:accept(token) and not service:pending())
print('WEREAD_NATIVE_THOUGHT_'..trial.rpc_token..'_RESULT='..json.encode{result='PASS',steps=2,posts=2,blocked=false})
