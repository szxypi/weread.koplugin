-- Real PluginLoader, native Menu/TextViewer and file-backed private tmpfs cache.
require('ffi').log=function() end
require('setupkoenv')
local ffi,json=require('ffi'),require('json');require('ffi/posix_h')
local mode=arg[1]
local report={result='UNVERIFIED',mode=mode,phase='init',anonymous_credentials=false,transport_guard=false,worker_heartbeat=false,
    native_filemanager=false,file_sqlite=false,account_isolation=false,cache_session_free=false,all_quotes=false,
    workers_reaped=false,credential_audit=false,screenshots=0,pages=0,quotes=0,requests=0,forbidden=0,failed_line=0,fault_cases=0}
local plugin,memory,counters,output;local descriptors={}
local ok,reason=pcall(function()
    local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/weread%-marks%-[%w_]+/profile$'))
    assert(mode=='live' or mode=='reopen')
    local raw=assert(io.stdin:read(8*1024*1024+1));assert(#raw<=8*1024*1024)
    local input=json.decode(raw);local grant=assert(input.credentials)
    local synthetic=os.getenv('WEREAD_MARKS_SYNTHETIC')=='1'
    assert((input.synthetic==true)==synthetic)
    if synthetic then assert(grant.vid=='900000' and grant.accessToken=='synthetic-mark-access'
        and grant.refreshToken=='synthetic-mark-refresh' and grant.deviceId==string.rep('1',32)) end
    local thoughts=input.variant=='thoughts';assert(thoughts==(os.getenv('WEREAD_PERSONAL_THOUGHTS')=='1'))
    local source=home..'/plugins/weread.koplugin';package.path=source..'/?.lua;'..package.path
    local Data=require(thoughts and 'weread.lib.my_cloud_thoughts' or 'weread.lib.my_cloud_marks');assert(Data.id(input.book_id))
    local codec={json_encode=function(_self,v) return json.encode(v) end,json_decode=function(_self,v) return json.decode(v) end}
    local expected=Data.project(codec,input.source,input.book_id,input.owner,input.now)
    assert(input.owner==grant.vid)
    G_defaults=require('luadefaults'):open();G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
    G_reader_settings:saveSetting('language','zh_CN');require('gettext').changeLang('zh_CN')
    G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
    local Device=require('device');require('document/canvascontext'):init(Device)
    local screen_shot=Device.screen.shot
    Device.screen.shot=function(self,path)
        assert(synthetic and os.getenv('WEREAD_MARKS_SHOTS') and path:sub(1,#os.getenv('WEREAD_MARKS_SHOTS')+1)==os.getenv('WEREAD_MARKS_SHOTS')..'/')
        report.screenshots=report.screenshots+1;return screen_shot(self,path)
    end
    local function shot(name)
        if synthetic and os.getenv('WEREAD_MARKS_SHOTS') then
            Device.screen:shot(os.getenv('WEREAD_MARKS_SHOTS')..'/'..mode..'-'..name..'.png')
        end
    end
    pcall(ffi.cdef,'int memfd_create(const char *, unsigned int); void *mmap(void *, unsigned long, int, int, int, long); int munmap(void *, unsigned long);')
    local function anonymous(data)
        local fd=tonumber(ffi.C.memfd_create('weread-marks',1));assert(fd>=0);descriptors[#descriptors+1]=fd
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
    local parent=tonumber(ffi.C.getpid())
    local target=thoughts and 'https://i.weread.qq.com/review/list?bookId='..input.book_id..'&listType=11&listMode=0&mine=1&synckey=0&count=20'
        or 'https://i.weread.qq.com/book/bookmarklist?bookId='..input.book_id..'&synckey=0'
    local targets={[target]=20};local request_budget=1
    if thoughts then
        local count,total=20,#expected.reviews
        while count<total do count=math.min(5000,count*2);request_budget=request_budget+1;targets[target:gsub('count=20$','count='..count)]=count end
    end
    local function allowed(options)
        local headers=options.headers or {}
        return mode=='live' and targets[options.url]~=nil and options.method=='GET' and options.body==nil
            and options.skip_cookie==true and options.persist_response_cookies==false and options.sensitive==true
            and headers.vid==grant.vid and headers.accessToken==grant.accessToken and not headers.Cookie and not headers.Authorization
    end
    local valid={url=target,method='GET',skip_cookie=true,persist_response_cookies=false,sensitive=true,
        headers={vid=grant.vid,accessToken=grant.accessToken}}
    assert(allowed(valid)==(mode=='live'))
    for _i,key in ipairs({'url','method','body','cookie','owner','token','authorization','skip','persist','sensitive'}) do
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
        if not allowed(options) or not synthetic and counters[0]>=request_budget or tonumber(ffi.C.getpid())==parent then
            counters[1]=counters[1]+1;error('own marks read scope rejected',0)
        end
        counters[0]=counters[0]+1
        if synthetic then
            require('socket').sleep(.35)
            if counters[2]==1 then return '{}',503 end
            local value=json.decode(json.encode(input.source))
            if thoughts then
                local count=targets[options.url]
                while #value.reviews>count do table.remove(value.reviews) end
                -- Real service returned false hasMore even for an incomplete prefix.
                value.hasMore=0
            end
            if counters[2]==2 then value.bookId='900099' end
            return json.encode(value),200
        end
        return request(self,options)
    end
    local fetch=Data.fetch
    function Data.fetch(client,id,access,options) options=options or {};options.now=input.now;return fetch(client,id,access,options) end
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
    plugin.fetchVisibleShelfCovers=function() end
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
    plugin:showBookMenu{book_id=input.book_id,title='所选书籍',chapters={}}
    local detail=assert(plugin._book_detail_view);local tr=require('weread.lib.plugin_util').tr
    local open
    for _i,button in ipairs(detail._action_buttons) do if button.text==tr(thoughts and 'My cloud thoughts' or 'My cloud highlights') then open=button.callback end end
    assert(open);open();local owner=assert(plugin._my_marks_owner);local menu=assert(plugin._my_marks_menu)
    if mode=='live' then
        assert(owner.context and owner.worker.job)
        local heartbeat=false;UI:scheduleIn(.1,function() heartbeat=true end);wait(function() return heartbeat end)
        report.worker_heartbeat=true
        wait(function() return not owner.context end)
    else assert(not owner.context and not owner.worker);report.worker_heartbeat=true end
    assert(same(owner.value,expected))
    report.phase='views'
    for page=1,menu.page_num do menu:onGotoPage(page);UI:forceRePaint();report.pages=report.pages+1 end
    shot('all-marks')
    local items=menu.item_table;local shown={}
    for _i,row in ipairs(thoughts and expected.reviews or expected.updated) do
        local item,position
        for index,candidate in ipairs(items) do
            if candidate.my_note_id==(thoughts and row.reviewId or row.bookmarkId) then item,position=candidate,index end
        end
        assert(item and item.callback and item.select_enabled~=false)
        menu:onGotoPage(menu:getPageNumber(position));menu:onMenuSelect(item)
        local popup=assert(menu._shelf_popup);assert(type(popup.text)=='string')
        local content=thoughts and row.content or row.markText
        if content and content~='' then assert(popup.text:find(content,1,true))
        elseif thoughts then assert(popup.text:find(tr('No thought text was returned.'),1,true)) end
        if row.abstract and row.abstract~='' then assert(popup.text:find(row.abstract,1,true)) end
        UI:forceRePaint();report.quotes=report.quotes+1
        local shot_kind=thoughts and ((row.abstract and row.abstract~='') and 'with-quote' or 'without-quote') or row.type
        if not shown[shot_kind] and (thoughts or row.type==0 or row.type==1) then
            shot(thoughts and shot_kind or row.type==1 and 'highlight' or 'bookmark');shown[shot_kind]=true
        end
        UI:close(popup);tick();assert(not menu._shelf_popup)
    end
    assert(report.quotes==#(thoughts and expected.reviews or expected.updated));report.all_quotes=true
    for _,filter in ipairs(thoughts and {'Thoughts with quoted text','Other thoughts','All my thoughts'} or {'Highlights only','Bookmarks only','All cloud marks'}) do
        for _,item in ipairs(menu.item_table) do if item.text==tr(filter) then menu:onMenuSelect(item);break end end
        UI:forceRePaint()
    end
    local Cache=require('weread.lib.my_cloud_marks_store');assert(same(Cache:new(plugin.library_db,plugin.client,input.variant):read(input.book_id),expected))
    local db=assert(plugin.library_db:open());local _,name,path=db:rowexec('PRAGMA database_list')
    assert(name=='main' and path==plugin.library_db:databasePath());local payload=db:rowexec('SELECT payload FROM '..(thoughts and 'my_cloud_thoughts' or 'my_cloud_marks'));db:close()
    for _,field in ipairs({'accessToken','refreshToken','source_revision','synckey','userVid'}) do assert(not payload:find('"'..field..'"',1,true)) end
    report.file_sqlite,report.cache_session_free=true,true
    local other=require('weread.lib.library_db'):new{data_dir=plugin.settings.data_dir,get=function(_self,key,default)
        return key=='account' and {user_vid=grant.vid=='900099' and '900098' or '900099'} or default
    end}
    assert(other:databasePath()~=plugin.library_db:databasePath() and not Cache:new(other,plugin.client,input.variant):read(input.book_id));report.account_isolation=true
    if synthetic and mode=='live' then
        local baseline=owner.value
        local function refresh()
            menu:onMenuSelect(menu.item_table[1]);assert(owner.context and owner.worker.job)
        end
        local function finished() wait(function() return not owner.context end) end
        local function clear_notice()
            local top=UI:getTopmostVisibleWidget();if top~=menu then UI:close(top) end
        end
        for fault=1,2 do
            counters[2]=fault;refresh();finished();assert(same(owner.value,baseline));clear_notice();report.fault_cases=report.fault_cases+1
        end
        counters[2]=0
        local write=owner.store.write;owner.store.write=function() return false end
        refresh();finished();owner.store.write=write;assert(same(owner.value,baseline));clear_notice();report.fault_cases=report.fault_cases+1
        local before=counters[0];refresh();local pid=owner.worker.job.pid;wait(function() return counters[0]>before end);plugin.busy_message:onTapClose();assert(not owner.context)
        wait(function() return owner.worker.runner.done(pid) end);assert(same(owner.value,baseline));report.fault_cases=report.fault_cases+1
        before=counters[0];refresh();pid=owner.worker.job.pid;wait(function() return counters[0]>before end);detail:onClose();assert(not plugin._my_marks_owner and not owner.context)
        wait(function() return owner.worker.runner.done(pid) end);report.fault_cases=report.fault_cases+1
        -- The old detail action must also stay stale after parent replacement.
        open();assert(not plugin._my_marks_owner);report.fault_cases=report.fault_cases+1
    end
    -- Close through the parent detail and reject a queued old entry callback.
    local stale=menu.item_table[1].callback;detail:onClose();assert(not plugin._my_marks_menu and not plugin._my_marks_owner)
    stale();assert(not plugin._my_marks_menu and not plugin.busy_message)
    plugin:closeWeReadUI();plugin.settings:flush();G_reader_settings:flush()
    for _,worker in ipairs(workers) do wait(function() return worker.runner.done(worker.pid) end) end
    report.workers_reaped=true;report.phase='audit'
    local lfs=require('libs/libkoreader-lfs')
    local function audit(directory)
        for entry in lfs.dir(directory) do
            if entry~='.' and entry~='..' and not (directory==home and entry=='plugins') then
                local filename=directory..'/'..entry;local info=assert(lfs.symlinkattributes(filename))
                if info.mode=='directory' then audit(filename)
                else
                    assert(info.mode=='file' and info.size<=16*1024*1024)
                    local f=assert(io.open(filename,'rb'));local bytes=f:read('*a');f:close()
                    for _,key in ipairs({'accessToken','refreshToken','deviceId'}) do assert(not bytes:find(grant[key],1,true)) end
                end
            end
        end
    end
    audit(home);report.credential_audit=true
    assert((synthetic or counters[0]==(mode=='live' and request_budget or 0)) and counters[1]==0)
    report.phase,report.result='complete','PASS';output={model=expected,native=owner.value,requests=tonumber(counters[0]),ui=report}
end)
if plugin then pcall(plugin.closeWeReadUI,plugin) end
if counters then report.requests,report.forbidden=tonumber(counters[0]),tonumber(counters[1]);ffi.C.munmap(memory,4096) end
for _,fd in ipairs(descriptors) do ffi.C.close(fd) end
if not ok then report.failed_line=tonumber(type(reason)=='string' and reason:match('my_cloud_marks_probe%.lua:(%d+):')) or 0 end
io.stdout:write('\nWEREAD_MY_MARKS_RESULT='..json.encode(output or {ui=report})..'\n')
os.exit(ok and 0 or 1)
