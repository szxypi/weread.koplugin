-- Actual FileManager and bookstore UI; private responses stay in a tmpfs profile.
require('ffi').log=function() end
require('setupkoenv')
local ffi=require('ffi');require('ffi/posix_h')
local json=require('json')
local report={result='UNVERIFIED',phase='init',suggestions=0,books=0,requests=0,forbidden=0,
    native_host=false,menu_matches=false,search_matches=false,workers_reaped=false,credential_audit=false,screenshots=0}
local descriptors={};local plugin,memory,counters
local ok,reason=pcall(function()
    local home=assert(os.getenv('KO_HOME'))
    assert(ffi.os=='Linux' and home:match('^/dev/shm/weread%-suggest%-[%w_]+/profile$'))
    local raw=assert(io.stdin:read(1024*1024+1));assert(#raw<=1024*1024)
    local input=json.decode(raw)
    local grant=assert(input.credentials);local words=assert(input.words);local expected=assert(input.search)
    assert(type(grant.vid)=='string' and grant.vid:match('^[1-9]%d*$') and #words>0 and #words<=10)
    for _,key in ipairs({'accessToken','refreshToken','deviceId'}) do assert(type(grant[key])=='string' and #grant[key]>=8) end
    assert(input.keyword=='科学' and words[1] and type(expected.books)=='table' and #expected.books<=100)
    local source=home..'/plugins/weread.koplugin';package.path=source..'/?.lua;'..package.path
    G_defaults=require('luadefaults'):open()
    G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
    G_reader_settings:saveSetting('language','zh_CN');require('gettext').changeLang('zh_CN')
    G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
    local Device=require('device');require('document/canvascontext'):init(Device)
    Device.screen.shot=function() report.screenshots=report.screenshots+1;error('screenshots disabled',0) end
    pcall(ffi.cdef,'int memfd_create(const char *, unsigned int);')
    local function anonymous(data)
        local fd=tonumber(ffi.C.memfd_create('weread-suggestions',1));assert(fd>=0);descriptors[#descriptors+1]=fd
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
    local Settings=require('weread.lib.settings');local original_settings=Settings.new
    function Settings:new()
        local value=original_settings(self);assert(not value.mock_endpoint)
        local flush=value.store.flush
        value.store.flush=function(store,...)
            local held={};local fields={'account','cookies','api_key','wr_ticket','wr_wrpa','device_fingerprint'}
            for _,key in ipairs(fields) do held[key]=store.data[key];store.data[key]=nil end
            local result={pcall(flush,store,...)}
            for _,key in ipairs(fields) do store.data[key]=held[key] end
            assert(result[1]);return unpack(result,2)
        end
        for key,item in pairs(auth) do value.store:saveSetting(key,item) end
        value.settings_file=scope_path
        return value
    end
    local Credentials=require('weread.lib.native_credentials');local original_credentials=Credentials.new
    function Credentials:new(settings,...)
        local value=original_credentials(self,settings,...);value.path=grant_path;return value
    end
    pcall(ffi.cdef,'void *mmap(void *, unsigned long, int, int, int, long); int munmap(void *, unsigned long);')
    memory=ffi.C.mmap(nil,4096,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1));counters=ffi.cast('int *',memory)
    local Protocol=require('weread.lib.protocol');local parent=tonumber(ffi.C.getpid())
    local suggest='https://i.weread.qq.com/store/suggest?count=10&keyword='..Protocol.urlencode(input.keyword)
    local search='https://i.weread.qq.com/store/search?'..Protocol.sorted_query{keyword=words[1],scope=10,count=20,maxIdx=0}
    local Client=require('weread.lib.client');local request=Client.request
    function Client:request(options)
        local headers=options.headers or {};local slot=options.url==suggest and 0 or options.url==search and 1 or nil
        if not slot or options.method~='GET' or options.body~=nil or options.skip_cookie~=true
            or options.persist_response_cookies~=false or options.sensitive~=true or headers.vid~=grant.vid
            or headers.accessToken~=grant.accessToken or headers.Cookie or headers.Authorization
            or counters[slot]~=0 or tonumber(ffi.C.getpid())==parent then
            counters[2]=counters[2]+1;error('request rejected',0)
        end
        counters[slot]=counters[slot]+1
        return request(self,options)
    end
    local Worker=require('weread.lib.memory_worker');local start=Worker.start;local pids={}
    function Worker:start(...)
        local result={start(self,...)}
        if self.job and self.job.pid then pids[#pids+1]={pid=self.job.pid,runner=self.runner} end
        return unpack(result)
    end
    local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
    for _,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
    assert(#Loader.enabled_plugins==1)
    local FM=require('apps/filemanager/filemanager');FM:showFiles(home..'/books')
    local browser=assert(FM.instance);plugin=assert(browser.weread);assert(plugin.ui==browser and not browser.document)
    report.native_host=true
    plugin.isNetworkOnline,plugin.isNetworkConnected=function() return true end,function() return true end
    plugin.fetchVisibleShelfCovers=function() end
    local UI=require('ui/uimanager');local socket=require('socket')
    local function wait(predicate)
        local deadline=socket.gettime()+45
        while not predicate() do
            assert(socket.gettime()<deadline);UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
        end
    end
    plugin:showBookstore();local view=assert(plugin.shelf_view);view.on_search()
    local dialog=assert(view._shelf_popup);dialog:setInputText(input.keyword);dialog.buttons[2][1].callback()
    wait(function() return plugin._discovery_menu~=nil or not plugin.search_suggestions_job end)
    local menu=assert(plugin._discovery_menu);assert(#menu.item_table==#words)
    for index,word in ipairs(words) do assert(menu.item_table[index].text==word) end
    UI:forceRePaint();report.menu_matches=true;report.suggestions=#words
    menu:onMenuSelect(menu.item_table[1])
    wait(function() return not plugin.discovery_loading and plugin.discovery_state and plugin.discovery_state.kind=='search' end)
    local state=assert(plugin.discovery_state)
    report.phase='search';report.keyword_matches=state.keyword==words[1]
    report.expected_books=#expected.books;report.books=#state.books
    assert(report.keyword_matches and #state.books==#expected.books)
    assert(state.next_cursor==expected.next_cursor and state.has_more==expected.has_more)
    for index,row in ipairs(expected.books) do
        for _,key in ipairs({'bookId','title','author','cover','category'}) do assert(state.books[index][key]==row[key]) end
    end
    assert(#plugin.shelf_view.books==#state.books);UI:forceRePaint();report.search_matches=true;report.books=#state.books
    plugin:closeWeReadUI();plugin.settings:flush();G_reader_settings:flush()
    for _,worker in ipairs(pids) do assert(worker.runner.done(worker.pid)) end
    assert(not plugin.search_suggestions_job and not plugin.discovery_request_context);report.workers_reaped=true
    local lfs=require('libs/libkoreader-lfs');local files=0
    local function audit(path)
        for entry in lfs.dir(path) do
            if entry~='.' and entry~='..' and not (path==home and entry=='plugins') then
                local filename=path..'/'..entry;local info=assert(lfs.symlinkattributes(filename))
                if info.mode=='directory' then audit(filename)
                elseif info.mode=='file' then
                    files=files+1;assert(files<=512 and info.size<=4*1024*1024)
                    local file=assert(io.open(filename,'rb'));local bytes=file:read('*a');file:close()
                    for _,key in ipairs({'accessToken','refreshToken','deviceId'}) do assert(not bytes:find(grant[key],1,true)) end
                else error('unexpected file',0) end
            end
        end
    end
    audit(home);report.credential_audit=true
    assert(counters[0]==1 and counters[1]==1 and counters[2]==0)
    report.phase='complete';report.result='PASS'
end)
if plugin then pcall(plugin.closeWeReadUI,plugin) end
if counters then
    report.requests=tonumber(counters[0]+counters[1]);report.forbidden=tonumber(counters[2]);ffi.C.munmap(memory,4096)
end
for _,fd in ipairs(descriptors) do ffi.C.close(fd) end
if not ok then report.failed_line=tonumber(type(reason)=='string' and reason:match('owner_suggestions_ui%.lua:(%d+):')) or 0 end
io.stdout:write('\nWEREAD_OWNER_SUGGESTIONS_UI='..json.encode(report)..'\n')
os.exit(ok and 0 or 1)
