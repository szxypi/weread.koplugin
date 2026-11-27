-- Real KOReader dialogs and workers; account-scoped navigation, optionally offline.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
assert(os.getenv('WEREAD_SYNTHETIC')=='1')
package.path=assert(arg[1])..'/?.lua;'..package.path
local json=require('json');local input=json.decode(assert(io.stdin:read('*a')))
if input.mode~='online' then assert(dofile(arg[1]..'/spec/koreader/offline_network_guard.lua')()) end
G_reader_settings=require('luasettings'):wrap({});G_defaults=require('luadefaults'):open()
local Device=require('device');require('document/canvascontext'):init(Device)
local UI=require('ui/uimanager');local socket=require('socket');local home=assert(os.getenv('KO_HOME'))
local scope={vid='12345678',epoch=1};local online=input.mode=='online'
local connected=online
local settings={data_dir=home,cache_dir=home,mock_endpoint=input.mock_endpoint,
    get=function(_,_,default) return default end,get_book=function() return nil end,
    get_auth_scope=function() return scope end,auth_scope_matches=function(_,value) return value==scope end}
local Access=require('weread.lib.native_read_access');local original=Access.capture
if online then
    local store={read=function() return input.credentials,1,nil,false end}
    Access.capture=function(s,existing)
        assert(connected,'offline navigation requested native credentials')
        return original(s,existing or store)
    end
else Access.capture=function() error('offline navigation requested credentials') end end
local client=require('weread.lib.client'):new(settings);local request=client.request
client.request=function(self,options)
    assert(connected,'offline navigation requested network')
    local url,headers=options.url,options.headers or {}
    assert(options.skip_cookie and options.persist_response_cookies==false and options.sensitive)
    assert((url=='https://i.weread.qq.com/book/info?bookId=42' and options.method=='GET')
        or (url=='https://i.weread.qq.com/book/chapterInfos' and options.method=='POST')
        or (url:find('https://i.weread.qq.com/book/chapterdownload?',1,true)==1 and options.method=='GET')
        or (require('weread.lib.native_chapter_remote').allowed(url)==url and options.method=='GET'
            and not headers.vid and not headers.accessToken and not headers.Cookie))
    return request(self,options)
end
local base=require('ui/widget/infomessage'):new{text='Fixture'};base.modal=false;UI:show(base)
local Common=require('weread.ui.common')
local host={settings=settings,client=client,discovery_epoch=1,_reader_session_gen=1,
    library_db={accountKey=function() return 'synthetic' end,getChapters=function() return {} end},ui={document={file=input.first}},
    isNetworkConnected=function() return connected end,
    showBusy=Common.showBusy,closeBusy=Common.closeBusy,refreshUI=function() end,
    showInfo=function(self,message) self.message=message end,showOffline=function() error('unexpected offline') end,
    showList=Common.showList,showInputDialog=Common.showInputDialog,showBookMenu=require('weread.ui.library').showBookMenu,
    getFullBookCachePath=function() return home..'/missing.epub' end,bookRecordHasDownload=function() return false end,
    safeCallback=function(_,_,callback) return callback end,
    openFile=function(self,path) self.opened=path;self.ui.document={file=path};self._reader_session_gen=self._reader_session_gen+1 end,
    onShowWeReadQuickMenu=require('weread.ui.reader_navigation').onShowWeReadQuickMenu}
local tr=require('weread.lib.plugin_util').tr
local function wait(predicate)
    local deadline=socket.gettime()+90
    while not predicate() do
        assert(socket.gettime()<deadline,'native reader navigation timeout')
        UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
    end
end
local function quick_menu()
    assert(host:onShowWeReadQuickMenu())
    wait(function()
        local top=UI:getTopmostVisibleWidget()
        return host.message or host._native_direct_navigation and host._native_direct_navigation.entry
            and not host.busy_message and top and type(top.getButtonById)=='function'
    end)
    assert(not host.message)
    local dialog=assert(UI:getTopmostVisibleWidget());UI:forceRePaint()
    return dialog
end
local function press(id)
    local dialog=quick_menu()
    local action=assert(dialog:getButtonById(id))
    assert(action.enabled~=false);action:onTapSelectButton()
end
if online then
    local interrupted=home..'/interrupt-catalog'
    assert(assert(io.open(interrupted,'wb')):close())
    press('chapter_list')
    wait(function() return host.message or host._native_direct_reading and host._native_direct_reading.menu end)
    local fallback=assert(host._native_direct_reading)
    assert(not host.message and fallback.offline and #fallback.menu.item_table==2
        and fallback.menu.subtitle==tr('The online catalog is unavailable. Showing saved chapters.')
        and not host.opened and not host.busy_message,'rate limited catalog did not offer saved copies')
    fallback.menu:onClose()
    assert(os.remove(interrupted))
    assert(not host._native_direct_reading and UI:getTopmostVisibleWidget()==base and host.ui.document.file==input.first,
        'closing the fallback did not keep the current page')
    press('next_chapter')
    wait(function() return host.opened or host.message or host._native_direct_reading and host._native_direct_reading.target end)
    assert(host._native_direct_reading and host.busy_message and not host._book_detail_view,
        'starting the adjacent download put book details over the reader')
    host.busy_message:onTapClose()
    assert(not host._native_direct_reading and not host.busy_message and not host.opened and not host.message
        and UI:getTopmostVisibleWidget()==base and host.ui.document.file==input.first,
        'cancelling the adjacent download did not keep the current chapter')
end
press('next_chapter')
wait(function() return host.opened or host.message or host._native_direct_navigation and host._native_direct_navigation.menu end)
if input.mode=='copies' then
    local ctx=assert(host._native_direct_navigation)
    local menu=assert(ctx.menu)
    assert(#menu.item_table==2 and not host.opened)
    local complete,missing
    for _,item in ipairs(menu.item_table) do
        if item.text:find(tr('No missing images'),1,true) then complete=item end
        if item.text:find(tr('%1 images unavailable'):gsub('%%1','1'),1,true) then missing=item end
    end
    assert(complete and missing,'copy completeness labels not found')
    if input.choose=='complete' then
        local file=assert(io.open(input.missing_copy,'ab'));assert(file:write('corrupt'));assert(file:close())
        local page=menu.page
        menu:onMenuSelect(missing)
        wait(function() return host.opened or host.message end)
        assert(not host.opened and host.message==tr('The saved chapter changed or could not be verified. Existing files were kept.')
            and not host.busy_message and ctx.menu==menu and menu.page==page,'damaged copy closed or reset the chooser')
        host.message=nil
        menu:onMenuSelect(complete)
        assert(host._native_direct_navigation_worker.job)
        assert(host.busy_message):onTapClose()
        assert(host._native_direct_navigation==ctx and ctx.menu==menu and not host.busy_message
            and not host._native_direct_navigation_worker.job and not host.opened,'cancel did not return to the chooser')
    end
    menu:onMenuSelect(input.choose=='complete' and complete or missing)
    wait(function() return host.opened or host.message end)
    assert(not host.message and host.opened==(input.choose=='complete' and input.second or input.missing_copy))
end
if input.mode=='gap' then
    assert(not host.opened and host.message==tr('The adjacent chapter is not saved. Connect to download it.'))
    host.message=nil
    local first=quick_menu()
    assert(first:getButtonById('previous_chapter').enabled==false)
    UI:close(first)
    host.ui.document={file=assert(input.last)};host._reader_session_gen=host._reader_session_gen+1
    local last=quick_menu()
    assert(last:getButtonById('next_chapter').enabled==false and last:getButtonById('previous_chapter').enabled~=false)
    UI:close(last)
    G_reader_settings:saveSetting('end_document_action','next_file')
    assert(require('weread.lib.reader_lifecycle').handleEndOfBook(host,{}))
    wait(function() return host.opened or host.message end)
    assert(not host.opened and host.message==tr('You have reached the last chapter.'))
else
    assert(host.opened and (input.mode=='online' or input.mode=='copies' or host.opened==input.second))
    local second=host.opened
    if input.mode=='online' then
        G_reader_settings:saveSetting('items_per_page',1)
        G_reader_settings:saveSetting('items_font_size',20)
        press('chapter_list')
        wait(function() return host.message or host._native_direct_reading and host._native_direct_reading.menu end)
        local ctx=assert(host._native_direct_reading)
        local menu=assert(ctx.menu)
        local prefix=tr('Current chapter')..' · '
        assert(not host.message and not ctx.offline and menu.page==2 and menu.item_table[2].text:find(prefix,1,true)==1
            and not menu.item_table[1].text:find(prefix,1,true) and host.opened==second,
            'online reader did not open the catalog at its current chapter')
        assert(menu.title_bar.left_icon=='appbar.menu' and menu.item_table[1].bold
            and menu.item_table[2].indent==Device.screen:scaleBySize(16) and not menu.item_table[3].indent,
            'section titles or normalized indentation were not shown')
        local function catalog_action(index)
            menu:onLeftButtonTap()
            local actions=assert(menu._shelf_popup)
            actions.buttons[index][1].callback()
            wait(function() return menu._shelf_popup and menu._shelf_popup~=actions end)
            return menu._shelf_popup
        end
        local search=catalog_action(1)
        search:setInputText('inside')
        search.buttons[1][2].callback()
        assert(#menu.item_table==1 and menu.item_table[1].chapter_index==2)
        local sections=catalog_action(2)
        assert(sections.title==tr('Sections') and #sections.item_table==1 and sections.item_table[1].text:find('Chapter group',1,true))
        sections:onMenuSelect(sections.item_table[1])
        assert(menu.page==1 and #menu.item_table==3 and not menu._shelf_popup and not host._native_direct_worker.job
            and menu.item_table[2].text:find(prefix,1,true)==1,'section jump did not restore the catalog at the heading')
        search=catalog_action(1)
        search:setInputText('Chapter')
        search.buttons[1][2].callback()
        menu:onGotoPage(2)
        local filtered=menu.item_table
        local item=assert(filtered[2])
        local Reader=require('weread.lib.native_direct_reader')
        local build=Reader.build
        Reader.build=function() return nil,'rate_limited' end
        menu:onMenuSelect(item)
        assert(ctx.menu==menu and host._native_direct_worker.job and host.busy_message)
        host.busy_message:onTapClose()
        assert(ctx.menu==menu and menu.item_table==filtered and menu.page==2 and not host._native_direct_worker.job
            and UI:getTopmostVisibleWidget()==menu and host.opened==second,
            'cancelling preparation did not keep the online search and its page')
        menu:onMenuSelect(item)
        wait(function() return host.message or not host.busy_message end)
        assert(host.message==tr('WeRead is limiting requests. Please try again later.') and ctx.menu==menu
            and menu.item_table==filtered and menu.page==2 and UI:getTopmostVisibleWidget()==menu and host.opened==second,
            'failed preparation did not keep the online search and its page')
        Reader.build=build
        host.message=nil
        menu:onClose()
        assert(not host._book_detail_view and not host._native_direct_reading and not host.busy_message
            and UI:getTopmostVisibleWidget()==base and host.ui.document.file==second,
            'closing the online catalog did not return to the current chapter')
        press('chapter_list')
        wait(function() return host.message or host._native_direct_reading and host._native_direct_reading.menu end)
        menu=assert(host._native_direct_reading.menu)
        connected=false
        menu:onGotoPage(3)
        menu:onMenuSelect(menu.item_table[3])
        wait(function() return host.message or not host.busy_message end)
        assert(host.message==tr('No saved copy matches this chapter. Connect to download it.')
            and menu.page==3 and UI:getTopmostVisibleWidget()==menu and host.ui.document.file==second,
            'an uncached chapter did not keep the catalog open after disconnecting')
        host.message,host.opened=nil,nil
        menu:onGotoPage(1)
        menu:onMenuSelect(menu.item_table[1])
        wait(function() return host.message or host.opened or host._native_direct_reading and host._native_direct_reading.copy_menu end)
        local copies=assert(host._native_direct_reading.copy_menu)
        assert(#copies.item_table==2 and not host.busy_message and UI:getTopmostVisibleWidget()==copies,
            'the catalog did not show both matching local copies')
        copies:onClose()
        assert(host._native_direct_reading.menu==menu and not host._native_direct_reading.copy_menu
            and menu.page==1 and UI:getTopmostVisibleWidget()==menu and host.ui.document.file==second,
            'closing the copy chooser lost the chapter catalog')
        connected=true
        assert(assert(io.open(home..'/interrupt-download','wb')):close())
        menu:onMenuSelect(menu.item_table[1])
        wait(function() return host.message or host.opened or host._native_direct_reading and host._native_direct_reading.copy_menu end)
        assert(not host.message and not host.opened and host._native_direct_reading
            and host._native_direct_reading.copy_menu,'disconnected transport did not fall back to local copies')
        copies=host._native_direct_reading.copy_menu
        local missing
        for _,candidate in ipairs(copies.item_table) do
            if candidate.text:find(tr('%1 images unavailable'):gsub('%%1','1'),1,true) then missing=candidate end
        end
        copies:onMenuSelect(assert(missing))
        wait(function() return host.message or host.opened end)
        assert(not host.message and host.opened==input.missing_copy and not host._native_direct_reading and not host.busy_message,
            'a saved chapter did not open directly from the catalog after disconnecting')
    end
    if input.mode=='two' then
        host.opened=nil
        press('previous_chapter');wait(function() return host.opened or host.message end)
        assert(not host.message and host.opened==input.first)
        host.opened=nil;host.ui.document={file=second};host._reader_session_gen=host._reader_session_gen+1
        G_reader_settings:saveSetting('end_document_action','next_file')
        assert(require('weread.lib.reader_lifecycle').handleEndOfBook(host,{}))
        wait(function() return host.opened or host.message end)
        assert(not host.opened and host.message==tr('The adjacent chapter is not saved. Connect to download it.'))
    end
end
print('WEREAD_DIRECT_NAV_RESULT='..json.encode{ok=true,mode=input.mode,path=host.opened or ''})
