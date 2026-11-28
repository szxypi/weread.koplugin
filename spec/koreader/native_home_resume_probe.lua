-- Installed plugin and chapter in isolated, separate offline processes.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
assert(os.getenv('WEREAD_SYNTHETIC')=='1' or os.getenv('WEREAD_DIRECT_OWNER_TMPFS')=='1')
local home=assert(os.getenv('KO_HOME'));local plugin=home..'/plugins/weread.koplugin'
if os.getenv('WEREAD_DIRECT_OWNER_TMPFS')=='1' then assert(home:match('^/dev/shm/')) end
package.path=plugin..'/?.lua;'..package.path
assert(dofile(assert(arg[1])..'/spec/koreader/offline_network_guard.lua')())
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua');G_defaults=require('luadefaults'):open()
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
local Device=require('device');require('document/canvascontext'):init(Device)
local json=require('json');local input=json.decode(assert(io.stdin:read('*a')))
local id=input.book_id or '42';local vid=input.vid or '12345678'
assert(type(id)=='string' and type(vid)=='string')
local settings=require('weread.lib.settings'):new()
local suspend_record=input.mode=='record_suspended'
local record_alternative=input.mode=='record_alternative'
local close_home=input.mode=='close_home'
local record=input.mode=='record' or record_alternative or suspend_record or close_home
local downloads_inventory=input.mode=='downloads_inventory'
if record then
    settings:set('account',{user_vid=vid,name='Synthetic',login_method='qr'})
    settings:set('cookies',{wr_vid=vid, wr_skey='synthetic'})
    local sync=settings:get('sync');sync.pull_on_open=false;sync.upload_on_close=false;sync.upload_interval_minutes=0;settings:set('sync',sync)
    local report=settings:get('read_report');report.enabled=false;settings:set('read_report',report)
    settings:set('books',{[id]={book_id=id,title='Synthetic book',author='Fixture'}});settings:flush()
    if suspend_record or close_home then assert(settings:patch_reading_state(id,{native_home_resume=false})) end
elseif downloads_inventory then
    settings:set('account',{user_vid=vid,name='Synthetic',login_method='qr'})
    settings:set('cookies',{wr_vid=vid,wr_skey='synthetic'})
    settings:flush()
elseif input.mode=='switch' then
    assert(vid=='12345678' and id=='42')
    settings:update_auth({account={user_vid='87654321',name='Other'},cookies={wr_vid='87654321',wr_skey='synthetic-other'}},
        {replace_cookies=true});settings:flush()
end
local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
for _,item in ipairs(Loader:_discover()) do if item.name=='weread' then Loader:_load{item} end end
assert(#Loader.enabled_plugins==1)
local UI=require('ui/uimanager');local socket=require('socket')
local Reader=require('apps/reader/readerui');local FM=require('apps/filemanager/filemanager')
local function pump(fn)
    local deadline=socket.gettime()+90
    while not fn() do
        assert(socket.gettime()<deadline,'native home timeout')
        UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
    end
end
if record then
    local delay_record=suspend_record
    if suspend_record then
        local cache=require('weread.lib.native_direct_cache')
        local identify=cache.identify
        cache.identify=function(...)
            if delay_record then socket.sleep(20) end -- The suspend event cancels this first worker.
            return identify(...)
        end
    end
    if close_home then
        G_reader_settings:saveSetting('lastdir',home)
        require('weread.ui.native_home_resume').record=function() return false end
    end
    Reader:showReader(input.path)
    pump(function() return Reader.instance and Reader.instance.weread end)
    local reader=Reader.instance
    if suspend_record then
        local active=reader.weread
        local interrupted=assert(active._native_home_resume,'chapter verification was not pending at reader start')
        assert(not active.settings:get_book(id).native_home_resume)
        active:onSuspend()
        assert(not active._native_home_resume and not active._native_home_resume_worker.job)
        delay_record=false
        active:onResume()
        assert(active._native_home_resume and active._native_home_resume~=interrupted,
            'waking on the same chapter did not restart its home verification')
    end
    if not close_home then
        pump(function() local b=reader.weread.settings:get_book(id);return b and b.native_home_resume end)
    end
    assert(not reader.weread:detectWeReadBook())
    if reader.document:getPageCount()<2 then
        assert(reader.font:onSetFontSize(48));UI:forceRePaint()
    end
    assert(reader.document:getPageCount()>=2,'sample does not cover page navigation')
    local first=assert(reader.document:getXPointer())
    local next_page=reader:getCurrentPage()==2 and 1 or 2
    reader.rolling:onGotoPage(next_page);UI:forceRePaint()
    local anchor=assert(reader.document:getXPointer())
    assert(reader:getCurrentPage()==next_page and anchor~=first,'page navigation did not move')
    local anchor_path=record_alternative and '/alternative-anchor' or '/anchor'
    local file=assert(io.open(home..anchor_path,'wb'));assert(file:write(anchor));file:close()
    if close_home then
        local active=reader.weread
        assert(not active.settings:get_book(id).native_home_resume,'the open-time check hid the close-time fallback')
        assert(active:onShowWeReadQuickMenu())
        local action
        pump(function()
            local top=UI:getTopmostVisibleWidget()
            action=top and type(top.getButtonById)=='function' and top:getButtonById('close_book')
            return action
        end)
        local tr=require('weread.lib.plugin_util').tr
        assert(action.text==tr('Close book and return home'))
        UI:forceRePaint();action:onTapSelectButton()
        pump(function()
            local host=FM.instance and FM.instance.weread
            return not Reader.instance and host and host.shelf_view and host.shelf_view._discovery_tab=='home'
        end)
        local host=assert(FM.instance.weread);local view=assert(host.shelf_view)
        assert(FM.instance.file_chooser.path==home and host.settings:get_auth_scope().vid==vid)
        local selected
        for _,book in ipairs(view.books) do if book.bookId==id then selected=book end end
        view.on_select(assert(selected,'the closed chapter was missing from the home page'))
        pump(function() return Reader.instance and Reader.instance.document.file==input.path end)
        assert(Reader.instance.document:isXPointerInCurrentPage(anchor),'the quit action did not save the page')
        Reader.instance:onClose(false)
    else
        while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=reader do UI:close(UI:getTopmostVisibleWidget()) end
        reader.weread:onFlushSettings();reader:onClose(false)
    end
    assert(not Reader.instance)
elseif input.mode=='record_standard' then
    local checkpoint=assert(settings:get_book(id).native_home_resume)
    Reader:showReader(input.path)
    pump(function() return Reader.instance and Reader.instance.document end)
    local reader=Reader.instance
    assert(reader.document:getPageCount()>=2)
    reader.rolling:onGotoPage(2);UI:forceRePaint()
    local proof={anchor=assert(reader.document:getXPointer()),native=checkpoint}
    assert(reader:getCurrentPage()==2)
    reader:onClose(false)
    local file=assert(io.open(home..'/standard-record','wb'))
    assert(file:write(json.encode(proof)));assert(file:close())
else
    FM:showFiles(home);local host=assert(FM.instance.weread)
    if downloads_inventory then
        require('ui/network/manager').isConnected=function() return false end
        host.client.request=function() error('download inventory attempted a network request') end
        assert(not host.settings:get_book(id) and not host.library_db:getBook(id)
            and #(host.library_db:getShelf() or {})==0,'fixture already indexed the native download')
        local Downloads=require('weread.ui.download_library')
        local function show()
            Downloads.show(host)
            pump(function() return host.shelf_view and host.shelf_view._discovery_tab=='downloads' end)
            local view=host.shelf_view
            local book=assert(view.books[1])
            assert(#view.books==1 and book.bookId==id and book.title=='Synthetic' and book.author=='Fixture'
                and book._native_cached_hint,'unindexed native book is missing or lacks its EPUB metadata')
            assert(not view._action_buttons,'cached book unexpectedly appeared as an unfinished plan')
            return view
        end
        show()
        local cache=require('weread.lib.native_direct_cache')
        local book_dir=assert(cache.book_directory(host.settings,vid,id))
        local parent,name=book_dir:match('^(.*)/([^/]+)$')
        local marker=parent..'/.native-presence-'..name
        assert(os.rename(marker,marker..'.fixture'))
        local view=show()
        assert(not io.open(marker,'rb'),'inventory rewrote the presence marker')
        assert(os.rename(marker..'.fixture',marker))
        local function current() return true end
        assert(#cache.list_books(host.settings,vid,{[id]=true},current)==0,'existing book would appear twice')
        assert(#cache.list_books(host.settings,'87654321',{},current)==0,'other account saw the native download')
        view.on_search()
        local dialog=assert(view._shelf_popup)
        dialog:setInputText('Fixture');dialog.buttons[1][2].callback()
        view=host.shelf_view
        assert(#view.books==1 and view.books[1].bookId==id,'author search omitted the off-shelf download')
        view.on_select(view.books[1])
        local detail=assert(host._book_detail_view)
        local read
        for _,button in ipairs(detail._footer_actions) do
            if button.text==require('weread.lib.plugin_util').tr('▤ Read') then read=button;break end
        end
        assert(read,'native-only detail omitted the read action').callback()
        pump(function() return host._native_direct_reading and host._native_direct_reading.menu end)
        local ctx=host._native_direct_reading
        assert(ctx.offline and #ctx.menu.item_table==2)
        require('weread.ui.native_home_resume').record=function() return false end
        ctx.menu:onMenuSelect(ctx.menu.item_table[1])
        pump(function() return Reader.instance and Reader.instance.document.file==input.path end)
        print('WEREAD_NATIVE_HOME='..json.encode{ok=true,mode=input.mode,network_blocked=true})
        os.exit(0)
    end
    if input.mode=='shelf_close' or input.mode=='shelf_close_prior' then
        require('ui/network/manager').isConnected=function() return false end
        require('weread.ui.native_home_resume').record=function() return false end
        assert(host.settings:patch_reading_state(id,{native_home_resume=false}))
        local shelf=host.settings:get('shelf');local tap_to_read=shelf.tap_to_read
        shelf.tap_to_read=true;host.settings:set('shelf',shelf)
        host:applyShelfSnapshot({{bookId=id,title='Synthetic book'}},{})
        host:showShelfView('books',nil,nil,{skip_cover_fetch_once=true,skip_progress_fetch_once=true})
        local shelf_view=assert(host.shelf_view)
        assert(shelf_view.books[1].bookId==id)
        shelf_view.on_select(shelf_view.books[1],'books')
        shelf.tap_to_read=tap_to_read;host.settings:set('shelf',shelf)
        pump(function() return host._native_direct_reading and host._native_direct_reading.menu end)
        local ctx=host._native_direct_reading
        assert(ctx.offline and #ctx.menu.item_table==2)
        ctx.menu:onMenuSelect(ctx.menu.item_table[1])
        pump(function() return Reader.instance and Reader.instance.document.file==input.path end)
        local reader=Reader.instance
        local active=reader.weread;local scope=active.settings:get_auth_scope()
        local opened=assert(active._native_home_verified_open)
        local store=require('weread.lib.native_direct_pending')
        local function read_reminder()
            return store.read(active.library_db,active.settings,scope,opened.entry,function() return true end)
        end
        local previous=read_reminder()
        if input.mode=='shelf_close' and previous then
            assert(store.remove(active.library_db,active.settings,scope,opened.entry,previous,function() return true end))
            previous=nil
        end
        assert((previous~=nil)==(input.mode=='shelf_close_prior'))
        assert(not active.settings:get_book(id).native_home_resume,'background verification was not suppressed')
        local current_page=reader:getCurrentPage()
        assert(reader.document:getPageCount()>=2)
        reader.rolling:onGotoPage(current_page==2 and 1 or 2);UI:forceRePaint()
        assert(reader:getCurrentPage()~=current_page and active._native_direct_reconnect.dirty)
        local anchor=assert(require('weread.lib.source_context').location(reader.document,'page')).xpointer
        reader:onHome()
        assert(not Reader.instance and FM.instance and FM.instance.weread)
        local recent=assert(FM.instance.weread.settings:get_book(id).native_home_resume,'normal close lost the selected chapter')
        assert(recent.entry.chapter_uid=='37')
        local reminder=assert(read_reminder(),'normal close lost the offline position reminder')
        if previous then assert(reminder.xpointer==previous.xpointer and reminder.xpointer~=anchor,'closing replaced an unread reminder')
        else assert(reminder.xpointer==anchor,'reminder did not contain the last page') end
        local file=assert(io.open(home..'/anchor','wb'));assert(file:write(anchor));file:close()
        print('WEREAD_NATIVE_HOME='..json.encode{ok=true,mode=input.mode,network_blocked=true})
        return
    end
    if input.mode=='detail_read_saved' or input.mode=='detail_catalog_saved' then
        assert(os.getenv('WEREAD_SYNTHETIC')=='1')
        require('ui/network/manager').isConnected=function() return false end
        assert(host.settings:patch_reading_state(id,{native_home_resume=false}))
        local detail=assert(host:showBookMenu(assert(host.settings:get_book(id))))
        local label=require('weread.lib.plugin_util').tr(input.mode=='detail_catalog_saved' and '☷ Chapter list' or '▤ Read')
        local action
        for _,button in ipairs(detail._footer_actions) do
            if button.text==label then action=button;break end
        end
        UI:forceRePaint();assert(action):onTapFooterAction()
        pump(function() return host._native_direct_reading and host._native_direct_reading.menu end)
        local ctx=assert(host._native_direct_reading)
        assert(ctx.offline and #ctx.menu.item_table==1 and not Reader.instance)
        ctx.menu:onMenuSelect(ctx.menu.item_table[1])
        pump(function() return Reader.instance and Reader.instance.document.file==input.path end)
        local reader=Reader.instance
        local file=assert(io.open(home..'/anchor','rb'));local anchor=assert(file:read('*a'));file:close()
        assert(reader.document:isXPointerInCurrentPage(anchor),'saved chapter lost its local reading page')
        print('WEREAD_NATIVE_HOME='..json.encode{ok=true,mode=input.mode,network_blocked=true})
        return
    end
    local standard_record
    if input.standard then
        local file=assert(io.open(home..'/standard-record','rb'))
        standard_record=json.decode(assert(file:read('*a')));file:close()
        local books=host.settings:get('books',{})
        local book=assert(books[id])
        book.cached_full_book=input.standard
        book._library_account_key=host.library_db:accountKey()
        host.settings:set('books',books);host.settings:flush()
        assert(host.settings:patch_reading_state(id,{native_home_resume=standard_record.native,
            home_recent_at=standard_record.native.at,home_recent_account=book._library_account_key}))
    end
    host:showHome();local view=assert(host.shelf_view);local selected
    for _,book in ipairs(view.books) do if book.bookId==id then selected=book end end
    if input.mode=='switch' then
        assert(not selected,'other account saw native home history')
        require('weread.ui.download_library').show(host)
        pump(function() return host.shelf_view and host.shelf_view._discovery_tab=='downloads' end)
        assert(#host.shelf_view.books==0,'other account saw a saved EPUB on the downloads page')
        assert(not host.shelf_view._action_buttons,'other account saw unfinished downloads')
        print('WEREAD_NATIVE_HOME='..json.encode{ok=true,mode=input.mode,network_blocked=true})
        os.exit(0)
    end
    if input.mode=='downloads_pending' then
        local scope=assert(host.settings:get_auth_scope())
        local store=require('weread.lib.native_direct_batch_plan'):new(host.library_db,scope)
        local function current() return true end
        local empty_id='999991'
        assert(host.library_db:putBook{book_id=empty_id,title='Pending without chapters'})
        local catalog={book_id=id,version=1,reading_digest=string.rep('a',64),chapters={{},{},{}}}
        assert(store:begin(catalog,{first=1,last=2},nil,current))
        catalog.book_id=empty_id
        assert(store:begin(catalog,{first=2,last=3},nil,current))
        require('ui/network/manager').isConnected=function() return false end
        require('weread.ui.download_library').show(host)
        pump(function() return host.shelf_view and host.shelf_view._discovery_tab=='downloads' end)
        view=host.shelf_view
        for _,book in ipairs(view.books) do assert(book.bookId~=empty_id,'unfinished book claimed a downloaded file') end
        local util=require('weread.lib.plugin_util')
        local action=assert(view._action_buttons and view._action_buttons[1])
        assert(action.text==util.T(util.tr('Unfinished downloads · %1'),2))
        action:onTapSelectButton()
        pump(function() return view._shelf_popup end)
        local menu=view._shelf_popup
        assert(#menu.item_table==2 and menu.item_table[2].text:find('Pending without chapters',1,true),
            'unfinished list omitted the book without a local file')
        assert(menu.item_table[1].text:find(util.T(util.tr('Chapters %1–%2'),1,2),1,true))
        menu:onMenuSelect(menu.item_table[2])
        local dialog=assert(menu._shelf_popup)
        assert(dialog.buttons[1][1].text==util.tr('Continue download'))
        dialog.buttons[4][1].callback()
        pump(function() return not menu._shelf_popup end)
        assert(view._shelf_popup==menu,'cancelling an action lost the unfinished list')
        menu:onMenuSelect(menu.item_table[1])
        dialog=assert(menu._shelf_popup)
        assert(dialog.buttons[2][1].text==util.tr('Saved E-Ink chapters'))
        dialog.buttons[2][1].callback()
        pump(function() return host._native_direct_reading and host._native_direct_reading.menu end)
        local saved=host._native_direct_reading
        assert(saved.offline and saved.book.book_id==id and #saved.menu.item_table>0 and not view._shelf_popup)
        saved.menu:onMenuSelect(saved.menu.item_table[1])
        pump(function() return Reader.instance and Reader.instance.document and Reader.instance.document.file==input.path end)
        print('WEREAD_NATIVE_HOME='..json.encode{ok=true,mode=input.mode,network_blocked=true})
        os.exit(0)
    end
    if input.mode=='downloads_discard' then
        local scope=assert(host.settings:get_auth_scope())
        local store=require('weread.lib.native_direct_batch_plan'):new(host.library_db,scope)
        local tr=require('weread.lib.plugin_util').tr
        local empty_id='999991'
        local function current() return true end
        local function open_plans()
            require('weread.ui.download_library').show(host)
            pump(function() return host.shelf_view and host.shelf_view._discovery_tab=='downloads' end)
            local downloads=host.shelf_view
            assert(downloads._action_buttons[1]):onTapSelectButton()
            pump(function() return downloads._shelf_popup end)
            return downloads,downloads._shelf_popup
        end
        local function remove_prompt(menu,index)
            menu:onMenuSelect(menu.item_table[index])
            local action=assert(menu._shelf_popup)
            assert(action.buttons[3][1].text==tr('Remove resume record'))
            action.buttons[3][1].callback()
            pump(function() return menu._shelf_popup and menu._shelf_popup~=action end)
            local dialog=menu._shelf_popup
            assert(dialog.text==tr('Remove this resume record? Downloaded chapters will still be available.'))
            return dialog
        end
        local downloads,menu=open_plans()
        local original=assert(store:read(empty_id,current))
        remove_prompt(menu,2):onClose()
        assert(not menu._shelf_popup and #menu.item_table==2 and store:read(empty_id,current).revision==original.revision)
        local confirmation=remove_prompt(menu,2)
        local newer=assert(store:begin({book_id=empty_id,version=1,reading_digest=original.digest,chapters={{},{},{}}},
            {first=1,last=1},original,current))
        local failure
        host.showInfo=function(_,message) failure=message end
        confirmation.ok_callback()
        pump(function() return failure end)
        assert(failure==tr('Could not remove this resume record. Refresh the list and try again.')
            and host.shelf_view==downloads and downloads._shelf_popup==menu
            and store:read(empty_id,current).revision==newer.revision,'a stale confirmation removed the replacement')
        downloads,menu=open_plans()
        remove_prompt(menu,2).ok_callback()
        pump(function() return host.shelf_view~=downloads and host.shelf_view and host.shelf_view._shelf_popup end)
        downloads=host.shelf_view;menu=downloads._shelf_popup
        assert(#menu.item_table==1 and not store:read(empty_id,current),'removing a record lost the remaining task')
        remove_prompt(menu,1).ok_callback()
        pump(function() return host.shelf_view~=downloads and host.shelf_view and not host.shelf_view._action_buttons end)
        assert(not store:read(id,current) and #host.shelf_view.books==1 and host.shelf_view.books[1].bookId==id)
        local cache=require('weread.lib.native_direct_cache')
        assert(cache.identify(host.settings,scope.vid,input.path,current)
            and cache.identify(host.settings,scope.vid,input.alternative,current),'removing a plan affected a saved chapter')
        print('WEREAD_NATIVE_HOME='..json.encode{ok=true,mode=input.mode,network_blocked=true})
        os.exit(0)
    end
    if input.mode=='downloads_missing_all' then
        require('weread.ui.download_library').show(host)
        pump(function() return host.shelf_view and host.shelf_view._discovery_tab=='downloads' end)
        assert(#host.shelf_view.books==0,'the stale marker showed a book without saved EPUBs')
        print('WEREAD_NATIVE_HOME='..json.encode{ok=true,mode=input.mode,network_blocked=true})
        os.exit(0)
    end
    if input.store_search then
        local saved=assert(host.settings:get_book(id))
        assert(selected and type(saved.title)=='string' and saved.title~='' and selected.title==saved.title,
            'native search book not listed on home')
    else assert(selected and selected.title=='Synthetic book','native chapter not listed on home') end
    if input.mode:match('^select_') then
        assert(standard_record)
        require('ui/network/manager').isConnected=function() return false end
        local tr=require('weread.lib.plugin_util').tr
        local target=input.mode=='select_native_downloads' and input.path or input.standard
        local anchor=standard_record.anchor
        if input.mode=='select_standard_detail' then
            local details=assert(host:showBookMenu(assert(host.settings:get_book(id))))
            assert(details._footer_actions[3].text==tr('▤ Continue reading'))
            local choose
            for _,button in ipairs(details._action_buttons) do
                if button.text==tr('Read standard download') then choose=button end
            end
            UI:forceRePaint();assert(choose,'ordinary copy is missing from the detail actions'):onTapSelectButton()
        else
            require('weread.ui.download_library').show(host)
            pump(function() return host.shelf_view and host.shelf_view._discovery_tab=='downloads' end)
            view=host.shelf_view
            assert(#view.books==1 and view.books[1].bookId==id)
            view.on_hold(view.books[1])
            local buttons=assert(view._shelf_popup).buttons
            assert(buttons[1][1].text==tr('Continue reading'))
            assert(buttons[2][1].text==tr('Read standard download')
                and buttons[3][1].text==tr('Read saved E-Ink chapter'),'mixed downloads do not offer both formats')
            if input.mode=='select_removed_downloads' then
                local unavailable
                host.showInfo=function(_,message) unavailable=message end
                assert(os.rename(input.standard,input.standard..'.moved'))
                buttons[2][1].callback()
                pump(function() return unavailable end)
                assert(os.rename(input.standard..'.moved',input.standard))
                assert(unavailable==tr('No cached file.') and not Reader.instance and not host._native_direct_reading,
                    'expired standard action opened a book or silently switched formats')
                print('WEREAD_NATIVE_HOME='..json.encode{ok=true,mode=input.mode,network_blocked=true})
                os.exit(0)
            elseif input.mode=='select_native_downloads' then
                buttons[3][1].callback()
                pump(function() return host._native_direct_reading and host._native_direct_reading.menu end)
                local menu=host._native_direct_reading.menu
                assert(not Reader.instance and #menu.item_table==2,'explicit E-Ink selection bypassed the saved chapters')
                menu:onMenuSelect(menu.item_table[1])
                local file=assert(io.open(home..'/anchor','rb'));anchor=assert(file:read('*a'));file:close()
            else buttons[2][1].callback() end
        end
        pump(function() return Reader.instance and Reader.instance.document.file==target end)
        assert(Reader.instance.document:isXPointerInCurrentPage(anchor),'the selected copy did not restore its own page')
        print('WEREAD_NATIVE_HOME='..json.encode{ok=true,mode=input.mode,network_blocked=true})
        os.exit(0)
    end
    local message
    local damage=standard_record or input.mode=='damage' or input.mode=='detail_damage'
        or input.mode=='shelf_damage' or input.mode=='no_alternative'
    local shelf=input.mode=='shelf_detail' or input.mode=='shelf_damage' or input.mode=='standard_shelf'
    local repair=input.mode=='downloads_repair' or input.mode=='downloads_repair_unwritable'
    local downloads=input.mode=='downloads' or input.mode=='downloads_choose' or input.mode=='standard_downloads' or repair
    local quick=input.mode=='quick_home' or input.mode=='quick_shelf' or input.mode=='quick_store' or input.mode=='quick_choose'
    local choose=input.mode=='downloads_choose' or input.mode=='quick_choose' or repair
    if damage then host.showInfo=function(_,text) message=text end end
    if shelf then
        -- Book details use the device link state, without a live DNS probe.
        local network=require('ui/network/manager')
        network.isConnected=function() return false end
        host:applyShelfSnapshot({{bookId=id,title='Synthetic book',author='Fixture'}},{})
        host:showShelfView('books',nil,nil,{skip_cover_fetch_once=true,skip_progress_fetch_once=true})
        local shelf_view=assert(host.shelf_view);local shelf_book
        for _,book in ipairs(shelf_view.books) do if book.bookId==id then shelf_book=book end end
        assert(shelf_book,'native chapter not listed on shelf')
        shelf_view.on_select(shelf_book,'books')
        assert(host._book_detail_view,'shelf selection did not open offline details')
    elseif input.mode=='detail' or input.mode=='detail_damage' or input.mode=='detail_closed' then
        host:showBookMenu(assert(host.settings:get_book(id)))
    end
    if downloads or quick then
        if choose then assert(host.settings:patch_reading_state(id,{native_home_resume=false})) end
        if input.mode=='downloads_repair_unwritable' then
            local files=require('weread.lib.notes_export_file');local create=files.create
            files.create=function(directory,label,extension)
                if label=='native-presence' then return nil end
                return create(directory,label,extension)
            end
        end
        if downloads then
            require('weread.ui.download_library').show(host)
            pump(function() return host.shelf_view and host.shelf_view._discovery_tab=='downloads' end)
        elseif input.mode=='quick_shelf' then
            host:applyShelfSnapshot({{bookId=id,title='Synthetic book'}},{})
            host:showShelfView('books',nil,nil,{skip_cover_fetch_once=true,skip_progress_fetch_once=true})
        elseif input.mode=='quick_store' then
            host:showDiscoveryPage('store',{{bookId=id,title='Synthetic book'}},{title='Synthetic search'})
        end
        view=assert(host.shelf_view);local cached
        for _,book in ipairs(view.books) do if book.bookId==id then cached=book end end
        assert(cached,'native chapter missing from the browse page')
        require('ui/network/manager').isConnected=function() return false end
        local rejected=false
        host.showOffline=function() rejected=true end
        if input.mode=='downloads_repair_unwritable' then
            view.on_select(cached,'books')
            local detail=assert(host._book_detail_view,'repaired book could not open its local details')
            UI:forceRePaint()
            local action
            for _,button in ipairs(detail._footer_actions) do
                if button.text==require('weread.lib.plugin_util').tr('▤ Read') then action=button;break end
            end
            assert(action,'the recovered book had no primary action'):onTapFooterAction()
        else
            view.on_hold(cached)
            local button=assert(view._shelf_popup).buttons[1][1]
            local tr=require('weread.lib.plugin_util').tr
            assert(button.text==tr(downloads and 'Read downloaded copy' or 'Read now')
                or downloads and button.text==tr('Continue reading'))
            button.callback()
        end
        pump(function() return rejected or Reader.instance or host._native_home_resume or host._native_direct_reading end)
        assert(not rejected,'browse shortcut reported offline despite the saved E-Ink chapter')
        if choose then
            pump(function() return host._native_direct_reading and host._native_direct_reading.menu end)
            local menu=host._native_direct_reading.menu
            assert(#menu.item_table>=1,'no saved E-Ink chapter offered')
            menu:onMenuSelect(menu.item_table[1])
        end
    elseif shelf or input.mode=='detail' or input.mode=='detail_damage' or input.mode=='detail_closed' then
        local detail=assert(host._book_detail_view);local action
        for _,button in ipairs(detail._footer_actions) do
            if button.text==require('weread.lib.plugin_util').tr('▤ Continue reading') then action=button end
        end
        assert(action and action.enabled~=false,'missing primary detail resume action')
        UI:forceRePaint()
        if input.mode=='detail_closed' then
            UI:close(detail)
            assert(not host._book_detail_view,'detail did not close')
            action.callback()
            assert(not Reader.instance and not host._native_home_resume,'closed detail started a resume')
            print('WEREAD_NATIVE_HOME='..json.encode{ok=true,mode=input.mode,network_blocked=true})
            os.exit(0)
        end
        action:onTapFooterAction()
    else view.on_select(selected,'books') end
    if damage then
        local function picker()
            local job=host._native_direct_reading
            return job and job.menu
        end
        local function alternative_confirmation()
            local job=host._native_direct_reading
            return job and job.confirm
        end
        pump(function() return message or Reader.instance or picker() or standard_record and alternative_confirmation() end)
        assert(not Reader.instance,'fallback opened a chapter without a selection')
        local tr=require('weread.lib.plugin_util').tr
        if standard_record then
            local dialog=assert(alternative_confirmation(),'other downloaded EPUB was not offered')
            assert(dialog.ok_text==tr('Read cached copy') and not picker())
            if input.mode=='standard_cancel' then
                UI:close(dialog);dialog.ok_callback()
                local after=assert(host.settings:get_book(id).native_home_resume)
                assert(after.entry.file_id==standard_record.native.entry.file_id and not Reader.instance
                    and not host._native_direct_reading,'cancelling changed the previous resume or allowed the old button')
            else
                dialog.ok_callback()
                pump(function() return Reader.instance and Reader.instance.document.file==input.standard end)
                assert(Reader.instance.document:isXPointerInCurrentPage(standard_record.anchor),
                    'standard download lost its own saved reading position')
            end
        elseif input.mode=='no_alternative' then
            assert(message==tr('No usable saved E-Ink chapters for this book and account. Existing files are kept.')
                and not picker(),'missing alternatives were not reported')
        else
            local menu=assert(picker(),'saved alternatives were not offered')
            assert(#menu.item_table==1 and menu.item_table[1].select_enabled,'the failed copy was still offered')
            local original=assert(host.settings:get_book(id).native_home_resume)
            assert(original.entry.chapter_uid=='37','showing alternatives changed the recent chapter')
            if input.mode=='detail_damage' then
                menu:onMenuSelect(menu.item_table[1])
                pump(function() return Reader.instance and Reader.instance.document.file==input.alternative end)
                local alternative_file=assert(io.open(home..'/alternative-anchor','rb'))
                local alternative_anchor=assert(alternative_file:read('*a'));alternative_file:close()
                assert(Reader.instance.document:isXPointerInCurrentPage(alternative_anchor),'alternative did not restore its local page')
                assert(not Reader.instance.weread:detectWeReadBook())
            else
                UI:close(menu);menu:onMenuSelect(menu.item_table[1])
                assert(not Reader.instance and not host._native_direct_reading,'closed chooser started a chapter open')
            end
        end
        print('WEREAD_NATIVE_HOME='..json.encode{ok=true,mode=input.mode,network_blocked=true})
        os.exit(0)
    end
    pump(function() return Reader.instance and Reader.instance.document and Reader.instance.document.file==input.path end)
    local reader=Reader.instance
    local file=assert(io.open(home..'/anchor','rb'));local anchor=assert(file:read('*a'));file:close()
    assert(reader.document:isXPointerInCurrentPage(anchor),'native page was not restored')
    assert(not reader.weread:detectWeReadBook(),'native resume gained Web position authority')
    if input.progress_estimate then
        local expected=input.progress_estimate;local active=reader.weread
        assert(input.mode=='reopen' and type(expected)=='table')
        assert(active:onShowWeReadQuickMenu())
        pump(function()
            local top=UI:getTopmostVisibleWidget()
            return top and type(top.getButtonById)=='function' and top:getButtonById('reader_progress')~=nil
        end)
        assert(UI:getTopmostVisibleWidget():getButtonById('reader_progress')):onTapSelectButton()
        pump(function() return active._weread_reader_progress~=nil end)
        local state=assert(active._weread_reader_progress)
        local wanted=(expected.before+expected.words*state.snapshot.percent/100)/expected.total*100
        assert(type(state.whole_estimate)=='number' and math.abs(state.whole_estimate-wanted)<1e-7,
            'native progress estimate differed from independent catalog weights')
        local util=require('weread.lib.plugin_util')
        assert(state.dialog.title:find(util.T(util.tr('Chapter %1 / %2'),tostring(expected.order),tostring(expected.count)),1,true),
            'native progress panel displayed the wrong chapter')
        assert(reader.document:isXPointerInCurrentPage(anchor),'progress panel changed the reading page')
        UI:close(state.dialog)
    end
end
local result={ok=true,mode=input.mode,network_blocked=true}
if input.progress_estimate then result.progress_estimate=true end
print('WEREAD_NATIVE_HOME='..json.encode(result))
os.exit(0)
