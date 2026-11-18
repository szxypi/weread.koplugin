-- Public data only, fresh temporary profile, no screenshots or credentials.
require('ffi').log=function() end
require('setupkoenv')
local ffi=require('ffi');require('ffi/posix_h')
local json=require('json')
local mode=arg[1] or 'live'
local transfer
local report={result='UNVERIFIED',phase='init',mode=mode,requests=0,first=0,second=0,
    guest=false,native_host=false,detail=false,public_intro=false,manual_refresh=false,metadata_requests=0,forbidden=0}
local ok=pcall(function()
    assert(mode=='live' or mode=='reopen')
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
        local common=options.skip_cookie and options.persist_response_cookies==false and options.sensitive
            and not headers.Cookie and not headers.Authorization and tonumber(ffi.C.getpid())~=parent
        local search=cursor and options.method=='GET' and options.body==nil and counts[0]<3
            and (counts[0]==1 and tonumber(cursor)>0 or counts[0]~=1 and cursor=='0')
        local metadata=false
        if options.url=='https://weread.qq.com/web/book/publicinfos' and options.method=='POST'
            and type(options.body)=='string' and counts[3]<2 and counts[2]>0 then
            local decoded_ok,body=pcall(json.decode,options.body)
            local expected=ffi.string(ffi.cast('char *',memory)+128,counts[2])
            metadata=decoded_ok and type(body)=='table' and type(body.bookIds)=='table'
                and #body.bookIds==1 and body.bookIds[1]==expected
            if metadata then for key in pairs(body) do if key~='bookIds' then metadata=false end end end
        end
        if mode~='live' or not common or not (search or metadata) then
            counts[1]=counts[1]+1;error('request outside public search scope',0)
        end
        if search then counts[0]=counts[0]+1 else counts[3]=counts[3]+1 end
        return request(self,options)
    end
    local get_public=Client.get_public_book_metadata
    function Client:get_public_book_metadata(id)
        local raw=get_public(self,id)
        assert(type(raw.data)=='table' and #raw.data==1 and tostring(raw.data[1].bookId)==id
            and type(raw.data[1].intro)=='string')
        local checksum=require('weread.lib.crypto').sha256_hex(raw.data[1].intro)
        ffi.copy(ffi.cast('char *',memory)+256,checksum,#checksum)
        return raw
    end
    local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
    for _i,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
    assert(#Loader.enabled_plugins==1)
    local FM=require('apps/filemanager/filemanager');FM:showFiles(home..'/books')
    local browser=assert(FM.instance);local plugin=assert(browser.weread)
    assert(plugin.ui==browser and not browser.document);report.native_host=true
    assert(not plugin.library_db:accountKey() and not plugin.settings:get_auth_scope());report.guest=true
    plugin.isNetworkOnline=function() return mode=='live' end
    plugin.isNetworkConnected=function() return false end
    plugin.fetchVisibleShelfCovers=function() end
    local scans=0;plugin.qr_login.start=function() scans=scans+1 end
    local UI=require('ui/uimanager');local socket=require('socket')
    if mode=='reopen' then
        local payload=json.decode(assert(io.stdin:read(4097)))
        assert(type(payload)=='table' and type(payload.book_id)=='string' and payload.book_id:match('^[1-9]%d*$')
            and #payload.book_id<=20 and type(payload.intro_hash)=='string' and payload.intro_hash:match('^[a-f0-9]+$')
            and #payload.intro_hash==64)
        local saved=assert(plugin.settings:get_book(payload.book_id))
        assert(saved.detail_source=='public' and type(saved.intro)=='string' and not saved.secret and not saved.progress)
        plugin:showBookRecord({bookId=payload.book_id})
        local detail=assert(plugin._book_detail_view)
        assert(require('weread.lib.crypto').sha256_hex(detail.data.intro)==payload.intro_hash
            and not plugin.book_metadata_context and scans==0)
        UI:forceRePaint();plugin:closeWeReadUI()
        report.detail=true;report.public_intro=true;report.requests=counts[0]
        report.metadata_requests=counts[3];report.forbidden=counts[1]
        assert(report.requests==0 and report.metadata_requests==0 and report.forbidden==0)
        report.phase='complete';report.result='PASS';return
    end
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
    counts[2]=#book.bookId;ffi.copy(ffi.cast('char *',memory)+128,book.bookId,counts[2])
    assert(plugin.shelf_view._item_rows[1]).callback()
    wait(function() return plugin._book_detail_view~=nil and not plugin.book_metadata_context end)
    local detail=assert(plugin._book_detail_view)
    assert(detail.data.title==book.title and scans==0 and not plugin.book_metadata_context)
    assert(type(detail.data.intro)=='string' and require('weread.lib.crypto').sha256_hex(detail.data.intro)
        ==ffi.string(ffi.cast('char *',memory)+256,64))
    report.public_intro=true
    UI:forceRePaint();report.detail=true
    detail._refresh_button.callback()
    wait(function() return counts[3]==2 and not plugin.book_metadata_context end)
    assert(scans==0 and plugin._book_detail_view);report.manual_refresh=true
    local latest=assert(plugin._book_detail_view)
    transfer={book_id=book.bookId,intro_hash=require('weread.lib.crypto').sha256_hex(latest.data.intro)}
    plugin.settings:flush()
    plugin:closeWeReadUI()
    report.requests=counts[0];report.metadata_requests=counts[3];report.forbidden=counts[1]
    assert(report.requests==3 and report.metadata_requests==2 and report.forbidden==0)
    report.phase='complete';report.result='PASS'
end)
if mode=='live' and transfer then io.stdout:write('\nWEREAD_PUBLIC_TRANSFER='..json.encode(transfer)) end
io.stdout:write('\nWEREAD_PUBLIC_GUEST='..json.encode(report)..'\n')
os.exit(ok and report.result=='PASS' and 0 or 1)
