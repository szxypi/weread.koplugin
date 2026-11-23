-- Actual installed FileManager plugin; real shelf data stays in tmpfs and pipes.
require('setupkoenv')
local json=require('json')
local payload=json.decode(assert(io.read('*a')))
local mode=arg[1]
local report={result='UNVERIFIED',phase=mode,groups=0,network_requests=0,failed_line=0}
local ok,reason=pcall(function()
    local home=assert(os.getenv('KO_HOME'))
    assert(home:match('^/dev/shm/weread%-owner%-copy%-[%w_]+/profile$'))
    assert(mode=='live' or mode=='reopen')
    package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
    G_defaults=require('luadefaults'):open()
    G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
    G_reader_settings:saveSetting('language','zh_CN');require('gettext').changeLang('zh_CN')
    G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
    local blocked=0
    local Client=require('weread.lib.client')
    Client.request=function() blocked=blocked+1;error('network disabled') end
    local http=require('socket.http');http.request=function() blocked=blocked+1;error('network disabled') end
    local https=require('ssl.https');https.request=function() blocked=blocked+1;error('network disabled') end
    local Device=require('device');require('document/canvascontext'):init(Device)
    local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
    for _,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
    assert(#Loader.enabled_plugins==1)
    local UI=require('ui/uimanager');UI:setRunForeverMode();UI:setInputTimeout(0)
    local FM=require('apps/filemanager/filemanager');FM:showFiles(home)
    local host=assert(FM.instance.weread)
    host.isNetworkOnline=function() return false end;host.isNetworkConnected=host.isNetworkOnline
    host.settings:update_auth({account={user_vid='900000',name='Synthetic'},
        cookies={wr_vid='900000',wr_skey='synthetic-session'}},{replace_cookies=true})
    host:applyShelfSnapshot(payload.books,payload.archives);host:showShelfView('books')
    local socket=require('socket')
    local function pump(predicate)
        local deadline=socket.gettime()+30
        while not predicate() do UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01);assert(socket.gettime()<deadline) end
    end
    local function text(key) return require('weread.lib.i18n').tr(key) end
    local function entry(menu,label)
        local found
        for _,row in ipairs(menu.item_table or {}) do if row.text==label then assert(not found);found=row end end
        return assert(found)
    end
    local function select(view,menu,label)
        menu:onMenuSelect(entry(menu,label));pump(function() return view._shelf_popup and view._shelf_popup~=menu end)
        return view._shelf_popup
    end
    local function equal(a,b)
        if type(a)~='table' or #a~=#b then return false end
        for i,item in ipairs(b) do if a[i]~=item then return false end end
        return true
    end
    local function check_saved(count)
        local state=assert(host.library_db:getProfileState('shelf_local_groups_v1'))
        assert(#state.groups==count)
        for i=1,count do
            local group=state.groups[i]
            assert(group.name=='验证副本 '..i and equal(group.books,payload.expected[i].members))
        end
    end
    if mode=='live' then
        for index,expected in ipairs(payload.expected) do
            local view=assert(host.shelf_view);view:showSourceMenu('books');local picker=assert(view._shelf_popup)
            local manager=select(view,picker,text('Manage local groups'))
            picker=select(view,manager,text('Copy a cloud group to this device'))
            local source=entry(picker,expected.label)
            assert(source.mandatory==tostring(#expected.members))
            local dialog=select(view,picker,expected.label);dialog:setInputText('验证副本 '..index)
            dialog.buttons[1][2].callback();pump(function() return host.shelf_view~=view end)
            check_saved(index);report.groups=index
        end
        host.settings:flush()
    else
        check_saved(#payload.expected)
        local groups=host.shelf_groups
        for index,expected in ipairs(payload.expected) do
            local group=assert(groups[#groups-#payload.expected+index])
            assert(group.local_group and group.label=='本机 · 验证副本 '..index)
            local known={};for _,book in ipairs(payload.books) do known[tostring(book.bookId)]=true end
            local missing=false;for _,id in ipairs(expected.members) do if not known[id] then missing=true end end
            assert((group.incomplete==true)==missing)
        end
        report.groups=#payload.expected
    end
    assert(blocked==0);report.result='PASS';report.network_requests=blocked
end)
if not ok and type(reason)=='string' then
    local source,line=reason:match('([%w_/-]+%.lua):(%d+):')
    report.failed_module=source;report.failed_line=tonumber(line) or 0
end
io.write('\nWEREAD_OWNER_COPY='..json.encode(report)..'\n')
os.exit(ok and 0 or 1)
