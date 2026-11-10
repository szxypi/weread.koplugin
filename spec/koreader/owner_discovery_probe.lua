-- Actual FileManager plugin, statistics UI and SQLite; private tmpfs only.
require('ffi').log=function() end
require('setupkoenv')
local ffi=require('ffi');require('ffi/posix_h')
local json=require('json')
local mode=arg[1]
local report={result='UNVERIFIED',phase='init',mode=mode,anonymous_credentials=false,transport_guard_selftest=false,
    file_backed_sqlite=false,ui_projection_matches=false,workers_reaped=false,credential_file_audit=false,
    native_filemanager_host=false,cache_account_scoped=false,cache_session_free=false,pagination_matches=false,
    worker_http_child=false,validated_views=0,samples=0,profile_files_audited=0,screenshots=0,forbidden_requests=0,
    failed_line=0,request_counts=json.decode('[0]'),batch_sizes=json.decode('[]')}
local private={sources=json.decode('[]'),views=json.decode('[]')}
local plugin,counters,memory
local descriptors={}
local ok,reason=pcall(function()
    assert(mode=='live' or mode=='reopen')
    local home=assert(os.getenv('KO_HOME'))
    assert(ffi.os=='Linux' and home:match('^/dev/shm/weread%-discovery%-[%w_]+/profile$'))
    local lfs=require('libs/libkoreader-lfs')
    assert((lfs.symlinkattributes(home..'/weread')~=nil)==(mode=='reopen'))
    local raw=assert(io.stdin:read(2*1024*1024+1));assert(#raw<=2*1024*1024)
    local input=json.decode(raw);local grant=assert(input.credentials)
    assert(type(grant.vid)=='string' and grant.vid:match('^[1-9]%d*$') and #grant.vid<=20)
    for _i,key in ipairs({'accessToken','refreshToken','deviceId'}) do assert(type(grant[key])=='string' and #grant[key]>=8) end
    assert(type(input.samples)=='table' and #input.samples>=3 and #input.samples<=6)
    assert(input.keyword=='三体' and input.book_id:match('^[1-9]%d*$') and #input.book_id<=20)
    local mock=os.getenv('WEREAD_DISCOVERY_MOCK')
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
        local fd=tonumber(ffi.C.memfd_create('weread-discovery-probe',1));assert(fd>=0);descriptors[#descriptors+1]=fd
        local bytes='return '..require('dump')(data,nil,true);local offset=0
        while offset<#bytes do
            local n=tonumber(ffi.C.write(fd,ffi.cast('const char *',bytes)+offset,#bytes-offset));assert(n>0);offset=offset+n
        end
        return '/proc/self/fd/'..fd
    end
    local auth={auth_schema_version=1,auth_epoch=1,account={user_vid=grant.vid,name=''},cookies={},api_key=''}
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
    local Protocol=require('weread.lib.protocol')
    local function url(kind,cursor,session)
        local params={maxIdx=cursor,count=20};local path
        if kind=='search' then path='/store/search';params.keyword=input.keyword;params.scope=10
        elseif kind=='similar' then path='/book/detailinfo';params.bookId=input.book_id;params.listtypes=2;params.synckey=0;params.sessionId=session
        else assert(kind=='recommend');path='/book/recommend' end
        return 'https://i.weread.qq.com'..path..'?'..Protocol.sorted_query(params)
    end
    report.request_counts={}
    for index,row in ipairs(input.samples) do
        report.request_counts[index]=0
        if row.cursor==0 or row.kind~='similar' then allowed[url(row.kind,row.cursor)]={slot=index-1,limit=1} end
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
            counters[64]=counters[64]+1;error('discovery read scope rejected',0)
        end
        counters[rule.slot]=counters[rule.slot]+1;counters[65]=1
        return request(self,options)
    end
    local Source=require('weread.lib.discovery_source');local project=Source.project
    function Source.project(client,kind,data,cursor)
        local value=project(client,kind,data,cursor);value._probe_source=data;return value
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
    local function same(a,b)
        if type(a)~=type(b) then return false end
        if type(a)=='number' then return math.abs(a-b)<=1e-9 end
        if type(a)~='table' then return a==b end
        for key,item in pairs(a) do if not same(item,b[key]) then return false end end
        for key in pairs(b) do if a[key]==nil then return false end end
        return true
    end
    local function fields(actual,expected)
        for key,item in pairs(expected) do assert(same(actual[key],item),'private bookstore view mismatch') end
    end
    local function paint(view)
        local size=view[1]:getSize();assert(size.h==Device.screen:getHeight() and size.w<=Device.screen:getWidth())
        UI:forceRePaint();report.validated_views=report.validated_views+1
    end
    -- Cover images are a separate case: this probe checks native book cards,
    -- field bindings, query batches and SQLite without additional cover GETs.
    plugin.fetchVisibleShelfCovers=function() end
    plugin:showBookstore()
    local function press(label)
        for _,button in ipairs(plugin.shelf_view._action_buttons) do
            if button.text==require('weread.lib.plugin_util').tr(label) then button.callback();return end
        end
        error('missing bookstore action',0)
    end
    local function wait(predicate)
        local deadline=socket.gettime()+80
        while plugin.discovery_loading or predicate and not predicate() do
            assert(socket.gettime()<deadline);UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
        end
    end
    local function verify(sample)
        local state=assert(plugin.discovery_state);assert(state.kind==sample.kind and state.cursor==sample.cursor)
        assert(state.cached==(mode=='reopen') or mode=='live' and state.cached==nil)
        assert(#state.books==#sample.expected.books and #plugin.shelf_view.books==#state.books)
        local view={kind=state.kind,cursor=state.cursor,next_cursor=state.next_cursor,has_more=state.has_more,
            cached=state.cached==true,books=json.decode('[]')}
        for index,book in ipairs(state.books) do
            local row={}
            for _,key in ipairs({'bookId','title','author','cover','category','searchIdx'}) do row[key]=book[key] end
            fields(plugin.shelf_view.books[index],row);view.books[#view.books+1]=row
        end
        private.views[#private.views+1]=view
        if mode=='live' then
            private.sources[#private.sources+1]={kind=state.kind,cursor=state.cursor,source=assert(state._probe_source)}
        end
        assert(state.next_cursor==sample.expected.next_cursor)
        if mode=='live' then assert(state.has_more==sample.expected.has_more)
        else
            local next_saved=false
            for _,other in ipairs(input.samples) do
                if other.kind==sample.kind and other.cursor==sample.expected.next_cursor and other.cursor>sample.cursor then next_saved=true end
            end
            assert(state.has_more==(sample.expected.has_more and next_saved))
        end
        paint(plugin.shelf_view)
    end
    if mode=='reopen' then
        local last=input.samples[#input.samples]
        assert(plugin.discovery_state.cached and plugin.discovery_state.kind==last.kind)
        verify(last)
    end
    for index,sample in ipairs(input.samples) do
        report.phase=sample.kind
        if sample.cursor==0 then
            if sample.kind=='search' then
                press('Search WeRead');wait(function() return UI:getTopmostVisibleWidget().setInputText~=nil end)
                local dialog=UI:getTopmostVisibleWidget();dialog:setInputText(input.keyword);dialog.buttons[1][2].callback()
            elseif sample.kind=='similar' then plugin:showSimilarBooks{bookId=input.book_id,title=input.book_title}
            else press('For you') end
        else
            if mode=='live' and sample.kind=='similar' then
                local session=assert(plugin.discovery_state.session_id);assert(#session>0 and #session<=512)
                allowed[url(sample.kind,sample.cursor,session)]={slot=index-1,limit=1}
            end
            press('Next batch')
        end
        wait(function() return plugin.discovery_state and plugin.discovery_state.kind==sample.kind and plugin.discovery_state.cursor==sample.cursor end)
        verify(sample);report.batch_sizes[index]=#sample.expected.books
        if mode=='reopen' and sample.cursor>0 then
            press('Previous batch');wait(function() return plugin.discovery_state.cursor==0 end)
            verify(input.samples[index-1])
        end

    end
    report.samples=#input.samples;report.ui_projection_matches=true;report.pagination_matches=true
    local db=assert(plugin.library_db:open());local stmt=db:prepare('SELECT payload FROM discovery_cache');local row=stmt:step()
    local records=0
    while row do
        records=records+1
        assert(not row[1]:find('session_id',1,true) and not row[1]:find('source_revision',1,true))
        row=stmt:step()
    end
    stmt:close();db:close();assert(records==3);report.cache_session_free=true
    plugin:closeWeReadUI();plugin.settings:flush();G_reader_settings:flush()
    for _i,worker in ipairs(pids) do assert(worker.runner.done(worker.pid)) end
    assert(not plugin.discovery_loading and not plugin.discovery_request_context);report.workers_reaped=true
    local persisted_db=assert(plugin.library_db:open());local _,name,file=persisted_db:rowexec('PRAGMA database_list')
    assert(name=='main' and file==plugin.library_db:databasePath() and lfs.symlinkattributes(file,'mode')=='file');persisted_db:close()
    report.file_backed_sqlite=true
    local other=require('weread.lib.library_db'):new{data_dir=plugin.settings.data_dir,get=function(_self,key,default)
        if key=='account' then return {user_vid=grant.vid=='90009999' and '90009998' or '90009999'} end
        return default
    end}
    assert(other:databasePath()~=plugin.library_db:databasePath() and not require('weread.lib.discovery_cache'):new(other,plugin.client):read())
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
    for index in ipairs(input.samples) do assert(counters[index-1]==(mode=='live' and 1 or 0)) end
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
    report.result='UNVERIFIED';report.failed_line=tonumber(type(reason)=='string' and reason:match('owner_discovery_probe%.lua:(%d+):')) or 0
end
io.stdout:write('\nWEREAD_OWNER_DISCOVERY_PRIVATE='..json.encode(private))
io.stdout:write('\nWEREAD_OWNER_DISCOVERY_RESULT='..json.encode(report)..'\n')
os.exit(ok and 0 or 1)
