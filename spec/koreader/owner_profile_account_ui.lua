-- Owner nickname acceptance in a disposable tmpfs profile. No private output.
require('ffi').log=function() end
require('setupkoenv')
local ffi=require('ffi');require('ffi/posix_h')
local json=require('json');local mode=arg[1]
local report={result='UNVERIFIED',mode=mode,phase='init',name_matches=false,sqlite_verified=false,
    offline_cache=false,worker_reaped=false,account_isolated=false,credentials_not_on_disk=false,
    statistics_verified=false,concurrent_started=false,statistics_requests=0,requests=0,forbidden=0,failed_line=0}
local descriptors={};local plugin,shared
local ok,reason=pcall(function()
    assert(mode=='live' or mode=='reopen')
    local home=assert(os.getenv('KO_HOME'));assert(ffi.os=='Linux' and home:match('^/dev/shm/weread%-profile%-[%w_]+/profile$'))
    local lfs=require('libs/libkoreader-lfs')
    assert((lfs.symlinkattributes(home..'/weread')~=nil)==(mode=='reopen'))
    local raw=assert(io.stdin:read(65537));assert(#raw<=65536)
    local input=json.decode(raw)
    assert(type(input)=='table' and type(input.owner)=='string' and input.owner:match('^[1-9]%d*$') and #input.owner<=20
        and type(input.cookies)=='table' and input.cookies.wr_vid == input.owner and type(input.cookies.wr_skey)=='string'
        and type(input.expected_name)=='string' and #input.expected_name>0 and #input.expected_name<=512)
    local mock=os.getenv('WEREAD_PROFILE_MOCK')
    assert((input.mock_port~=nil)==(mock~=nil))
    if mock then assert(tonumber(mock)==input.mock_port and input.owner=='900000' and input.cookies.wr_skey=='mock-only') end
    local concurrent=input.with_statistics==true
    local grant=input.native_credentials
    if concurrent then
        assert(type(grant)=='table' and grant.vid==input.owner)
        for _i,key in ipairs({'accessToken','refreshToken','deviceId'}) do assert(type(grant[key])=='string' and #grant[key]>=8) end
        if mock then assert(grant.accessToken=='mock-native-access' and grant.refreshToken=='mock-native-refresh'
            and grant.deviceId=='eink334691225'..string.rep('1',19)) end
    else assert(grant==nil) end
    package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
    G_defaults=require('luadefaults'):open();G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
    G_reader_settings:saveSetting('language','zh_CN');require('gettext').changeLang('zh_CN')
    G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
    local Device=require('device');require('document/canvascontext'):init(Device)
    Device.screen.shot=function() error('private screenshots disabled',0) end
    pcall(ffi.cdef,'int memfd_create(const char *, unsigned int);')
    local function anonymous(data)
        local fd=tonumber(ffi.C.memfd_create('weread-profile',1));assert(fd>=0);descriptors[#descriptors+1]=fd
        local bytes='return '..require('dump')(data,nil,true);local offset=0
        while offset<#bytes do
            local count=tonumber(ffi.C.write(fd,ffi.cast('const char *',bytes)+offset,#bytes-offset));assert(count>0);offset=offset+count
        end
        return '/proc/self/fd/'..fd
    end
    local auth={auth_schema_version=1,auth_epoch=1,account={user_vid=input.owner,name=''},cookies=input.cookies,api_key=''}
    local scope_file=anonymous(auth)
    local grant_file
    if concurrent then
        local saved={};for key,value in pairs(grant) do saved[key]=value end
        saved.epoch,saved.verified_at,saved.book_count=1,os.time(),0
        grant_file=anonymous({revision=1,authorization=saved})
    end
    local Settings=require('weread.lib.settings');local original=Settings.new
    function Settings:new()
        local value=original(self);assert(not value.mock_endpoint)
        if mock then value.mock_endpoint='http://127.0.0.1:'..mock end
        local flush=value.store.flush
        value.store.flush=function(store,...)
            local held={};local fields={'account','cookies','api_key','wr_ticket','wr_wrpa','device_fingerprint'}
            for _i,key in ipairs(fields) do held[key]=store.data[key];store.data[key]=nil end
            local result={pcall(flush,store,...)}
            for _i,key in ipairs(fields) do store.data[key]=held[key] end
            assert(result[1]);return unpack(result,2)
        end
        for key,item in pairs(auth) do value.store:saveSetting(key,item) end
        value.settings_file=scope_file
        return value
    end
    if concurrent then
        local Credentials=require('weread.lib.native_credentials');local new=Credentials.new
        function Credentials:new(settings,...)
            local value=new(self,settings,...);value.path=grant_file;return value
        end
    end
    pcall(ffi.cdef,'void *mmap(void *, unsigned long, int, int, int, long); int munmap(void *, unsigned long);')
    shared=ffi.C.mmap(nil,4096,3,0x21,-1,0);assert(shared~=ffi.cast('void *',-1))
    local counters=ffi.cast('int *',shared);local parent=tonumber(ffi.C.getpid())
    local allowed_stats={}
    if concurrent then
        local Stats=require('weread.lib.read_stats');local base=Stats.period_start('monthly',os.time())
        for _i=1,24 do
            allowed_stats['https://i.weread.qq.com/readdata/detail?baseTime='..string.format('%.0f',base)..'&mode=monthly']=true
            base=Stats.shift_period('monthly',base,-1)
        end
    end
    local Client=require('weread.lib.client');local request=Client.request
    function Client:request(options)
        local headers=options.headers or {}
        local name_request=mode=='live' and options.url=='https://weread.qq.com/api/userInfo?userVid='
                ..require('weread.lib.protocol').urlencode(input.owner)
            and options.method=='GET' and options.body==nil and options.skip_cookie==true
            and options.persist_response_cookies==false and options.sensitive==true
            and headers.Cookie==require('weread.lib.cookie').to_header(input.cookies)
            and tonumber(ffi.C.getpid())~=parent and counters[0]==0
        local stats_request=mode=='live' and concurrent and allowed_stats[options.url]
            and options.method=='GET' and options.body==nil and options.skip_cookie==true
            and options.persist_response_cookies==false and options.sensitive==true
            and headers.vid==input.owner and headers.accessToken==grant.accessToken and not headers.Cookie
            and tonumber(ffi.C.getpid())~=parent and counters[2]<24
        if name_request then counters[0]=counters[0]+1
        elseif stats_request then allowed_stats[options.url]=nil;counters[2]=counters[2]+1
        else counters[1]=counters[1]+1;error('profile read scope rejected',0) end
        return request(self,options)
    end
    local Worker=require('weread.lib.memory_worker');local start=Worker.start;local jobs={}
    function Worker:start(...)
        local result={start(self,...)}
        if self.job then jobs[#jobs+1]={pid=self.job.pid,runner=self.runner} end
        return unpack(result)
    end
    local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
    for _i,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
    assert(#Loader.enabled_plugins==1)
    local FM=require('apps/filemanager/filemanager');FM:showFiles(home..'/books');plugin=assert(FM.instance.weread)
    plugin.isNetworkConnected=function() return mode=='live' end
    plugin.isNetworkOnline=function() error('profile used a synchronous Internet check') end
    if concurrent then
        plugin.native_renewal=nil -- Only read requests are permitted in this test.
        local refresh_name=plugin.refreshProfileName
        function plugin:refreshProfileName()
            assert(self.profile_request,'statistics was not running when name refresh started')
            report.concurrent_started=true
            return refresh_name(self)
        end
    else plugin.refreshProfile=function() end end
    local UI=require('ui/uimanager');local socket=require('socket')
    local function pump(predicate)
        local deadline=socket.gettime()+40
        repeat UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01);assert(socket.gettime()<deadline)
        until predicate()
    end
    report.phase='profile';plugin:showProfile()
    if mode=='live' then
        assert(plugin._profile_view.data.account_name==require('weread.lib.plugin_util').tr('Unknown account'))
        plugin._profile_view._profile_buttons[3].callback()
        pump(function() return counters[0]==1 and not plugin.profile_name_request
            and (not concurrent or counters[2]>=1 and not plugin.profile_request) end)
    end
    local view=assert(plugin._profile_view)
    assert(view.data.account_name==input.expected_name)
    UI:forceRePaint()
    local function find_name(widget)
        if widget.text==input.expected_name and widget.face==view.fonts.card_title then return widget end
        for _i,child in ipairs(widget) do local found=find_name(child);if found then return found end end
    end
    local label=assert(find_name(view));local size=label:getSize()
    assert(size.w>0 and size.w<=view.content_width and label.use_xtext and #label._xshaping>0)
    for _i,glyph in ipairs(label._xshaping) do assert(glyph.no_drawing or glyph.glyph>0) end
    report.name_matches=true
    local stored=assert(plugin.library_db:getProfileState('account_name'))
    assert(stored.name==input.expected_name and stored.epoch==1);report.sqlite_verified=true
    if concurrent then
        local snapshot=assert(plugin.library_db:getProfileState('statistics'))
        assert(view.data.has_data and snapshot.source_kind=='native')
        local goal=plugin.library_db:getProfileState('goal') or {}
        local Profile=require('weread.lib.profile')
        local full=Profile.build(snapshot,goal.minutes)
        local Util=require('weread.lib.plugin_util')
        local expected=Util.T(Util.tr('Today %1 / %2 min · %3 consecutive days'),
            math.floor(full.today_seconds/60),full.goal_minutes,
            (full.streak_lower_bound and '≥' or '')..tostring(full.streak))
        local now=os.time()
        if not full.fetched_at or now-full.fetched_at>=Profile.TTL or now<full.fetched_at then
            expected=expected..' · '..Util.tr('Cached')
        end
        local reads=0;local original_read=plugin.library_db.openRead
        plugin.library_db.openRead=function(self,...) reads=reads+1;return original_read(self,...) end
        local summary=plugin:homeReadingSummary()
        plugin.library_db.openRead=original_read
        assert(reads==1 and summary==expected,'home summary differs from full profile')
        local digest=require('weread.lib.readtime_transfer_contract').digest(snapshot)
        local path=home..'/statistics-fingerprint';local file
        if mode=='live' then file=assert(io.open(path,'wb'));assert(file:write(digest));assert(file:close())
        else file=assert(io.open(path,'rb'));assert(file:read('*a')==digest);assert(file:close()) end
        report.statistics_verified=true
    end
    report.offline_cache=mode=='reopen'
    local other=require('weread.lib.library_db'):new{data_dir=plugin.settings.data_dir,get=function(_self,key,default)
        if key=='account' then return {user_vid=input.owner=='90009999' and '90009998' or '90009999'} end
        return default
    end}
    assert(not other:getProfileState('account_name'));report.account_isolated=true
    plugin:closeWeReadUI();plugin.settings:flush();G_reader_settings:flush()
    for _i,job in ipairs(jobs) do assert(job.runner.done(job.pid)) end
    assert(not plugin.profile_name_request and not plugin.profile_request);report.worker_reaped=true
    report.phase='audit'
    local function audit(path)
        for entry in lfs.dir(path) do if entry~='.' and entry~='..' and not (path==home and entry=='plugins') then
            local file=path..'/'..entry;local info=assert(lfs.symlinkattributes(file))
            if info.mode=='directory' then audit(file)
            elseif info.mode=='file' then
                assert(info.size<=4*1024*1024);local handle=assert(io.open(file,'rb'));local bytes=handle:read('*a');handle:close()
                for key,value in pairs(input.cookies) do if key~='wr_vid' and #value>=8 then assert(not bytes:find(value,1,true)) end end
                if concurrent then for _i,key in ipairs({'accessToken','refreshToken','deviceId'}) do
                    assert(not bytes:find(grant[key],1,true))
                end end
            else error('unexpected profile file',0) end
        end end
    end
    audit(home);report.credentials_not_on_disk=true
    assert(counters[0]==(mode=='live' and 1 or 0) and counters[1]==0
        and (not concurrent and counters[2]==0 or concurrent and (mode=='live' and counters[2]>=1 or mode=='reopen' and counters[2]==0)))
    report.phase,report.result='complete','PASS'
end)
if plugin then pcall(plugin.closeWeReadUI,plugin) end
if shared then local counters=ffi.cast('int *',shared);report.requests=tonumber(counters[0]);report.forbidden=tonumber(counters[1]);report.statistics_requests=tonumber(counters[2]);ffi.C.munmap(shared,4096) end
for _i,fd in ipairs(descriptors) do ffi.C.close(fd) end
if not ok then report.failed_line=tonumber(type(reason)=='string' and reason:match('owner_profile_account_ui%.lua:(%d+):')) or 0 end
io.stdout:write('\nWEREAD_PROFILE_ACCOUNT_UI='..json.encode(report)..'\n')
os.exit(ok and 0 or 1)
