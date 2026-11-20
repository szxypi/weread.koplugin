-- Actual FileManager plugin, statistics UI and SQLite; private tmpfs only.
require('ffi').log=function() end
require('setupkoenv')
local ffi=require('ffi');require('ffi/posix_h')
local json=require('json')
local mode=arg[1]
local report={result='UNVERIFIED',phase='init',mode=mode,anonymous_credentials=false,transport_guard_selftest=false,
    file_backed_sqlite=false,profile_matches=false,detail_views_match=false,local_goal_readback=false,workers_reaped=false,
    credential_file_audit=false,native_filemanager_host=false,cache_account_scoped=false,worker_http_child=false,
    account_name_matches=false,account_name_glyphs=false,account_name_present=false,
    profile_months=0,validated_views=0,detail_periods=0,calendar_days=0,calendar_cells=0,profile_files_audited=0,
    screenshots=0,forbidden_requests=0,failed_line=0,request_counts=json.decode('[0]')}
local plugin,counters,memory
local descriptors={}
local ok,reason=pcall(function()
    assert(mode=='live' or mode=='reopen')
    local home=assert(os.getenv('KO_HOME'))
    assert(ffi.os=='Linux' and home:match('^/dev/shm/weread%-statistics%-[%w_]+/profile$'))
    local lfs=require('libs/libkoreader-lfs')
    assert((lfs.symlinkattributes(home..'/weread')~=nil)==(mode=='reopen'))
    local raw=assert(io.stdin:read(2*1024*1024+1));assert(#raw<=2*1024*1024)
    local input=json.decode(raw);local grant=assert(input.credentials)
    assert(input.account_name==nil or type(input.account_name)=='string' and #input.account_name>0 and input.account_name:find('%S'))
    local account_name=input.account_name or ''
    assert(type(account_name)=='string' and #account_name<=512 and not account_name:find('[%z%c]'))
    report.account_name_present=account_name~=''
    assert(type(grant.vid)=='string' and grant.vid:match('^[1-9]%d*$') and #grant.vid<=20)
    for _i,key in ipairs({'accessToken','refreshToken','deviceId'}) do assert(type(grant[key])=='string' and #grant[key]>=8) end
    assert(math.abs(os.time()-input.now)<=180 and math.floor((os.time()+28800)/86400)==math.floor((input.now+28800)/86400))
    assert(#input.profile_months>=1 and #input.profile_months<=24 and #input.details==6 and #input.rules<=29)
    local mock=os.getenv('WEREAD_STATISTICS_MOCK')
    assert((input.mock_port~=nil)==(mock~=nil))
    if mock then
        assert(tonumber(mock)==input.mock_port and grant.vid=='900000' and grant.accessToken=='mock-native-access'
            and grant.refreshToken=='mock-native-refresh' and grant.deviceId=='eink334691225'..string.rep('1',19))
    end
    local source=home..'/plugins/weread.koplugin';package.path=source..'/?.lua;'..package.path
    G_defaults=require('luadefaults'):open()
    G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
    G_reader_settings:saveSetting('language','zh_CN');require('gettext').changeLang('zh_CN')
    G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
    local Device=require('device');require('document/canvascontext'):init(Device)
    Device.screen.shot=function() report.screenshots=report.screenshots+1;error('private screenshots disabled',0) end
    pcall(ffi.cdef,'int memfd_create(const char *, unsigned int);')
    local function anonymous(data)
        local fd=tonumber(ffi.C.memfd_create('weread-statistics-probe',1));assert(fd>=0);descriptors[#descriptors+1]=fd
        local bytes='return '..require('dump')(data,nil,true);local offset=0
        while offset<#bytes do
            local n=tonumber(ffi.C.write(fd,ffi.cast('const char *',bytes)+offset,#bytes-offset));assert(n>0);offset=offset+n
        end
        return '/proc/self/fd/'..fd
    end
    local auth={auth_schema_version=1,auth_epoch=1,account={user_vid=grant.vid,name=account_name},cookies={},api_key=''}
    local scope_path=anonymous(auth);local saved={}
    for key,value in pairs(grant) do saved[key]=value end
    saved.epoch,saved.verified_at,saved.book_count=1,os.time(),0
    local grant_path=anonymous({revision=1,authorization=saved})
    local Settings=require('weread.lib.settings');local new_settings=Settings.new
    function Settings:new()
        local value=new_settings(self);assert(not value.mock_endpoint)
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
        value.settings_file=scope_path
        assert(value.store.file==home..'/settings/weread.lua')
        return value
    end
    local Credentials=require('weread.lib.native_credentials');local new_credentials=Credentials.new
    function Credentials:new(settings,...)
        local value=new_credentials(self,settings,...);value.path=grant_path;return value
    end
    report.anonymous_credentials=true
    pcall(ffi.cdef,'void *mmap(void *, unsigned long, int, int, int, long); int munmap(void *, unsigned long);')
    memory=ffi.C.mmap(nil,4096,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1));counters=ffi.cast('int *',memory)
    local parent=tonumber(ffi.C.getpid());local allowed={}
    report.request_counts={}
    for index,row in ipairs(input.rules) do
        assert(row.mode=='weekly' or row.mode=='monthly' or row.mode=='annually' or row.mode=='overall')
        assert(type(row.base_time)=='number' and row.base_time>=0 and row.base_time%1==0 and (row.count==1 or row.count==2))
        local url='https://i.weread.qq.com/readdata/detail?baseTime='..string.format('%.0f',row.base_time)..'&mode='..row.mode
        assert(not allowed[url]);allowed[url]={slot=index-1,limit=row.count};report.request_counts[index]=0
    end
    local function classify(options)
        local headers=options.headers or {};local rule=allowed[options.url]
        if rule and mode=='live' and options.method=='GET' and options.body==nil and options.skip_cookie==true
            and options.persist_response_cookies==false and options.sensitive==true and headers.vid==grant.vid
            and headers.accessToken==grant.accessToken and not headers.Cookie and not headers.Authorization then return rule end
    end
    local first=next(allowed)
    local valid={url=first,method='GET',skip_cookie=true,persist_response_cookies=false,sensitive=true,
        headers={vid=grant.vid,accessToken=grant.accessToken}}
    assert((classify(valid)~=nil)==(mode=='live'))
    for _i,change in ipairs({'url','method','body','cookie','owner','token','authorization','skip','persist','sensitive'}) do
        local test={};for key,item in pairs(valid) do test[key]=item end
        test.headers={vid=grant.vid,accessToken=grant.accessToken}
        if change=='url' then test.url='https://i.weread.qq.com/login' elseif change=='method' then test.method='POST'
        elseif change=='body' then test.body='{}' elseif change=='cookie' then test.headers.Cookie='forbidden'
        elseif change=='owner' then test.headers.vid='0' elseif change=='token' then test.headers.accessToken='invalid'
        elseif change=='authorization' then test.headers.Authorization='forbidden' elseif change=='skip' then test.skip_cookie=false
        elseif change=='persist' then test.persist_response_cookies=true else test.sensitive=false end
        assert(not classify(test))
    end
    report.transport_guard_selftest=true
    local Client=require('weread.lib.client');local request=Client.request
    function Client:request(options)
        local rule=classify(options)
        if not rule or counters[rule.slot]>=rule.limit or tonumber(ffi.C.getpid())==parent then
            counters[64]=counters[64]+1;error('statistics read scope rejected',0)
        end
        counters[rule.slot]=counters[rule.slot]+1;counters[65]=1
        return request(self,options)
    end
    local Worker=require('weread.lib.memory_worker');local start=Worker.start;local pids={}
    function Worker:start(...)
        local result={start(self,...)}
        if self.job and self.job.pid then pids[#pids+1]={pid=self.job.pid,runner=self.runner};assert(#pids<=32) end
        return unpack(result)
    end
    local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
    for _i,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
    assert(#Loader.enabled_plugins==1)
    local FM=require('apps/filemanager/filemanager');FM:showFiles(home..'/books');local browser=assert(FM.instance)
    plugin=assert(browser.weread);assert(plugin.ui==browser and not browser.document)
    report.native_filemanager_host=true
    plugin.isNetworkOnline,plugin.isNetworkConnected=function() return mode=='live' end,function() return mode=='live' end
    assert(Credentials:new(plugin.settings):read().vid==grant.vid)
    local UI=require('ui/uimanager');local socket=require('socket')
    local function pump(predicate)
        local deadline=socket.gettime()+80
        while plugin.profile_request or plugin.statistics_request or predicate and not predicate() do
            assert(socket.gettime()<deadline);UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
        end
    end
    local function same(a,b)
        if type(a)~=type(b) then return false end
        if type(a)=='number' then return math.abs(a-b)<=1e-9 end
        if type(a)~='table' then return a==b end
        for key,item in pairs(a) do if not same(item,b[key]) then return false end end
        for key in pairs(b) do if a[key]==nil then return false end end
        return true
    end
    local function fields(actual,expected)
        for key,item in pairs(expected) do assert(same(actual[key],item),'private statistics view mismatch') end
    end
    local function paint(view)
        local size=view[1]:getSize();assert(size.h==Device.screen:getHeight() and size.w<=Device.screen:getWidth())
        UI:forceRePaint();report.validated_views=report.validated_views+1
    end
    report.phase='profile';plugin:showProfile();pump()
    if mode=='live' then
        plugin._profile_view._profile_buttons[1].callback()
        pump(function() return plugin._profile_goal_dialog~=nil end)
        local goal=assert(plugin._profile_goal_dialog);goal:setInputText('45');goal.buttons[1][2].callback();pump()
    end
    local profile=assert(plugin._profile_view);fields(profile.data,input.profile_display)
    assert(profile.data.cached==(mode=='reopen'))
    report.calendar_days=#profile.data.days;report.calendar_cells=#profile._calendar_cells
    assert(report.calendar_cells==math.ceil((profile.data.first_weekday-1+report.calendar_days)/7)*7)
    local snapshot=assert(plugin.library_db:getProfileState('statistics'))
    assert(snapshot.source_kind=='native' and same(snapshot.months,input.profile_snapshot))
    report.profile_months=#input.profile_months;report.profile_matches=true;paint(profile)
    local expected_name=account_name~='' and account_name or require('weread.lib.plugin_util').tr('Unknown account')
    assert(profile.data.account_name==expected_name)
    local function name_widget(widget)
        if widget.text==expected_name and widget.face==profile.fonts.card_title then return widget end
        for _i,child in ipairs(widget) do local found=name_widget(child);if found then return found end end
    end
    local label=assert(name_widget(profile))
    local label_size=label:getSize()
    assert(label_size.w>0 and label_size.w<=profile.content_width and label_size.h>0)
    report.account_name_matches=true
    assert(label.use_xtext and label._xshaping and #label._xshaping>0)
    for _i,glyph in ipairs(label._xshaping) do assert(glyph.no_drawing or glyph.glyph>0,'profile name has a missing glyph') end
    report.account_name_glyphs=true
    assert(plugin.library_db:getProfileState('goal').minutes==45);report.local_goal_readback=true
    profile._profile_buttons[2].callback();pump(function() return plugin._read_stats_view~=nil end)
    for index,expected in ipairs(input.details) do
        report.phase=({'monthly','history','return_month','weekly','annually','overall'})[index]
        if index==2 then plugin._read_stats_view._nav_buttons[1].callback();pump()
        elseif index==3 then plugin._read_stats_view._nav_buttons[2].callback();pump()
        elseif index>=4 then plugin._read_stats_view._tab_buttons[({1,3,4})[index-3]].callback();pump() end
        local view=assert(plugin._read_stats_view);fields(view.data,mode=='live' and expected.display or expected.offline_display)
        assert(view.data.cached==(mode=='reopen'))
        local key='reading-statistics:'..expected.mode..':'..string.format('%.0f',expected.raw.baseTime)
        local cache=assert(plugin.library_db:getProfileState(key))
        assert(cache.source_kind=='native' and same(cache.raw,mode=='live' and expected.raw or expected.offline_raw))
        paint(view);report.detail_periods=report.detail_periods+1
    end
    report.detail_views_match=true
    plugin:closeWeReadUI();plugin.settings:flush();G_reader_settings:flush()
    for _i,worker in ipairs(pids) do assert(worker.runner.done(worker.pid)) end
    assert(not plugin.profile_request and not plugin.statistics_request);report.workers_reaped=true
    local db=assert(plugin.library_db:open());local _,name,file=db:rowexec('PRAGMA database_list')
    assert(name=='main' and file==plugin.library_db:databasePath() and lfs.symlinkattributes(file,'mode')=='file');db:close()
    report.file_backed_sqlite=true
    local other=require('weread.lib.library_db'):new{data_dir=plugin.settings.data_dir,get=function(_self,key,default)
        if key=='account' then return {user_vid=grant.vid=='90009999' and '90009998' or '90009999'} end
        return default
    end}
    assert(other:databasePath()~=plugin.library_db:databasePath() and not other:getProfileState('statistics') and not other:getProfileState('goal'))
    report.cache_account_scoped=true
    report.phase='audit'
    local function audit(path)
        for entry in lfs.dir(path) do
            if entry~='.' and entry~='..' and not (path==home and entry=='plugins') then
                local filename=path..'/'..entry;local info=assert(lfs.symlinkattributes(filename))
                if info.mode=='directory' then audit(filename)
                elseif info.mode=='file' then
                    report.profile_files_audited=report.profile_files_audited+1;assert(report.profile_files_audited<=512 and info.size<=4*1024*1024)
                    local handle=assert(io.open(filename,'rb'));local bytes=handle:read('*a');handle:close()
                    for _i,key in ipairs({'accessToken','refreshToken','deviceId'}) do assert(not bytes:find(grant[key],1,true)) end
                else error('unexpected profile entry',0) end
            end
        end
    end
    audit(home);report.credential_file_audit=true
    assert(counters[64]==0)
    for index,row in ipairs(input.rules) do assert(counters[index-1]==(mode=='live' and row.count or 0)) end
    report.phase,report.result='complete','PASS'
end)
if plugin then pcall(plugin.closeWeReadUI,plugin) end
if counters then
    for index=1,#report.request_counts do report.request_counts[index]=tonumber(counters[index-1]) end
    report.forbidden_requests=tonumber(counters[64]);report.worker_http_child=counters[65]==1
    ffi.C.munmap(memory,4096)
end
for _i,fd in ipairs(descriptors) do ffi.C.close(fd) end
if not ok then
    report.result='UNVERIFIED';report.failed_line=tonumber(type(reason)=='string' and reason:match('owner_statistics_probe%.lua:(%d+):')) or 0
end
io.stdout:write('\nWEREAD_OWNER_STATISTICS_RESULT='..json.encode(report)..'\n')
os.exit(ok and 0 or 1)
