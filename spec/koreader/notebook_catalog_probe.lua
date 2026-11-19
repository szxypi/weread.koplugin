-- Isolated native plugin catalog acceptance. All private data stays in tmpfs and pipes.
require('ffi').log=function() end
require('setupkoenv')
local ffi,json=require('ffi'),require('json');require('ffi/posix_h')
local mode=arg[1]
local report={result='UNVERIFIED',mode=mode,phase='init',anonymous_credentials=false,transport_guard=false,
    worker_heartbeat=false,native_filemanager=false,menu_navigation=false,file_sqlite=false,account_isolation=false,
    cache_session_free=false,workers_reaped=false,credential_audit=false,pages=0,books=0,requests=0,forbidden=0,failed_line=0}
local plugin,memory,counters,output;local descriptors={}
local ok,reason=pcall(function()
    local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/weread%-notebook%-[%w_]+/profile$'))
    assert(mode=='live' or mode=='reopen')
    local raw=assert(io.stdin:read(8*1024*1024+1));assert(#raw<=8*1024*1024)
    local input=json.decode(raw);local grant=assert(input.credentials);local synthetic=input.synthetic==true
    assert(synthetic==(os.getenv('WEREAD_NOTEBOOK_SYNTHETIC')=='1'))
    if synthetic then assert(grant.vid=='900000' and grant.accessToken=='synthetic-notebook-access'
        and grant.refreshToken=='synthetic-notebook-refresh' and grant.deviceId==string.rep('1',32)) end
    local source=home..'/plugins/weread.koplugin';package.path=source..'/?.lua;'..package.path
    local Data=require('weread.lib.notebook_catalog')
    local codec={json_encode=function(_self,v) return json.encode(v) end,json_decode=function(_self,v) return json.decode(v) end}
    local expected=Data.project(codec,input.source,input.now)
    assert(input.owner==grant.vid and #expected.books>0)
    G_defaults=require('luadefaults'):open();G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
    G_reader_settings:saveSetting('language','zh_CN');require('gettext').changeLang('zh_CN')
    G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
    local Device=require('device');require('document/canvascontext'):init(Device)
    pcall(ffi.cdef,'int memfd_create(const char *, unsigned int); void *mmap(void *, unsigned long, int, int, int, long); int munmap(void *, unsigned long);')
    local function anonymous(data)
        local fd=tonumber(ffi.C.memfd_create('weread-notebook',1));assert(fd>=0);descriptors[#descriptors+1]=fd
        local bytes='return '..require('dump')(data,nil,true);local offset=0
        while offset<#bytes do
            local n=tonumber(ffi.C.write(fd,ffi.cast('const char *',bytes)+offset,#bytes-offset));assert(n>0);offset=offset+n
        end
        return '/proc/self/fd/'..fd
    end
    local auth={auth_schema_version=1,auth_epoch=1,account={user_vid=grant.vid,name=''},cookies={},api_key=''}
    local scope_path=anonymous(auth);local saved={}
    for key,v in pairs(grant) do saved[key]=v end
    saved.epoch,saved.verified_at,saved.book_count=1,os.time(),0
    local grant_path=anonymous{revision=1,authorization=saved}
    local Settings=require('weread.lib.settings');local new_settings=Settings.new
    function Settings:new()
        local value=new_settings(self);assert(not value.mock_endpoint)
        local flush=value.store.flush
        value.store.flush=function(store,...)
            local held={};local fields={'account','cookies','api_key','wr_ticket','wr_wrpa','device_fingerprint'}
            for _i,key in ipairs(fields) do held[key]=store.data[key];store.data[key]=nil end
            local result={pcall(flush,store,...)}
            for _i,key in ipairs(fields) do store.data[key]=held[key] end
            assert(result[1]);return unpack(result,2)
        end
        for key,v in pairs(auth) do value.store:saveSetting(key,v) end
        value.settings_file=scope_path;return value
    end
    local Credentials=require('weread.lib.native_credentials');local new_credentials=Credentials.new
    function Credentials:new(settings,...)
        local value=new_credentials(self,settings,...);value.path=grant_path;return value
    end
    report.anonymous_credentials=true
    memory=ffi.C.mmap(nil,4096,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1));counters=ffi.cast('int *',memory)
    local parent=tonumber(ffi.C.getpid());local target='https://i.weread.qq.com/user/notebooks?count=100'
    local function allowed(options)
        local headers=options.headers or {}
        return mode=='live' and options.url==target and options.method=='GET' and options.body==nil
            and options.skip_cookie==true and options.persist_response_cookies==false and options.sensitive==true
            and headers.vid==grant.vid and headers.accessToken==grant.accessToken and not headers.Cookie and not headers.Authorization
    end
    local valid={url=target,method='GET',skip_cookie=true,persist_response_cookies=false,sensitive=true,
        headers={vid=grant.vid,accessToken=grant.accessToken}}
    assert(allowed(valid)==(mode=='live'))
    for _,key in ipairs({'url','method','body','cookie','owner','token','authorization','skip','persist','sensitive'}) do
        local test={};for name,v in pairs(valid) do test[name]=v end
        test.headers={vid=grant.vid,accessToken=grant.accessToken}
        if key=='url' then test.url='https://i.weread.qq.com/login' elseif key=='method' then test.method='POST'
        elseif key=='body' then test.body='{}' elseif key=='cookie' then test.headers.Cookie='forbidden'
        elseif key=='owner' then test.headers.vid='0' elseif key=='token' then test.headers.accessToken='forbidden'
        elseif key=='authorization' then test.headers.Authorization='forbidden' elseif key=='skip' then test.skip_cookie=false
        elseif key=='persist' then test.persist_response_cookies=true else test.sensitive=false end
        assert(not allowed(test))
    end
    report.transport_guard=true
    local Client=require('weread.lib.client');local request=Client.request
    function Client:request(options)
        if not allowed(options) or counters[0]>=1 or tonumber(ffi.C.getpid())==parent then
            counters[1]=counters[1]+1;error('notebook read scope rejected',0)
        end
        counters[0]=counters[0]+1
        if synthetic then require('socket').sleep(.35);return json.encode(input.source),200 end
        return request(self,options)
    end
    local fetch=Data.fetch
    function Data.fetch(client,access,options) options=options or {};options.now=input.now;return fetch(client,access,options) end
    local Worker=require('weread.lib.memory_worker');local start=Worker.start;local workers={}
    function Worker:start(...)
        local result={start(self,...)}
        if self.job then workers[#workers+1]={pid=self.job.pid,runner=self.runner} end
        return unpack(result)
    end
    local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
    for _i,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
    assert(#Loader.enabled_plugins==1)
    local FM=require('apps/filemanager/filemanager');FM:showFiles(home);plugin=assert(FM.instance.weread)
    assert(plugin.ui==FM.instance and not plugin.ui.document);report.native_filemanager=true
    plugin.isNetworkOnline=function() return mode=='live' end;plugin.isNetworkConnected=plugin.isNetworkOnline
    local UI,socket=require('ui/uimanager'),require('socket')
    local function tick() UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01) end
    local function wait(predicate)
        local deadline=socket.gettime()+60
        while not predicate() do assert(socket.gettime()<deadline);tick() end
    end
    local function same(a,b)
        if type(a)~=type(b) then return false end
        if type(a)~='table' then return a==b end
        for key,v in pairs(a) do if not same(v,b[key]) then return false end end
        for key in pairs(b) do if a[key]==nil then return false end end
        return true
    end
    report.phase='open'
    local tr=require('weread.lib.plugin_util').tr;local entry
    for _,item in ipairs(plugin:getMainMenuItems()) do if item.text==tr('My notebooks') then entry=item end end
    assert(entry and entry.callback);entry.callback()
    local owner=assert(plugin._notebook_owner);local menu=assert(plugin._notebook_menu)
    if mode=='live' then
        assert(owner.context and owner.worker.job)
        local heartbeat=false;UI:scheduleIn(.1,function() heartbeat=true end);wait(function() return heartbeat end)
        report.worker_heartbeat=true;wait(function() return not owner.context end)
    else assert(not owner.context and not owner.worker);report.worker_heartbeat=true end
    assert(same(owner.value,expected))
    report.phase='views'
    for page=1,menu.page_num do menu:onGotoPage(page);UI:forceRePaint();report.pages=report.pages+1 end
    assert(#menu.item_table==#expected.books+2)
    for index,book in ipairs(expected.books) do
        local item=menu.item_table[index+2];assert(item.text==book.title and item.mandatory==book.author)
        menu:onGotoPage(menu:getPageNumber(index+2));report.books=report.books+1
    end
    -- Exercise each per-book destination without additional network requests.
    local chosen,position
    local Marks=require('weread.lib.my_cloud_marks')
    for index,book in ipairs(expected.books) do if Marks.display_id(book.bookId) then chosen=book;position=index+2;break end end
    assert(chosen);plugin.isNetworkOnline=function() return false end
    for index,variant in ipairs({'highlights','thoughts','bookmarks'}) do
        menu:onGotoPage(menu:getPageNumber(position));menu:onMenuSelect(menu.item_table[position])
        local popup=assert(menu._shelf_popup);assert(#popup.buttons==3)
        popup.buttons[index][1].callback();local child=assert(plugin._my_marks_owner)
        assert(child.id==chosen.bookId and not child.context and (variant~='thoughts' or child.thoughts)
            and (variant~='bookmarks' or child.bookmarks));plugin:cancelMyCloudMarks()
    end
    report.menu_navigation=true
    local Store=require('weread.lib.notebook_catalog_store')
    assert(same(Store:new(plugin.library_db,plugin.client,plugin.library_db:accountKey()):read(),expected))
    local db=assert(plugin.library_db:open());local _,name,path=db:rowexec('PRAGMA database_list')
    assert(name=='main' and path==plugin.library_db:databasePath())
    local payload=db:rowexec("SELECT payload FROM profile_state WHERE name='notebook_catalog'");db:close()
    for _,field in ipairs({'accessToken','refreshToken','deviceId','synckey','userVid'}) do assert(not payload:find('"'..field..'"',1,true)) end
    report.file_sqlite,report.cache_session_free=true,true
    local other=require('weread.lib.library_db'):new{data_dir=plugin.settings.data_dir,get=function(_self,key,default)
        return key=='account' and {user_vid=grant.vid=='900099' and '900098' or '900099'} or default
    end}
    assert(other:databasePath()~=plugin.library_db:databasePath()
        and not Store:new(other,plugin.client,other:accountKey()):read());report.account_isolation=true
    local stale=menu.item_table[1].callback;plugin:closeWeReadUI();assert(not plugin._notebook_menu and not plugin._notebook_owner)
    stale();assert(not plugin._notebook_menu and not plugin.busy_message)
    plugin.settings:flush();G_reader_settings:flush()
    for _,worker in ipairs(workers) do wait(function() return worker.runner.done(worker.pid) end) end
    report.workers_reaped=true;report.phase='audit'
    local lfs=require('libs/libkoreader-lfs')
    local function audit(directory)
        for filename_part in lfs.dir(directory) do
            if filename_part~='.' and filename_part~='..' and not (directory==home and filename_part=='plugins') then
                local filename=directory..'/'..filename_part;local info=assert(lfs.symlinkattributes(filename))
                if info.mode=='directory' then audit(filename) else
                    assert(info.mode=='file' and info.size<=16*1024*1024)
                    local f=assert(io.open(filename,'rb'));local bytes=f:read('*a');f:close()
                    for _,key in ipairs({'accessToken','refreshToken','deviceId'}) do assert(not bytes:find(grant[key],1,true)) end
                end
            end
        end
    end
    audit(home);report.credential_audit=true
    assert(counters[0]==(mode=='live' and 1 or 0) and counters[1]==0)
    report.phase,report.result='complete','PASS';output={model=expected,native=owner.value,requests=tonumber(counters[0]),ui=report}
end)
if plugin then pcall(plugin.closeWeReadUI,plugin) end
if counters then report.requests,report.forbidden=tonumber(counters[0]),tonumber(counters[1]);ffi.C.munmap(memory,4096) end
for _,fd in ipairs(descriptors) do ffi.C.close(fd) end
if not ok then report.failed_line=tonumber(type(reason)=='string' and reason:match('notebook_catalog_probe%.lua:(%d+):')) or 0 end
io.stdout:write('\nWEREAD_NOTEBOOK_RESULT='..json.encode(output or {ui=report})..'\n')
os.exit(ok and 0 or 1)
