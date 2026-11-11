-- Actual native personal-thought UI, production service/SQLite and HTTPS.
-- The host independently reads every step before permitting the next action.
require('ffi').log=function() end
require('setupkoenv')
local ffi,json=require('ffi'),require('json');require('ffi/posix_h')
local descriptors,workers={},{};local plugin,gate,input,counters,memory
local report={result='UNVERIFIED',phase='init',permit_writes=false,anonymous_credentials=false,native_ui=false,
    guard_installed=false,worker_heartbeat=false,journal_before_post=false,no_authentication_posts=true,credential_audit=false,workers_reaped=false,
    local_pending_kept=false,dispatch_blocked=false,cache_verified=false,steps=0,requests=0,posts=0,forbidden=0,failed_line=0,screenshots=0}
local function emit(kind,value)
    assert(input and type(input.rpc_token)=='string' and input.rpc_token:match('^[a-f0-9]+$') and #input.rpc_token==32)
    local raw=json.encode(value);assert(#raw<=16384)
    io.write('\nWEREAD_NATIVE_THOUGHT_'..input.rpc_token..'_'..kind..'='..raw..'\n');io.flush()
end
local ok,reason=pcall(function()
    local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/weread%-native%-thought%-[%w_]+/profile$'))
    local length=assert(io.stdin:read('*l'));assert(length:match('^[1-9]%d*$') and #length<=8 and tonumber(length)<=8*1024*1024)
    input=json.decode(assert(io.stdin:read(tonumber(length))))
    assert(type(input.permit_writes)=='boolean' and input.permit_writes==(os.getenv('WEREAD_NATIVE_THOUGHT_ARMED')=='1'))
    report.permit_writes=input.permit_writes
    local grant=assert(input.credentials);assert(grant.vid==input.owner and type(input.original_ids)=='table')
    local source=home..'/plugins/weread.koplugin';package.path=source..'/?.lua;'..package.path
    G_defaults=require('luadefaults'):open();G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
    G_reader_settings:saveSetting('language','zh_CN');require('gettext').changeLang('zh_CN')
    G_reader_settings:saveSetting('virtual_keyboard_enabled',true);G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
    local Device=require('device');require('document/canvascontext'):init(Device)
    Device.screen.shot=function() report.screenshots=report.screenshots+1;error('native_trial/screenshots_disabled',0) end
    pcall(ffi.cdef,'int memfd_create(const char *, unsigned int); void *mmap(void *, unsigned long, int, int, int, long); int munmap(void *, unsigned long);')
    local function anonymous(value)
        local fd=tonumber(ffi.C.memfd_create('weread-native-thought',1));assert(fd>=0);descriptors[#descriptors+1]=fd
        local bytes='return '..require('dump')(value,nil,true);local offset=0
        while offset<#bytes do local n=tonumber(ffi.C.write(fd,ffi.cast('const char *',bytes)+offset,#bytes-offset));assert(n>0);offset=offset+n end
        return '/proc/self/fd/'..fd
    end
    local auth={auth_schema_version=1,auth_epoch=1,account={user_vid=input.owner,name=''},cookies={},api_key=''}
    local auth_path=anonymous(auth);local saved={};for k,v in pairs(grant) do saved[k]=v end
    saved.epoch,saved.verified_at,saved.book_count=1,os.time(),input.shelf_books
    local grant_path=anonymous({revision=1,authorization=saved})
    local Settings=require('weread.lib.settings');local settings_new=Settings.new
    function Settings:new()
        local value=settings_new(self);assert(not value.mock_endpoint)
        if input.mock_port then
            assert(grant.vid=='900000' and grant.accessToken=='synthetic-native-access' and input.book_id=='41'
                and os.getenv('WEREAD_NATIVE_THOUGHT_MOCK')==tostring(input.mock_port))
            value.mock_endpoint='http://127.0.0.1:'..input.mock_port
        else assert(not os.getenv('WEREAD_NATIVE_THOUGHT_MOCK')) end
        local flush=value.store.flush
        value.store.flush=function(store,...)
            local held={};local keys={'account','cookies','api_key','wr_ticket','wr_wrpa','device_fingerprint'}
            for _i,k in ipairs(keys) do held[k]=store.data[k];store.data[k]=nil end
            local result={pcall(flush,store,...)};for _i,k in ipairs(keys) do store.data[k]=held[k] end
            assert(result[1]);return unpack(result,2)
        end
        for k,v in pairs(auth) do value.store:saveSetting(k,v) end
        value.settings_file=auth_path;return value
    end
    local Credentials=require('weread.lib.native_credentials');local credentials_new=Credentials.new
    function Credentials:new(settings,...)
        local value=credentials_new(self,settings,...);value.path=grant_path
        value._write=function() error('native_trial/renewal_disabled',0) end;return value
    end
    report.anonymous_credentials=true
    memory=ffi.C.mmap(nil,128,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1));counters=ffi.cast('int *',memory)
    local parent=tonumber(ffi.C.getpid());local base='https://i.weread.qq.com';local id=input.book_id
    local paths={[base..'/review/list?bookId='..id..'&listType=11&listMode=0&mine=1&synckey=0&count=20']='thoughts',
        [base..'/book/bookmarklist?bookId='..id..'&synckey=0']='marks',[base..'/book/info?bookId='..id]='metadata',
        [base..'/review/add']='create',[base..'/review/useredit']='edit',[base..'/review/delete']='delete'}
    local Client=require('weread.lib.client');local request=Client.request
    function Client:request(options)
        local kind=paths[options.url];local writing=kind=='create' or kind=='edit' or kind=='delete';local h=options.headers or {}
        if not kind or tonumber(ffi.C.getpid())==parent or options.method~=(writing and 'POST' or 'GET')
            or options.skip_cookie~=true or options.persist_response_cookies~=false or options.sensitive~=true
            or h.vid~=grant.vid or h.accessToken~=grant.accessToken or h.Cookie or h.cookie or h.Authorization or h.authorization
            or not writing and options.body~=nil or counters[0]>=32 then counters[2]=counters[2]+1;error('native_trial/transport_scope',0) end
        if writing then
            local body=self:json_decode(options.body);assert(gate)
            if not gate:claim(kind,body) then error('native_trial/dispatch_blocked',0) end
            counters[1]=counters[1]+1;assert(counters[1]<=3)
        end
        counters[0]=counters[0]+1;return request(self,options)
    end
    report.guard_installed=true
    local UI=require('ui/uimanager');local socket=require('socket')
    local Worker=require('weread.lib.memory_worker');local start=Worker.start
    function Worker:start(...)
        local result=start(self,...);if self.job then workers[#workers+1]={pid=self.job.pid,runner=self.runner} end;return result
    end
    local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
    for _i,item in ipairs(Loader:_discover()) do if item.name=='weread' then Loader:_load{item} end end;assert(#Loader.enabled_plugins==1)
    local FM=require('apps/filemanager/filemanager');FM:showFiles(home);plugin=assert(FM.instance.weread)
    plugin.isNetworkOnline=function() return true end;plugin.isNetworkConnected=plugin.isNetworkOnline
    local Cache=require('weread.lib.my_cloud_marks_store');assert(Cache:new(plugin.library_db,plugin.client):write(input.marks))
    local cache=Cache:new(plugin.library_db,plugin.client,'thoughts');assert(cache:write(input.thoughts))
    local fixtures=assert(debug.getinfo(1,'S').source:match('^@(.*/)'))
    gate=dofile(fixtures..'native_thought_trial_gate.lua'):new(input,plugin.library_db,plugin.client,home)
    local journal=require('weread.lib.thought_edit_store'):new(plugin.library_db,plugin.client)
    local tr=require('weread.lib.plugin_util').tr
    local function tick() UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01) end
    local function wait(test)
        local deadline=socket.gettime()+90;while not test() do assert(socket.gettime()<deadline);tick() end
    end
    local function select(owner,key)
        for index,item in ipairs(owner.menu.item_table) do if item.my_note_id==key then
            owner.menu:onGotoPage(owner.menu:getPageNumber(index));owner.menu:onMenuSelect(item);return
        end end;error('native_trial/missing_note',0)
    end
    local function tap(owner,key)
        UI:forceRePaint();assert(owner.menu._shelf_popup.button_table:getButtonById(key)):onTapSelectButton()
    end
    local function open(thoughts)
        plugin:showBookMenu{book_id=id,title='所选测试书籍',chapters={}}
        local detail=assert(plugin._book_detail_view)
        for _i,button in ipairs(detail._action_buttons) do if button.text==tr(thoughts and 'My cloud thoughts' or 'My cloud highlights') then
            button.callback();return assert(plugin._my_marks_owner)
        end end;error('native_trial/missing_entry',0)
    end
    local function operate(owner,operation,target,text)
        select(owner,target);tap(owner,'thought_'..operation)
        if operation~='delete' then owner.editor.input:setInputText(text);tap(owner,'submit_thought') end
        wait(function() return not owner.editor or owner.editor.service.preview end);assert(owner.editor)
        local beat=false;UI:scheduleIn(.1,function() beat=true end)
        tap(owner,'confirm_thought_change');wait(function() return beat and not owner.editor end)
        report.worker_heartbeat=true
        local top=UI:getTopmostVisibleWidget();if top~=owner.menu then UI:close(top) end
    end
    local function step(number,target)
        emit('STEP',{seq=number,created_id=target})
        local raw=assert(io.stdin:read('*l'));assert(#raw<=16384);local reply=json.decode(raw)
        assert(type(reply)=='table' and reply.seq==number and reply.ok==true and reply.created_id==target)
        report.steps=number
    end
    report.native_ui=true;report.phase='create'
    operate(open(false),'create',input.bookmark_id,input.create_body.content)
    local state=gate:read()
    if not input.permit_writes then
        assert(state.phase=='blocked' and state.posts==0 and state.preview and journal:read().phase=='pending')
        report.dispatch_blocked,report.local_pending_kept=true,true
        emit('STEP',{seq=0,preview=state.preview});local raw=assert(io.stdin:read('*l'));local reply=json.decode(raw)
        assert(reply.seq==0 and reply.ok==true);report.phase='complete'
    else
        assert(state.phase=='create_pending' and state.posts==1 and journal:read().phase=='idle')
        local value=assert(cache:read(id));local target
        for _i,row in ipairs(value.reviews) do if row.content==input.create_body.content and row.isPrivate==1 then assert(not target);target=row.reviewId end end
        assert(target);step(1,target);gate:advance(1,target)
        report.phase='edit';operate(open(true),'edit',target,input.edited_text)
        assert(gate:read().phase=='edit_pending' and journal:read().phase=='idle');step(2,target);gate:advance(2,target)
        report.phase='delete';operate(open(true),'delete',target)
        assert(gate:read().phase=='delete_pending' and gate:read().posts==3 and journal:read().phase=='idle');step(3,target)
        value=assert(cache:read(id));for _i,row in ipairs(value.reviews) do assert(row.reviewId~=target) end
        report.cache_verified=true;report.phase='complete'
    end
    report.journal_before_post=true
    plugin:closeWeReadUI();for _i,worker in ipairs(workers) do wait(function() return worker.runner.done(worker.pid) end) end;report.workers_reaped=true
    local lfs=require('libs/libkoreader-lfs')
    local function audit(directory)
        for entry in lfs.dir(directory) do if entry~='.' and entry~='..' and not (directory==home and entry=='plugins') then
            local path=directory..'/'..entry;local attr=assert(lfs.symlinkattributes(path))
            if attr.mode=='directory' then audit(path) else
                assert(attr.mode=='file' and attr.size<=16*1024*1024)
                local file=assert(io.open(path,'rb'));local raw=file:read('*a');file:close()
                for _i,key in ipairs({'accessToken','refreshToken','deviceId'}) do assert(not raw:find(grant[key],1,true)) end
            end
        end end
    end
    audit(home);report.credential_audit=true;assert(counters[2]==0);report.result='PASS'
end)
if plugin then pcall(plugin.closeWeReadUI,plugin) end
if counters then report.requests,report.posts,report.forbidden=tonumber(counters[0]),tonumber(counters[1]),tonumber(counters[2]);ffi.C.munmap(memory,128) end
for _i,fd in ipairs(descriptors) do ffi.C.close(fd) end
if not ok then report.failed_line=tonumber(type(reason)=='string' and reason:match('owner_thought_trial_probe%.lua:(%d+):')) or 0 end
if input then emit('RESULT',report) end
os.exit(ok and 0 or 1)
