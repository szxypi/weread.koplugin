-- Public chart only, disposable guest profile, no screenshots or credentials.
require('ffi').log=function() end
require('setupkoenv')
local ffi=require('ffi');require('ffi/posix_h')
local json=require('json')
local mode=arg[1]
local report={result='UNVERIFIED',phase='init',mode=mode,requests=0,forbidden=0,
    first=0,second=0,guest=false,native_host=false,offline=false}
local transfer
local ok=pcall(function()
    assert(mode=='live' or mode=='reopen')
    local home=assert(os.getenv('KO_HOME'))
    assert(home:match('^/dev/shm/weread%-chart%-[%w_]+/profile$'))
    local source=home..'/plugins/weread.koplugin';package.path=source..'/?.lua;'..source..'/?/init.lua;'..package.path
    G_defaults=require('luadefaults'):open()
    G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
    G_reader_settings:saveSetting('language','zh_CN');require('gettext').changeLang('zh_CN')
    G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
    local Device=require('device');require('document/canvascontext'):init(Device)
    Device.screen.shot=function() error('screenshots disabled',0) end
    pcall(ffi.cdef,'void *mmap(void *, unsigned long, int, int, int, long);')
    local memory=ffi.C.mmap(nil,4096,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1))
    local counts=ffi.cast('int *',memory);local parent=tonumber(ffi.C.getpid())
    local Client=require('weread.lib.client');local request=Client.request
    function Client:request(options)
        local headers=options.headers or {}
        local cursor=options.url and options.url:match('^https://weread%.qq%.com/web/bookListInCategory/rising%?rank=1&maxIndex=(%d+)$')
        if mode~='live' or not cursor or options.method~='GET' or options.body~=nil
            or not options.skip_cookie or options.persist_response_cookies~=false or not options.sensitive
            or headers.Cookie or headers.Authorization or tonumber(ffi.C.getpid())==parent
            or counts[0]>=2 or (counts[0]==0 and cursor~='0') or (counts[0]==1 and tonumber(cursor)<=0) then
            counts[1]=counts[1]+1;error('request outside public chart scope',0)
        end
        counts[0]=counts[0]+1;return request(self,options)
    end
    local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
    for _,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
    assert(#Loader.enabled_plugins==1)
    local FM=require('apps/filemanager/filemanager');FM:showFiles(home..'/books')
    local browser=assert(FM.instance);local plugin=assert(browser.weread)
    assert(plugin.ui==browser and not browser.document);report.native_host=true
    assert(not plugin.library_db:accountKey() and not plugin.settings:get_auth_scope());report.guest=true
    plugin.isNetworkOnline=function() return mode=='live' end
    plugin.isNetworkConnected=function() return mode=='live' end
    plugin.fetchVisibleShelfCovers=function() end
    plugin.qr_login.start=function() error('public chart requested login',0) end
    local UI=require('ui/uimanager');local socket=require('socket')
    local function wait(predicate)
        local deadline=socket.gettime()+45
        repeat
            assert(socket.gettime()<deadline)
            UI:shiftScheduledTasksBy(-1e9);UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
        until not plugin.discovery_loading and predicate()
    end
    local function press(label)
        for _,button in ipairs(plugin.shelf_view._action_buttons) do
            if button.text==require('weread.lib.plugin_util').tr(label) then button.callback();return end
        end
        error('missing native button',0)
    end
    local function digest(state)
        local values={}
        for _,book in ipairs(state.books) do values[#values+1]={book.bookId,book.title,book.author} end
        return require('weread.lib.crypto').sha256_hex(json.encode(values))
    end
    report.phase='entry';plugin:showHome()
    local store
    for _,button in ipairs(plugin.shelf_view._navigation_buttons) do
        if button.text==require('weread.lib.plugin_util').tr('Bookstore') then store=button end
    end
    assert(store);store.callback()
    if mode=='live' then
        wait(function() return plugin.discovery_state and plugin.discovery_state.kind=='category' end)
        local first=assert(plugin.discovery_state)
        assert(first.category_id=='rising' and first.rank and not first.account and first.cursor==0
            and first.category_title==require('weread.lib.plugin_util').tr('Rising · Published')
            and #first.books>0 and first.has_more)
        report.first=#first.books;local first_hash=digest(first);UI:forceRePaint()
        report.phase='next';press('Next batch');wait(function() return plugin.discovery_state.cursor>0 end)
        local second=plugin.discovery_state
        assert(#second.books>0 and second.history[1]==0)
        report.second=#second.books;UI:forceRePaint()
        transfer={first=first_hash,second=digest(second)}
    else
        local expected=json.decode(assert(io.stdin:read(4097)))
        for _,key in ipairs({'first','second'}) do
            assert(type(expected[key])=='string' and #expected[key]==64 and expected[key]:match('^[a-f0-9]+$'))
        end
        wait(function() return plugin.discovery_state~=nil end)
        local second=plugin.discovery_state
        assert(second.cached and second.category_id=='rising' and second.cursor>0 and digest(second)==expected.second)
        report.second=#second.books
        press('Previous batch');wait(function() return plugin.discovery_state.cursor==0 end)
        assert(plugin.discovery_state.cached and digest(plugin.discovery_state)==expected.first)
        report.first=#plugin.discovery_state.books;UI:forceRePaint();report.offline=true
    end
    plugin:closeWeReadUI();report.requests=counts[0];report.forbidden=counts[1]
    assert(report.requests==(mode=='live' and 2 or 0) and report.forbidden==0)
    report.phase='complete';report.result='PASS'
end)
if mode=='live' and transfer then io.stdout:write('\nWEREAD_CHART_TRANSFER='..json.encode(transfer)) end
io.stdout:write('\nWEREAD_CHART_REPORT='..json.encode(report)..'\n')
os.exit(ok and report.result=='PASS' and 0 or 1)
