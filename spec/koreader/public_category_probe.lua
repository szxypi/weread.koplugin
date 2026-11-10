-- Actual signed-out PluginLoader/FileManager, anonymous HTTP and public SQLite.
require('ffi').log=function() end
require('setupkoenv')
local ffi,json=require('ffi'),require('json');require('ffi/posix_h')
local mode=arg[1]
local report={result='UNVERIFIED',phase='init',mode=mode,native_filemanager_host=false,guest=false,
    transport_guard_selftest=false,file_backed_sqlite=false,directory_persisted=false,cache_projected=false,
    all_pages_verified=false,workers_reaped=false,profile_audit=false,stale_picker_rejected=false,public_store_rejects_personal=false,
    batch_views=0,painted_views=0,forward_books=0,profile_files=0,failed_line=0,forbidden_requests=0,request_counts={}}
local private=json.decode('{"catalog_source":null,"sources":[],"views":[]}')
local plugin,memory,counters
local ok,reason=pcall(function()
    assert(mode=='live' or mode=='reopen')
    local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/weread%-category%-[%w_]+/profile$'))
    local input=json.decode(assert(io.stdin:read(2*1024*1024+1)))
    assert(type(input.samples)=='table' and #input.samples>=3 and #input.samples<=6)
    local source=home..'/plugins/weread.koplugin';package.path=source..'/?.lua;'..package.path
    G_defaults=require('luadefaults'):open()
    G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
    G_reader_settings:saveSetting('language','zh_CN');require('gettext').changeLang('zh_CN')
    G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
    local Device=require('device');require('document/canvascontext'):init(Device)
    Device.screen.shot=function() error('public category screenshots disabled',0) end
    local mock=os.getenv('WEREAD_CATEGORY_MOCK')
    if mock then assert(require('weread.lib.mock_environment').save{enabled=true,host='127.0.0.1',port=assert(tonumber(mock))}) end
    pcall(ffi.cdef,'void *mmap(void *, unsigned long, int, int, int, long); int munmap(void *, unsigned long);')
    memory=ffi.C.mmap(nil,4096,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1))
    counters=ffi.cast('int *',memory);local last=ffi.cast('double *',ffi.cast('char *',memory)+2048)
    local parent=tonumber(ffi.C.getpid());local allowed={}
    allowed['https://weread.qq.com/web/categories?rank=1&synckey=0']=0
    for index,sample in ipairs(input.samples) do
        assert(sample.role=='rank' or sample.role=='main' or sample.role=='child')
        local entry=sample.entry;assert(entry.id:match('^[%w_-]+$') and #entry.id<=128 and type(entry.rank)=='boolean')
        local address='https://weread.qq.com/web/bookListInCategory/'..entry.id..'?rank='..(entry.rank and '1' or '0')..'&maxIndex='..sample.cursor
        assert(not allowed[address]);allowed[address]=index
    end
    for _slot_index=1,#input.samples+1 do report.request_counts[#report.request_counts+1]=0 end
    local function classify(options)
        local slot=allowed[options.url];local headers=options.headers or {}
        if slot~=nil and mode=='live' and options.method=='GET' and options.body==nil and options.skip_cookie==true
            and options.persist_response_cookies==false and options.sensitive==true
            and not headers.Cookie and not headers.Authorization and not headers.vid and not headers.accessToken then return slot end
    end
    local valid={url=next(allowed),method='GET',skip_cookie=true,persist_response_cookies=false,sensitive=true,headers={}}
    assert((classify(valid)~=nil)==(mode=='live'))
    for _change_index,change in ipairs({'url','method','body','cookie','token','authorization','skip','persist','sensitive'}) do
        local test={};for key,value in pairs(valid) do test[key]=value end;test.headers={}
        if change=='url' then test.url='https://weread.qq.com/web/shelf/sync' elseif change=='method' then test.method='POST'
        elseif change=='body' then test.body='{}' elseif change=='cookie' then test.headers.Cookie='forbidden'
        elseif change=='token' then test.headers.accessToken='forbidden' elseif change=='authorization' then test.headers.Authorization='forbidden'
        elseif change=='skip' then test.skip_cookie=false elseif change=='persist' then test.persist_response_cookies=true else test.sensitive=false end
        assert(classify(test)==nil)
    end
    report.transport_guard_selftest=true
    local Client=require('weread.lib.client');local request=Client.request;local socket=require('socket')
    function Client:request(options)
        local slot=classify(options)
        if slot==nil or counters[slot]>=1 or tonumber(ffi.C.getpid())==parent then
            counters[64]=counters[64]+1;error('public category request rejected',0)
        end
        local delay=1-(socket.gettime()-last[0]);if delay>0 then socket.sleep(delay) end
        last[0]=socket.gettime();counters[slot]=counters[slot]+1
        return request(self,options)
    end
    local Catalog=require('weread.lib.category_catalog');local project_catalog=Catalog.project
    function Catalog.project(data,...)
        local value=project_catalog(data,...);value._probe_source=data;return value
    end
    local Source=require('weread.lib.discovery_source');local project=Source.project
    function Source.project(client,kind,data,cursor)
        local value=project(client,kind,data,cursor);value._probe_source=data;return value
    end
    local Worker=require('weread.lib.memory_worker');local start=Worker.start;local pids={}
    function Worker:start(task,complete)
        local result={start(self,task,function(value)
            if type(value)=='table' and type(value.catalog)=='table' and value.catalog._probe_source then
                private.catalog_source=value.catalog._probe_source;value.catalog._probe_source=nil
            end
            return complete(value)
        end)}
        if self.job and self.job.pid then pids[#pids+1]={pid=self.job.pid,runner=self.runner};assert(#pids<=16) end
        return unpack(result)
    end
    local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
    for _entry_index,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
    assert(#Loader.enabled_plugins==1)
    local FM=require('apps/filemanager/filemanager');FM:showFiles(home);plugin=assert(FM.instance.weread)
    assert(plugin.ui==FM.instance and not plugin.ui.document);report.native_filemanager_host=true
    plugin.settings:set('account',{});plugin.settings:set('cookies',{});plugin.settings:set('api_key','');plugin.settings:flush()
    assert(not plugin.library_db:accountKey() and not plugin.settings:is_cookie_configured() and not plugin.settings:is_api_configured())
    report.guest=true
    plugin.isNetworkOnline=function() return mode=='live' end;plugin.isNetworkConnected=plugin.isNetworkOnline
    plugin.fetchVisibleShelfCovers=function() end
    local UI=require('ui/uimanager')
    local function tick() UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01) end
    local function wait(predicate)
        local deadline=socket.gettime()+30
        while plugin.discovery_loading or predicate and not predicate() do assert(socket.gettime()<deadline,'category deadline');tick() end
    end
    local function press(label)
        for _button_index,button in ipairs(plugin.shelf_view._action_buttons) do
            if button.text==require('weread.lib.plugin_util').tr(label) then button.callback();return end
        end
        error('category batch button missing',0)
    end
    local function same(a,b)
        if type(a)~=type(b) then return false end
        if type(a)~='table' then return a==b end
        for key,value in pairs(a) do if not same(value,b[key]) then return false end end
        for key in pairs(b) do if a[key]==nil then return false end end
        return true
    end
    local function verify(sample)
        local state=assert(plugin.discovery_state)
        assert(state.kind=='category' and state.category_id==sample.entry.id and state.rank==sample.entry.rank
            and state.cursor==sample.cursor and state.source_kind=='public' and not state.account)
        assert((state.cached==true)==(mode=='reopen'))
        local view={role=sample.role,cursor=state.cursor,books=json.decode('[]'),next_cursor=state.next_cursor,has_more=state.has_more,cached=state.cached==true}
        for _book_index,book in ipairs(state.books) do
            local row={};for _field_index,key in ipairs({'bookId','title','author','cover','category','searchIdx'}) do row[key]=book[key] end
            view.books[#view.books+1]=row
        end
        private.views[#private.views+1]=view;report.batch_views=report.batch_views+1
        if mode=='live' then private.sources[#private.sources+1]={role=sample.role,cursor=state.cursor,source=assert(state._probe_source)} end
        local total=plugin.shelf_view.page_count;local checked=0
        local function paint(page,reverse)
            local current=plugin.shelf_view;assert(current.page==page and current.page_count==total)
            local size=current[1]:getSize();assert(size.h==Device.screen:getHeight() and size.w<=Device.screen:getWidth())
            for index,book in ipairs(current:getVisibleBooks()) do
                local expected=state.books[(page-1)*current.page_size+index]
                for _field_index,key in ipairs({'bookId','title','author','cover','category','searchIdx'}) do assert(same(book[key],expected[key])) end
                if not reverse then checked=checked+1 end
            end
            UI:forceRePaint();report.painted_views=report.painted_views+1;assert(report.painted_views<=256)
        end
        for page=1,total do if page>1 then plugin.shelf_view:onShelfSwipe(nil,{direction='west'}) end;paint(page,false) end
        assert(checked==#state.books);report.forward_books=report.forward_books+checked
        local boundary=plugin.shelf_view;boundary:onShelfSwipe(nil,{direction='west'});assert(plugin.shelf_view==boundary)
        if mode=='reopen' then
            for page=total-1,1,-1 do plugin.shelf_view:onShelfSwipe(nil,{direction='east'});paint(page,true) end
            boundary=plugin.shelf_view;boundary:onShelfSwipe(nil,{direction='east'});assert(plugin.shelf_view==boundary)
        end
    end
    plugin:showBookstore()
    if mode=='reopen' then assert(plugin.discovery_state and plugin.discovery_state.cached);verify(input.samples[#input.samples]) end
    report.phase='catalog';plugin:showDiscoveryCategories(mode=='live');wait(function() return plugin._discovery_menu~=nil end)
    local tree=assert(Catalog:new(plugin.settings,plugin.client):read());assert(#tree.ranks==#input.catalog.ranks and #tree.categories==#input.catalog.categories)
    report.directory_persisted=true
    plugin._discovery_menu:onCloseAllMenus()
    local function select(sample)
        plugin:showDiscoveryCategories();local menu=assert(plugin._discovery_menu)
        menu:onMenuSelect(menu.item_table[sample.role=='rank' and 1 or 2])
        local entries=sample.role=='rank' and tree.ranks or tree.categories
        local index,parent_entry
        if sample.role=='child' then
            for entry_index,entry in ipairs(entries) do
                for child_index,child in ipairs(entry.children) do
                    if child.id==sample.entry.id then index,parent_entry=entry_index,child_index end
                end
            end
        else for entry_index,entry in ipairs(entries) do if entry.id==sample.entry.id then index=entry_index end end end
        assert(index);local row=menu.item_table[index];menu:onMenuSelect(row)
        if sample.role=='child' then row=menu.item_table[parent_entry+1];menu:onMenuSelect(row)
        elseif sample.role=='main' and #entries[index].children>0 then row=menu.item_table[1];menu:onMenuSelect(row) end
        assert(row.callback);local stale=row.callback
        wait(function() return plugin.discovery_state and plugin.discovery_state.category_id==sample.entry.id and plugin.discovery_state.cursor==0 end)
        local current=plugin.shelf_view;stale();for _tick_index=1,3 do tick() end
        assert(plugin.shelf_view==current and not plugin.discovery_loading and not plugin._discovery_menu)
    end
    for index,sample in ipairs(input.samples) do
        report.phase=sample.role
        if sample.cursor==0 then select(sample) else press('Next batch') end
        wait(function() return plugin.discovery_state and plugin.discovery_state.category_id==sample.entry.id and plugin.discovery_state.cursor==sample.cursor end)
        verify(sample)
        if mode=='reopen' and sample.cursor>0 then press('Previous batch');wait(function() return plugin.discovery_state.cursor==0 end);verify(input.samples[index-1]) end
    end
    report.all_pages_verified,report.stale_picker_rejected=true,true
    local cache=require('weread.lib.public_discovery_cache'):new(plugin.settings,plugin.client)
    assert(not cache:read({kind='search',keyword='private'}) and not cache:write({kind='recommend',source_kind='native'}))
    report.public_store_rejects_personal=true
    report.phase='audit';plugin:closeWeReadUI();plugin.settings:flush();G_reader_settings:flush()
    for _worker_index,worker in ipairs(pids) do assert(worker.runner.done(worker.pid)) end
    assert(not plugin.discovery_loading and not plugin.discovery_request_context);report.workers_reaped=true
    local db=require('lua-ljsqlite3/init').open(plugin.settings.data_dir..'/bookstore-public.db')
    local _,name,path=db:rowexec('PRAGMA database_list');assert(name=='main' and path==plugin.settings.data_dir..'/bookstore-public.db')
    local stmt=db:prepare('SELECT payload FROM discovery_cache');local row=stmt:step();local records=0
    while row do
        records=records+1;local value=plugin.client:json_decode(row[1]);assert(value.query.kind=='category' and value.source_kind=='public')
        for _field_index,key in ipairs({'session_id','source_revision','accessToken','refreshToken','cookies','keyword','_probe_source'}) do assert(not row[1]:find('"'..key..'"',1,true)) end
        row=stmt:step()
    end
    stmt:close();db:close();assert(records==3);report.file_backed_sqlite,report.cache_projected=true,true
    local lfs=require('libs/libkoreader-lfs')
    local function audit(directory)
        for entry in lfs.dir(directory) do
            if entry~='.' and entry~='..' and not (directory==home and entry=='plugins') then
                local child=directory..'/'..entry;local info=assert(lfs.symlinkattributes(child))
                if info.mode=='directory' then audit(child)
                else assert(info.mode=='file' and info.size<=20*1024*1024)
                    report.profile_files=report.profile_files+1;assert(report.profile_files<=64)
                    assert(not child:match('/library%-') and not child:match('/native%-authorization'))
                end
            end
        end
    end
    audit(home);report.profile_audit=true
    assert(counters[64]==0)
    for slot=0,#input.samples do assert(counters[slot]==(mode=='live' and 1 or 0)) end
    report.phase,report.result='complete','PASS'
end)
if plugin then pcall(plugin.closeWeReadUI,plugin) end
if counters then
    for index=1,#report.request_counts do report.request_counts[index]=tonumber(counters[index-1]) end
    report.forbidden_requests=tonumber(counters[64]);ffi.C.munmap(memory,4096)
end
if not ok then report.failed_line=tonumber(type(reason)=='string' and reason:match('public_category_probe%.lua:(%d+):')) or 0 end
io.stdout:write('\nWEREAD_PUBLIC_CATEGORY_PRIVATE='..json.encode(private))
io.stdout:write('\nWEREAD_PUBLIC_CATEGORY_RESULT='..json.encode(report)..'\n')
os.exit(ok and 0 or 1)
