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
local record=input.mode=='record' or record_alternative or suspend_record
if record then
    settings:set('account',{user_vid=vid,name='Synthetic',login_method='qr'})
    settings:set('cookies',{wr_vid=vid, wr_skey='synthetic'})
    local sync=settings:get('sync');sync.pull_on_open=false;sync.upload_on_close=false;sync.upload_interval_minutes=0;settings:set('sync',sync)
    local report=settings:get('read_report');report.enabled=false;settings:set('read_report',report)
    settings:set('books',{[id]={book_id=id,title='Synthetic book',author='Fixture'}});settings:flush()
    if suspend_record then assert(settings:patch_reading_state(id,{native_home_resume=false})) end
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
    pump(function() local b=reader.weread.settings:get_book(id);return b and b.native_home_resume end)
    assert(not reader.weread:detectWeReadBook())
    if reader.document:getPageCount()<2 then
        assert(reader.font:onSetFontSize(48));UI:forceRePaint()
    end
    assert(reader.document:getPageCount()>=2,'sample does not cover page navigation')
    local first=assert(reader.document:getXPointer())
    reader.rolling:onGotoPage(2);UI:forceRePaint()
    local anchor=assert(reader.document:getXPointer())
    assert(anchor~=first,'page navigation did not advance')
    local anchor_path=record_alternative and '/alternative-anchor' or '/anchor'
    local file=assert(io.open(home..anchor_path,'wb'));assert(file:write(anchor));file:close()
    while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=reader do UI:close(UI:getTopmostVisibleWidget()) end
    reader.weread:onFlushSettings();reader:onClose(false)
    assert(not Reader.instance)
else
    FM:showFiles(home);local host=assert(FM.instance.weread)
    if input.mode=='detail_read_saved' then
        assert(os.getenv('WEREAD_SYNTHETIC')=='1')
        require('ui/network/manager').isConnected=function() return false end
        assert(host.settings:patch_reading_state(id,{native_home_resume=false}))
        local detail=assert(host:showBookMenu(assert(host.settings:get_book(id))))
        for _,action in ipairs(detail._footer_actions) do
            if action.text==require('weread.lib.plugin_util').tr('▤ Read') then action.callback();break end
        end
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
    local message
    local damage=input.mode=='damage' or input.mode=='detail_damage' or input.mode=='shelf_damage' or input.mode=='no_alternative'
    local shelf=input.mode=='shelf_detail' or input.mode=='shelf_damage'
    local repair=input.mode=='downloads_repair' or input.mode=='downloads_repair_unwritable'
    local downloads=input.mode=='downloads' or input.mode=='downloads_choose' or repair
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
            assert(button.text==require('weread.lib.plugin_util').tr(downloads and 'Read downloaded copy' or 'Read now'))
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
        pump(function() return message or Reader.instance or picker() end)
        assert(not Reader.instance,'fallback opened a chapter without a selection')
        local tr=require('weread.lib.plugin_util').tr
        if input.mode=='no_alternative' then
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
