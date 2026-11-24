-- FileManager plugin uses private shelf samples only in a disposable profile.
require('setupkoenv')
local json=require('json');local input=json.decode(assert(io.read('*a')));local mode=arg[1]
local report={result='UNVERIFIED',mode=mode,queries=0,books=0,group_books=0,network_requests=0,failed_line=0}
local ok,reason=pcall(function()
    local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/weread%-owner%-search%-[%w_]+/profile$'))
    assert(mode=='live' or mode=='reopen');package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
    G_defaults=require('luadefaults'):open();G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
    G_reader_settings:saveSetting('language','zh_CN');require('gettext').changeLang('zh_CN')
    G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
    local blocked=0;local Client=require('weread.lib.client')
    Client.request=function() blocked=blocked+1;error('network disabled') end
    local http=require('socket.http');http.request=function() blocked=blocked+1;error('network disabled') end
    local https=require('ssl.https');https.request=function() blocked=blocked+1;error('network disabled') end
    local Device=require('device');require('document/canvascontext'):init(Device)
    Device.screen.shot=function() error('owner_search/screenshots_disabled',0) end
    local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
    for _,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
    assert(#Loader.enabled_plugins==1)
    local UI=require('ui/uimanager');UI:setRunForeverMode();UI:setInputTimeout(0)
    local FM=require('apps/filemanager/filemanager');FM:showFiles(home);local host=assert(FM.instance.weread)
    host.isNetworkOnline=function() return false end;host.isNetworkConnected=host.isNetworkOnline
    host.settings:update_auth({account={user_vid='900000',name='Synthetic'},
        cookies={wr_vid='900000',wr_skey='synthetic-session'}},{replace_cookies=true})
    if mode=='live' then assert(host.library_db:cacheShelf(input.books,input.archives)) end
    local books,archives=assert(host.library_db:getShelf()),assert(host.library_db:getShelfArchives())
    assert(#books==#input.books and #archives==#input.archives)
    host:applyShelfSnapshot(books,archives);host:showShelfView('books')
    local socket=require('socket');local function pump(predicate)
        local deadline=socket.gettime()+30
        while not predicate() do UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01);assert(socket.gettime()<deadline) end
    end
    local function equal(actual,expected)
        if #actual~=#expected then return false end
        local seen={};for _,id in ipairs(expected) do seen[id]=(seen[id] or 0)+1 end
        for _,book in ipairs(actual) do local id=tostring(book.bookId or book.book_id)
            if not seen[id] or seen[id]==0 then return false end;seen[id]=seen[id]-1 end
        return true
    end
    local function find(menu,label)
        local item
        for _,row in ipairs(menu.item_table or {}) do if row.text==label then assert(not item);item=row end end
        return assert(item)
    end
    local function choose(label)
        local view=assert(host.shelf_view);view:showSourceMenu('books');local menu=assert(view._shelf_popup)
        menu:onMenuSelect(find(menu,label));pump(function() return host.shelf_view and host.shelf_view~=view end)
    end
    local function search(query,expected)
        local view=assert(host.shelf_view);view.on_search();local dialog=assert(view._shelf_popup)
        dialog:setInputText(query);dialog.buttons[1][2].callback()
        pump(function() return host.shelf_view and host.shelf_view~=view end)
        assert(equal(host.shelf_view.books,expected));report.queries=report.queries+1;UI:forceRePaint()
    end
    local function clear(expected)
        local view=assert(host.shelf_view);view.on_search();local dialog=assert(view._shelf_popup)
        dialog.buttons[1][1].callback();pump(function() return host.shelf_view and host.shelf_view~=view end)
        assert(equal(host.shelf_view.books,expected) and host.shelf_search_keyword==nil)
    end
    local tr=require('weread.lib.i18n').tr
    assert(equal(host.shelf_view.books,input.all_ids));search(input.queries[1],input.expected_all);clear(input.all_ids)
    choose(input.group_label);assert(equal(host.shelf_view.books,input.group_ids))
    for index=1,3 do search(input.queries[index],input.expected_group[index]) end
    clear(input.group_ids);choose(tr('All books'));assert(equal(host.shelf_view.books,input.all_ids))
    assert(blocked==0);report.books=#input.all_ids;report.group_books=#input.group_ids;report.result='PASS'
end)
if not ok and type(reason)=='string' then
    local module,line=reason:match('([%w_/-]+%.lua):(%d+):')
    report.failed_module=module;report.failed_line=tonumber(line) or 0
end
io.write('\nWEREAD_OWNER_SHELF_SEARCH='..json.encode(report)..'\n');os.exit(ok and 0 or 1)
