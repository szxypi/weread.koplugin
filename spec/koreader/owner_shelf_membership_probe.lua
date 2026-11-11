-- Owner-only native preview or exactly two separately authorized data POSTs.
-- Credentials use anonymous descriptors; all other private files are tmpfs.
require('ffi').log=function() end
require('setupkoenv')
local ffi=require('ffi');require('ffi/posix_h')
local json=require('json')
local report={result='UNVERIFIED',phase='init',permit_writes=false,anonymous_credentials=false,guard_selftest=false,
    native_detail=false,preview_matches=false,native_confirmation=false,worker_heartbeat=false,cancel_no_post=false,
    status_close_cancelled=false,workers_reaped=false,credential_audit=false,local_state_preserved=false,
    roundtrip_restored=false,no_authentication_posts=false,journal_before_posts=false,native_cache_readback=false,
    shelf_books=0,profile_files_audited=0,screenshots=0,failed_line=0,denied_route=0,
    request_counts={0,0,0,0,0},post_statuses=json.decode('[]')}
local private={plan_fingerprint=string.rep('0',64),intent_digest='',final_members_digest=string.rep('0',64)}
local descriptors,seen={},{}
local counters,plugin,rpc_token
local ok,reason=pcall(function()
    local home=assert(os.getenv('KO_HOME'))
    assert(ffi.os=='Linux' and home:match('^/dev/shm/weread%-membership%-[%w_]+/profile$'))
    local source=home..'/plugins/weread.koplugin'
    local lfs=require('libs/libkoreader-lfs')
    assert(lfs.symlinkattributes(source,'mode')=='directory' and not lfs.symlinkattributes(home..'/weread'))
    local raw
    if os.getenv('WEREAD_MEMBERSHIP_HOST_STEPS')=='1' then
        local length=assert(io.stdin:read('*l'));assert(#length<=8 and length:match('^[1-9]%d*$'))
        length=tonumber(length);assert(length<=256*1024);raw=assert(io.stdin:read(length));assert(#raw==length)
    else raw=assert(io.stdin:read(256*1024+1));assert(#raw<=256*1024) end
    local input=json.decode(raw)
    if os.getenv('WEREAD_MEMBERSHIP_HOST_STEPS')=='1' then
        rpc_token=assert(input.host_steps and input.host_steps.rpc_token)
        assert(type(rpc_token)=='string' and #rpc_token==32 and rpc_token:match('^[a-f0-9]+$'))
    else assert(input.host_steps==nil) end
    assert(type(input.permit_writes)=='boolean' and input.permit_writes==(os.getenv('WEREAD_MEMBERSHIP_ARMED')=='1'))
    local grant=assert(input.credentials)
    assert(type(grant.vid)=='string' and grant.vid:match('^[1-9]%d*$'))
    local id=assert(input.book_id);assert(type(id)=='string' and id:match('^[1-9]%d*$') and #id<=20)
    if input.mock_port~=nil then
        assert(type(input.mock_port)=='number' and input.mock_port%1==0 and input.mock_port>=1 and input.mock_port<=65535
            and os.getenv('WEREAD_MEMBERSHIP_MOCK')==tostring(input.mock_port))
        assert(grant.vid=='900000' and grant.accessToken=='mock-native-access' and grant.refreshToken=='mock-native-refresh'
            and id=='900001' and grant.deviceId=='eink334691225'..string.rep('1',19))
    else assert(not os.getenv('WEREAD_MEMBERSHIP_MOCK')) end
    assert(type(input.expected_metadata)=='table' and input.expected_metadata.bookId==id)
    assert(type(input.members_digest)=='string' and #input.members_digest==64 and input.members_digest:match('^[a-f0-9]+$'))
    assert(type(input.plan_fingerprint)=='string' and #input.plan_fingerprint==64 and input.plan_fingerprint:match('^[a-f0-9]+$'))
    assert(type(input.intent_digest)=='string' and (input.permit_writes and #input.intent_digest==64
        and input.intent_digest:match('^[a-f0-9]+$') or not input.permit_writes and input.intent_digest==''))
    report.permit_writes=input.permit_writes
    private.plan_fingerprint,private.intent_digest,private.final_members_digest=input.plan_fingerprint,input.intent_digest,input.members_digest
    package.path=source..'/?.lua;'..package.path
    G_defaults=require('luadefaults'):open()
    local LuaSettings=require('luasettings')
    G_reader_settings=LuaSettings:open(home..'/settings.reader.lua')
    G_reader_settings:saveSetting('language','zh_CN');require('gettext').changeLang('zh_CN')
    local Device=require('device');require('document/canvascontext'):init(Device)
    Device.screen.shot=function() report.screenshots=report.screenshots+1;error('screenshots disabled',0) end
    local UI=require('ui/uimanager');UI:setRunForeverMode();UI:setInputTimeout(0)
    pcall(ffi.cdef,'int memfd_create(const char *, unsigned int);')
    local function anonymous(data)
        local fd=tonumber(ffi.C.memfd_create('weread-membership-probe',1));assert(fd>=0);descriptors[#descriptors+1]=fd
        local bytes='return '..require('dump')(data,nil,true);local at=0
        while at<#bytes do local n=tonumber(ffi.C.write(fd,ffi.cast('const char *',bytes)+at,#bytes-at));assert(n>0);at=at+n end
        return '/proc/self/fd/'..fd
    end
    local auth={auth_schema_version=1,auth_epoch=1,account={user_vid=grant.vid,name=''},cookies={},api_key=''}
    local scope_path=anonymous(auth)
    local saved={};for key,value in pairs(grant) do saved[key]=value end
    saved.epoch,saved.verified_at,saved.book_count=1,os.time(),input.shelf_books
    local grant_path=anonymous({revision=1,authorization=saved})
    local Settings=require('weread.lib.settings');local new_settings=Settings.new
    function Settings:new()
        local value=new_settings(self);assert(not value.mock_endpoint)
        if input.mock_port then value.mock_endpoint='http://127.0.0.1:'..input.mock_port end
        local flush=value.store.flush
        local secret_keys={'account','cookies','api_key','wr_ticket','wr_wrpa','device_fingerprint'}
        value.store.flush=function(store,...)
            local held={};for _i,key in ipairs(secret_keys) do held[key]=store.data[key];store.data[key]=nil end
            local result={pcall(flush,store,...)}
            for _i,key in ipairs(secret_keys) do store.data[key]=held[key] end
            assert(result[1]);return unpack(result,2)
        end
        for key,item in pairs(auth) do value.store:saveSetting(key,item) end
        value:set('shelf',{source='native',view_mode='list',paginated=true});value:flush()
        value.settings_file=scope_path;return value
    end
    local Credentials=require('weread.lib.native_credentials');local new_credentials=Credentials.new
    function Credentials:new(settings,...)
        local value=new_credentials(self,settings,...);value.path=grant_path
        value._write=function() report.denied_route=7;error('authentication changes disabled',0) end
        return value
    end
    report.anonymous_credentials=true
    pcall(ffi.cdef,'void *mmap(void *, unsigned long, int, int, int, long); int munmap(void *, unsigned long);')
    local memory=ffi.C.mmap(nil,128,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1));counters=ffi.cast('int *',memory)
    local parent=tonumber(ffi.C.getpid())
    local base='https://i.weread.qq.com'
    local function classify(options,armed)
        local headers=options.headers or {}
        if not options.skip_cookie or options.persist_response_cookies~=false or not options.sensitive
            or headers.vid~=grant.vid or headers.accessToken~=grant.accessToken or headers.Cookie~=nil or headers.Authorization~=nil then return nil end
        if options.method=='GET' and options.body==nil then
            if options.url==base..'/shelf/sync' then return 0 end
            if options.url==base..'/book/info?bookId='..id then return 1 end
        elseif armed and options.method=='POST' and type(options.body)=='string' then
            local parsed,body=pcall(json.decode,options.body)
            if not parsed or type(body)~='table' or type(body.bookIds)~='table' or #body.bookIds~=1 or body.bookIds[1]~=id then return nil end
            for key in pairs(body) do if key~='bookIds' then return nil end end
            for key in pairs(body.bookIds) do if key~=1 then return nil end end
            if options.url==base..'/shelf/add' then return 2 end
            if options.url==base..'/shelf/delete' then return 3 end
        end
    end
    local permitted={url=base..'/shelf/sync',method='GET',skip_cookie=true,persist_response_cookies=false,sensitive=true,
        headers={vid=grant.vid,accessToken=grant.accessToken}}
    assert(classify(permitted,false)==0)
    for _i,change in ipairs({'post','body','url','cookie','owner','token','persist'}) do
        local value={};for key,item in pairs(permitted) do value[key]=item end
        value.headers={vid=grant.vid,accessToken=grant.accessToken}
        if change=='post' then value.method='POST' elseif change=='body' then value.body='{}'
        elseif change=='url' then value.url=base..'.invalid/shelf/sync' elseif change=='cookie' then value.headers.Cookie='forbidden'
        elseif change=='owner' then value.headers.vid='0' elseif change=='token' then value.headers.accessToken='invalid' else value.persist_response_cookies=true end
        assert(classify(value,false)==nil)
    end
    for _i,operation in ipairs({'add','delete'}) do
        local value={};for key,item in pairs(permitted) do value[key]=item end
        value.url=base..'/shelf/'..operation;value.method='POST';value.body=json.encode{bookIds={id}}
        assert(classify(value,false)==nil and classify(value,true)==(_i==1 and 2 or 3))
    end
    report.guard_selftest=true
    local Client=require('weread.lib.client');local request=Client.request
    function Client:request(options)
        local index=classify(options,input.permit_writes)
        local permitted_count=index==0 and 13 or 1
        if index==nil or counters[index]>=permitted_count or tonumber(ffi.C.getpid())==parent
            or index==3 and counters[7]~=1 or index==2 and counters[3]~=0 then
            counters[4]=counters[4]+1;error('membership transport scope denied',0)
        end
        if index>=2 then
            local scope=plugin.settings:get_auth_scope()
            local record=assert(plugin.shelf_membership.journal:read(scope))
            assert(record.phase=='pending' and record.book_id==id and record.operation==(index==2 and 'add' or 'remove'))
            counters[8]=counters[8]+1
        end
        counters[index]=counters[index]+1
        local result={request(self,options)}
        if index>=2 then counters[index+3]=tonumber(result[2]) or 0 end
        return unpack(result)
    end
    local Plugin=dofile(source..'/main.lua');plugin=Plugin:new{ui={menu={registerToMainMenu=function() end}}}
    plugin.isNetworkOnline,plugin.isNetworkConnected=function() return true end,function() return true end
    plugin.fetchVisibleShelfCovers=function() end;plugin.prepareShelfProgress=function() return nil end;plugin.refreshVisibleShelfProgress=function() end
    local Task=require('weread.lib.shelf_membership_write')
    local Crypto=require('weread.lib.crypto')
    local tr=require('weread.lib.plugin_util').tr
    local socket=require('socket')
    local function observe()
        for _i,worker in ipairs({plugin.shelf_membership.worker or {},plugin.book_metadata_worker or {}}) do
            if worker.job then seen[worker.job.pid]=true end
        end
    end
    local function pump(predicate)
        local deadline=socket.gettime()+40
        while not predicate() do
            assert(socket.gettime()<deadline);observe();UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
        end
        observe()
    end
    local function file(path) local stream=assert(io.open(path,'rb'));local value=stream:read('*a');stream:close();return value end
    local sentinel={book_id=id,title=input.expected_metadata.title,progress=.12,pending_upload_position={book_id=id,chapter_uid=1,chapter_offset=7,percent=12}}
    plugin.settings:set('books',{[id]=sentinel});plugin.settings:flush()
    report.phase='detail';plugin:showBookRecord(input.expected_metadata)
    pump(function() return not plugin.book_metadata_context end)
    local detail=assert(plugin._book_detail_view)
    assert(detail.data.title==input.expected_metadata.title)
    local record=assert(plugin.settings:get_book(id))
    assert(tostring(record.book_id or record.bookId)==id)
    for key,value in pairs(input.expected_metadata) do if key~='bookId' then assert(record[key]==value) end end
    assert(record.detail_source=='native');report.native_detail=true
    local state_path=record.cache_dir..'/reading_state.json';local state_hash=Crypto.sha256_hex(file(state_path))
    local function paint() UI:forceRePaint() end
    local function open_state()
        local action
        for _i,buttons in ipairs({detail._action_buttons or {},detail._footer_actions or {}}) do
            for _j,button in ipairs(buttons) do if button.text==tr('Shelf status') then action=button end end
        end
        assert(action);action.callback();assert(plugin._shelf_state_menu)
    end
    local function start_preview()
        if not plugin._shelf_state_menu then open_state() end
        local action
        for _i,item in ipairs(plugin._shelf_state_menu.item_table) do if item.text==tr('Change cloud membership') then action=item end end
        assert(action);action.callback()
    end
    local function wait_preview(before,digest)
        pump(function() return plugin._shelf_membership_ui and plugin._shelf_membership_ui.dialog end)
        local plan=assert(plugin.shelf_membership.preview)
        assert(plan.book_id==id and plan.before==before and Task.digest(assert(Task.members(plan.snapshot)))==digest)
        local dialog=plugin._shelf_membership_ui.dialog
        assert(dialog.ok_text==tr(before and 'Remove from cloud bookshelf' or 'Add to cloud bookshelf'))
        assert(dialog.text:find(input.expected_metadata.title,1,true));paint();return dialog
    end
    report.phase='preview';start_preview()
    UI:scheduleIn(.1,function() report.worker_heartbeat=plugin.shelf_membership.job~=nil end)
    local dialog=wait_preview(false,input.members_digest)
    report.shelf_books=input.shelf_books;report.preview_matches=true;report.native_confirmation=true
    report.phase='cancel';dialog.cancel_callback();dialog.ok_callback()
    assert(not plugin._shelf_membership_ui and not plugin.shelf_membership.preview and counters[2]+counters[3]==0)
    report.cancel_no_post=true
    report.phase='close';start_preview();local cancelled_pid=assert(plugin.shelf_membership.worker.job).pid;seen[cancelled_pid]=true
    pump(function() return counters[0]>=2 end)
    local stale=plugin._shelf_membership_ui and plugin._shelf_membership_ui.dialog
    UI:close(assert(plugin._shelf_state_menu));if stale then stale.ok_callback() end
    pump(function() return require('ffi/util').isSubProcessDone(cancelled_pid) end)
    assert(not plugin._shelf_membership_ui and not plugin.shelf_membership.job and not plugin.shelf_membership.preview)
    report.status_close_cancelled=true
    report.phase='recreate';plugin.shelf_membership:cancel()
    plugin.shelf_membership=require('weread.lib.shelf_membership_service'):new{settings=plugin.settings,client=plugin.client,scheduler=UI}
    start_preview();dialog=wait_preview(false,input.members_digest)
    local function independent(sequence)
        if not rpc_token then return end
        io.stdout:write('\nWEREAD_NATIVE_THOUGHT_'..rpc_token..'_STEP='..json.encode{seq=sequence}..'\n');io.stdout:flush()
        local line=assert(io.stdin:read('*l'));assert(#line<=16384)
        local reply=json.decode(line);assert(type(reply)=='table' and reply.seq==sequence and reply.ok==true)
        for key in pairs(reply) do assert(key=='seq' or key=='ok') end
    end
    if input.permit_writes then
        report.phase='add';dialog.ok_callback();pump(function() return not plugin._shelf_membership_ui end)
        assert(counters[2]==1 and counters[3]==0 and not plugin.shelf_membership:pending())
        assert(plugin.library_db:getShelfStatus(id).present==true)
        local members=assert(Task.members{books=plugin.library_db:getShelf()})
        assert(#members==input.shelf_books+1)
        local original={};for _i,value in ipairs(members) do if value~=id then original[#original+1]=value end end
        assert(Task.digest(original)==input.members_digest and counters[5]==200)
        local added_digest=Task.digest(members);independent(1);counters[7]=1
        report.phase='remove';start_preview();dialog=wait_preview(true,added_digest);dialog.ok_callback()
        pump(function() return not plugin._shelf_membership_ui end)
        assert(counters[2]==1 and counters[3]==1 and counters[5]==200 and counters[6]==200 and not plugin.shelf_membership:pending())
        assert(plugin.library_db:getShelfStatus(id).present==false)
        private.final_members_digest=Task.digest(assert(Task.members{books=plugin.library_db:getShelf()}))
        assert(private.final_members_digest==input.members_digest)
        independent(2)
        report.roundtrip_restored=true;report.journal_before_posts=counters[8]==2;report.native_cache_readback=true
    else dialog.cancel_callback();assert(counters[2]+counters[3]==0) end
    assert(Crypto.sha256_hex(file(state_path))==state_hash)
    local latest=assert(plugin.settings:get_book(id))
    assert(latest.progress==.12 and latest.pending_upload_position.chapter_offset==7)
    report.local_state_preserved=true
    plugin:closeWeReadUI()
    for pid in pairs(seen) do pump(function() return require('ffi/util').isSubProcessDone(pid) end) end
    report.workers_reaped=next(seen)~=nil
    report.phase='audit'
    local function audit(path)
        for name in lfs.dir(path) do
            if name~='.' and name~='..' and not (path==home and name=='plugins') then
                local full=path..'/'..name;local info=assert(lfs.symlinkattributes(full))
                if info.mode=='directory' then audit(full)
                elseif info.mode=='file' then
                    report.profile_files_audited=report.profile_files_audited+1;assert(report.profile_files_audited<=1024 and info.size<=16*1024*1024)
                    local bytes=file(full)
                    for _i,value in ipairs({grant.accessToken,grant.refreshToken,grant.deviceId}) do assert(not bytes:find(value,1,true)) end
                else error('unexpected profile entry',0) end
            end
        end
    end
    audit(home);report.credential_audit=true
    assert(counters[0]>=3 and counters[1]==1 and counters[4]==0 and report.worker_heartbeat)
    report.no_authentication_posts=true;report.phase,report.result='complete','PASS'
end)
if plugin then pcall(plugin.closeWeReadUI,plugin) end
if not ok then report.failed_line=tonumber(type(reason)=='string' and reason:match('owner_shelf_membership_probe%.lua:(%d+):')) or 0 end
if counters then
    for index=1,5 do report.request_counts[index]=tonumber(counters[index-1]) end
    if counters[2]>0 then report.post_statuses[#report.post_statuses+1]=tonumber(counters[5]) end
    if counters[3]>0 then report.post_statuses[#report.post_statuses+1]=tonumber(counters[6]) end
    ffi.C.munmap(counters,128)
end
for _i,fd in ipairs(descriptors) do ffi.C.close(fd) end
local prefix=rpc_token and 'WEREAD_NATIVE_THOUGHT_'..rpc_token..'_RESULT=' or 'WEREAD_OWNER_MEMBERSHIP_RESULT='
io.stdout:write('\n'..prefix..json.encode{report=report,private=private}..'\n');io.stdout:flush()
os.exit(ok and 0 or 1)
