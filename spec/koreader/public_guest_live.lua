-- Public data only, fresh temporary profile, no screenshots or credentials.
require('ffi').log=function() end
require('setupkoenv')
local ffi=require('ffi');require('ffi/posix_h')
local json=require('json')
local report={result='UNVERIFIED',phase='init',requests=0,first=0,second=0,
    guest=false,native_host=false,detail=false,public_intro=false,manual_login=false,forbidden=0}
local ok=pcall(function()
    local home=assert(os.getenv('KO_HOME'))
    assert(home:match('^/dev/shm/weread%-public%-[%w_]+/profile$'))
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
    local prefix='https://weread.qq.com/web/search/global?count=20&keyword='..
        require('weread.lib.protocol').urlencode('三体')..'&maxIdx='
    local Client=require('weread.lib.client');local request=Client.request
    function Client:request(options)
        local headers=options.headers or {};local cursor=options.url and options.url:match('^'..prefix:gsub('([^%w])','%%%1')..'(%d+)$')
        if not cursor or options.method~='GET' or options.body~=nil or not options.skip_cookie
            or options.persist_response_cookies~=false or not options.sensitive or headers.Cookie or headers.Authorization
            or tonumber(ffi.C.getpid())==parent or counts[0]>=3
            or (counts[0]~=1 and cursor~='0') or (counts[0]==1 and tonumber(cursor)<=0) then
            counts[1]=counts[1]+1;error('request outside public search scope',0)
        end
        counts[0]=counts[0]+1
        return request(self,options)
    end
    local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
    for _i,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
    assert(#Loader.enabled_plugins==1)
    local FM=require('apps/filemanager/filemanager');FM:showFiles(home..'/books')
    local browser=assert(FM.instance);local plugin=assert(browser.weread)
    assert(plugin.ui==browser and not browser.document);report.native_host=true
    assert(not plugin.library_db:accountKey() and not plugin.settings:get_auth_scope());report.guest=true
    plugin.isNetworkOnline=function() return true end
    plugin.isNetworkConnected=function() return false end
    plugin.fetchVisibleShelfCovers=function() end
    local scans=0;plugin.qr_login.start=function() scans=scans+1 end
    local UI=require('ui/uimanager');local socket=require('socket')
    local function wait(predicate)
        local deadline=socket.gettime()+45
        repeat
            assert(socket.gettime()<deadline)
            UI:shiftScheduledTasksBy(-1e9);UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
        until not plugin.discovery_loading and (not predicate or predicate())
    end
    local function press(label)
        for _,button in ipairs(plugin.shelf_view._action_buttons) do
            if button.text==require('weread.lib.plugin_util').tr(label) then button.callback();return end
        end
        error('missing native button',0)
    end
    report.phase='search'
    plugin:showBookstore()
    plugin.shelf_view.on_search()
    local dialog=assert(plugin.shelf_view._shelf_popup)
    dialog:setInputText('三体');dialog.buttons[1][2].callback()
    wait(function() return plugin.discovery_state and plugin.discovery_state.kind=='search' end)
    local first=assert(plugin.discovery_state)
    assert(first.source_kind=='public' and not first.account and first.cursor==0 and #first.books>0 and first.has_more)
    report.first=#first.books;UI:forceRePaint()
    press('Next batch');wait(function() return plugin.discovery_state.cursor>0 end)
    local second=plugin.discovery_state;report.second=#second.books
    assert(second.source_kind=='public' and #second.books>0 and second.history[1]==0)
    press('Previous batch');wait(function() return plugin.discovery_state.cursor==0 end)
    assert(plugin.discovery_state.source_kind=='public')
    report.phase='detail'
    local book=assert(plugin.discovery_state.books[1])
    assert(plugin.shelf_view._item_rows[1]).callback()
    wait(function() return plugin._book_detail_view~=nil end)
    local detail=assert(plugin._book_detail_view)
    assert(detail.data.title==book.title and scans==0 and not plugin.book_metadata_context)
    assert(book._public_info and type(book._public_info.intro)=='string'
        and detail.data.intro==book._public_info.intro)
    report.public_intro=true
    UI:forceRePaint();report.detail=true
    detail._refresh_button.callback()
    wait(function() return scans==1 end);report.manual_login=true
    plugin:closeWeReadUI()
    report.requests=counts[0];report.forbidden=counts[1]
    assert(report.requests==3 and report.forbidden==0)
    report.phase='complete';report.result='PASS'
end)
io.stdout:write('\nWEREAD_PUBLIC_GUEST='..json.encode(report)..'\n')
os.exit(ok and report.result=='PASS' and 0 or 1)
