-- Packaged native UI, isolated synthetic file, and tightly bounded transport.
-- Account data and the returned test-book identifier stay on the private pipe.
require('ffi').log=function() end
require('setupkoenv')
local ffi=require('ffi');require('ffi/posix_h')
local json=require('json')
local report={result='UNVERIFIED',phase='init',permit_writes=false,chooser=false,cancel_no_request=false,
    heartbeat=false,journal_idle=false,cache_verified=false,file_unchanged=false,credential_audit=false,
    guard_selftest=false,native_gets=0,credential_gets=0,puts=0,notifies=0,denied=0,screenshots=0,failed_line=0}
local input,token,profile,plugin,counters,memory,target
local ok,reason=pcall(function()
    local home=assert(os.getenv('KO_HOME'));assert(ffi.os=='Linux' and home:match('^/dev/shm/weread%-upload%-ui%-[%w_]+/profile$'))
    local length=assert(io.stdin:read('*l'));assert(length:match('^[1-9]%d*$') and #length<=6)
    length=tonumber(length);assert(length<=256*1024);input=json.decode(assert(io.stdin:read(length)))
    token=assert(input.rpc_token);assert(type(token)=='string' and token:match('^[a-f0-9]+$') and #token==32)
    local grant=assert(input.credentials);local name=assert(input.name);local armed=input.permit_writes
    local mock=tonumber(os.getenv('WEREAD_UPLOAD_UI_MOCK_PORT') or '')
    assert(type(armed)=='boolean' and armed==(os.getenv('WEREAD_UPLOAD_UI_ARMED')=='1'))
    assert(type(input.shelf_books)=='number' and input.shelf_books%1==0 and input.shelf_books>=1 and input.shelf_books<=5000)
    assert(type(name)=='string' and (mock and name=='SyntheticUpload.txt' or name:match('^KOReaderSynthetic%-[a-f0-9]+%.txt$') and #name==38))
    assert(type(grant.vid)=='string' and grant.vid:match('^[1-9]%d*$'))
    report.permit_writes=armed
    local source=home..'/plugins/weread.koplugin';package.path=source..'/?.lua;'..package.path
    G_defaults=require('luadefaults'):open();G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
    G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'});G_reader_settings:saveSetting('language','zh_CN')
    require('gettext').changeLang('zh_CN')
    local Device=require('device');require('document/canvascontext'):init(Device)
    Device.screen.shot=function() report.screenshots=report.screenshots+1;error('upload_ui/screenshots_disabled',0) end
    local UI=require('ui/uimanager');UI:setRunForeverMode();UI:setInputTimeout(0)
    profile=dofile(assert(debug.getinfo(1,'S').source:match('^@(.*/)'))..'native_account_profile.lua')
    profile.start(home,grant,input.shelf_books)
    if mock then
        assert(mock>=1 and mock<=65535 and grant.vid=='900000' and grant.accessToken=='mock-native-access')
        local Settings=require('weread.lib.settings');local factory=Settings.new
        function Settings:new() local value=factory(self);value.mock_endpoint='http://127.0.0.1:'..mock;return value end
    end
    local body='Synthetic upload for KOReader.\n';local path=home..'/'..name
    local f=assert(io.open(path,'wb'));assert(f:write(body));f:close()
    pcall(ffi.cdef,'void *mmap(void *, unsigned long, int, int, int, long); int munmap(void *, unsigned long);')
    memory=ffi.C.mmap(nil,128,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1));counters=ffi.cast('int *',memory)
    local parent=tonumber(ffi.C.getpid());local base='https://i.weread.qq.com'
    local protocol=require('weread.lib.protocol');local Cos=require('weread.lib.cos_sign');local temporary
    local Auth=require('weread.lib.native_authorization');local old_auth=Auth._request
    function Auth:_request(stage,...)
        local value=old_auth(self,stage,...)
        if stage=='personal_upload_credential' then assert(not temporary);temporary=value end
        return value
    end
    local Client=require('weread.lib.client');local request=Client.request
    function Client:request(opts)
        local h=opts.headers or {};local kind
        if opts.sensitive and opts.skip_cookie and opts.persist_response_cookies==false and h.Cookie==nil then
            if opts.method=='GET' and opts.body==nil and h.vid==grant.vid and h.accessToken==grant.accessToken then
                if opts.url==base..'/shelf/sync' then kind=0
                elseif opts.url==base..'/cos/getcredential?name='..protocol.urlencode(name:sub(1,-5))..'&from=' then kind=1 end
            elseif temporary and opts.method=='PUT' and opts.body==nil then
                local prepared=assert(Cos.prepare(temporary,#body,os.time()));local signed=assert(Cos.sign(prepared))
                if opts.url==signed.url and h.Host==signed.headers.Host and h['Content-Length']==tostring(#body)
                    and h['x-cos-security-token']==signed.headers['x-cos-security-token'] and type(h.Authorization)=='string'
                    and h.vid==nil and h.accessToken==nil and type(opts.source)=='function' then kind=2 end
            elseif temporary and opts.method=='POST' and h.vid==grant.vid and h.accessToken==grant.accessToken
                and opts.url==base..'/cos/notify?name='..protocol.urlencode(name)..'&path='..protocol.urlencode(temporary.ObjectName)..'&cancel=0'
                and opts.body=='{}' then kind=3 end
        end
        local ctx=plugin and plugin._personal_upload_ui
        if kind==nil or not armed or tonumber(ffi.C.getpid())==parent or kind==0 and counters[0]>=8 or kind~=0 and counters[kind]>=1
            or not ctx or not ctx.record or not ctx.journal:owns(ctx.selected.scope,ctx.record) then
            counters[4]=counters[4]+1;error('upload_ui/transport_denied',0)
        end
        counters[kind]=counters[kind]+1
        if kind==2 then
            local stream=opts.source;local sent=''
            opts.source=function()
                local part,err=stream();if part then sent=sent..part;assert(body:sub(1,#sent)==sent) else assert(sent==body) end
                return part,err
            end
        end
        return request(self,opts)
    end
    local denied=pcall(Client.request,Client:new({}),{url=base..'/login',method='POST',body='{}',headers={},
        sensitive=true,skip_cookie=true,persist_response_cookies=false})
    assert(not denied and counters[4]==1);counters[4]=0;report.guard_selftest=true
    local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
    for _i,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
    assert(#Loader.enabled_plugins==1)
    local FM=require('apps/filemanager/filemanager');FM:showFiles(home);plugin=assert(FM.instance.weread)
    plugin.isNetworkConnected=function() return true end;plugin.isNetworkOnline=function() return true end
    plugin.fetchVisibleShelfCovers=function() end;plugin.prepareShelfProgress=function() end;plugin.refreshVisibleShelfProgress=function() end
    local Worker=require('weread.lib.memory_worker');local Upload=require('weread.ui.personal_upload')
    plugin.personal_upload_worker=Worker:new{scheduler=UI,codec=plugin.client,max_bytes=8*1024*1024}
    local start=plugin.personal_upload_worker.start
    function plugin.personal_upload_worker:start(task,callback)
        return start(self,task,function(result)
            if Upload.confirmed(result) then target=result.book_id end
            callback(result)
        end)
    end
    local socket=require('socket');local function pump(test)
        local deadline=socket.gettime()+100
        repeat UI:setInputTimeout(0);UI:handleInput();if test() then return end
            assert(socket.gettime()<deadline,'upload_ui/deadline');socket.sleep(.01) until false
    end
    local tr=require('weread.lib.plugin_util').tr;local Journal=require('weread.lib.personal_upload_journal')
    local scope=assert(plugin.settings:get_auth_scope())
    local function choose()
        local found=false
        for _i,item in ipairs(plugin:getMainMenuItems()) do if item.text==tr('Upload local book') then item.callback();found=true;break end end
        assert(found);local chooser=assert(plugin._personal_upload_ui.chooser)
        chooser:onMenuHold({path=path});assert(chooser.button_dialog).buttons[1][2].callback()
        pump(function() return plugin._personal_upload_ui and plugin._personal_upload_ui.dialog~=nil end)
        return assert(plugin._personal_upload_ui.dialog)
    end
    report.phase='chooser';local dialog=choose();report.chooser=true;dialog.cancel_callback()
    assert(not plugin._personal_upload_ui and Journal:new(plugin.settings,plugin.client):read(scope).phase=='idle')
    assert(counters[0]==0 and counters[1]==0 and counters[2]==0 and counters[3]==0);report.cancel_no_request=true
    if armed then
        report.phase='upload';dialog=choose();dialog.ok_callback()
        local beat=false;UI:scheduleIn(.1,function() beat=true end)
        pump(function() return not plugin._personal_upload_ui and beat end);report.heartbeat=true
        assert(target and Journal:new(plugin.settings,plugin.client):read(scope).phase=='idle');report.journal_idle=true
        local status=assert(plugin.library_db:getShelfStatus(target));assert(status.present==true);report.cache_verified=true
    end
    f=assert(io.open(path,'rb'));assert(f:read('*a')==body);f:close();report.file_unchanged=true
    plugin:closeWeReadUI()
    local lfs=require('libs/libkoreader-lfs')
    local function audit(dir)
        for item in lfs.dir(dir) do if item~='.' and item~='..' and not (dir==home and item=='plugins') then
            local full=dir..'/'..item;local info=assert(lfs.symlinkattributes(full))
            if info.mode=='directory' then audit(full)
            elseif info.mode=='file' then
                assert(info.size<=16*1024*1024);local file=assert(io.open(full,'rb'));local bytes=file:read('*a');file:close()
                for _i,value in ipairs({grant.accessToken,grant.refreshToken,grant.deviceId}) do assert(not bytes:find(value,1,true)) end
            else error('upload_ui/profile_entry',0) end
        end end
    end
    report.phase='audit';audit(home);report.credential_audit=true
    assert(counters[4]==0 and (not armed or counters[0]>=2 and counters[1]==1 and counters[2]==1 and counters[3]==1))
    report.phase,report.result='complete','PASS'
end)
if plugin then pcall(plugin.closeWeReadUI,plugin) end
if counters then
    report.native_gets,report.credential_gets,report.puts,report.notifies,report.denied=tonumber(counters[0]),tonumber(counters[1]),tonumber(counters[2]),tonumber(counters[3]),tonumber(counters[4])
    ffi.C.munmap(memory,128)
end
if profile then profile.close() end
if not ok then report.failed_line=tonumber(type(reason)=='string' and reason:match('owner_personal_upload_ui_probe%.lua:(%d+):')) or 0 end
if target and report.result=='PASS' then report.target=target end
if token then io.stdout:write('\nWEREAD_NATIVE_THOUGHT_'..token..'_RESULT='..json.encode(report)..'\n');io.stdout:flush() end
os.exit(ok and 0 or 1)
