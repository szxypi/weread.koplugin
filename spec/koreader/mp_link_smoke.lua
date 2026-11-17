-- Packaged widgets, SQLite, worker, HTTP and cache; synthetic account only.
require('setupkoenv')
local home,evidence=assert(os.getenv('KO_HOME')),assert(os.getenv('WEREAD_EVIDENCE'))
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
G_reader_settings:saveSetting('language','zh_CN');require('gettext').changeLang('zh_CN')
package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
local Device=require('device');require('document/canvascontext'):init(Device)
local UI=require('ui/uimanager');UI:setRunForeverMode();UI:setInputTimeout(0)
assert(require('weread.lib.mock_environment').save{enabled=true,host='127.0.0.1',port=assert(tonumber(os.getenv('WEREAD_MOCK_PORT')))})
local Plugin=dofile(home..'/plugins/weread.koplugin/main.lua')
local plugin=Plugin:new{ui={menu={registerToMainMenu=function() end}}}
local socket=require('socket')
local function tick() UI:shiftScheduledTasksBy(-1e9);UI:setInputTimeout(0);UI:handleInput() end
local function pump(test)
    local deadline=socket.gettime()+30
    repeat tick();if test() then return end;assert(socket.gettime()<deadline,'article import deadline');socket.sleep(.01) until false
end
local reopen=os.getenv('WEREAD_MP_LINK_REOPEN')=='1'
if not reopen then
    local login=require('weread.lib.qr_login'):new({},plugin.client,plugin.settings)
    login.login_cookies={wr_fp='1234567890'}
    login:_complete_protocol({succeed=true,webLoginVid='900000',accessToken='mock-web-access'},login.generation)
    local scope=assert(plugin.settings:get_auth_scope())
    local credentials={vid=scope.vid,accessToken='mock-native-access',refreshToken='mock-native-refresh',deviceId=string.rep('1',32)}
    assert(require('weread.lib.native_credentials'):new(plugin.settings):save(credentials,scope,0,0))
else
    plugin.client.request=function() error('offline reopen sent HTTP') end
end
plugin.isNetworkConnected=function() return not reopen end
plugin:applyShelfSnapshot({},{})
plugin:showShelfView('public_account')
local view=assert(plugin.shelf_view)
local function choose(label)
    view:showOptions();local options=assert(view._shelf_popup);local choice
    for _,row in ipairs(options.buttons) do for _,button in ipairs(row) do
        if button.text==require('weread.lib.i18n').tr(label) then choice=button end
    end end
    assert(choice,'article option missing');choice.callback();pump(function() return view._shelf_popup~=options end)
end
if not reopen then
    choose('Import article link');local input=assert(view._shelf_popup);assert(input.setInputText)
    input:setInputText('https://mp.weixin.qq.com/s/synthetic_article');input.buttons[1][2].callback()
    pump(function() return not plugin.mp_link_job end)
else choose('Imported articles') end
local menu=assert(plugin._mp_link_menu);assert(#menu.item_table==1 and menu.item_table[1].text=='合成导入文章标题','imported article title missing')
UI:forceRePaint();Device.screen:shot(evidence..(reopen and '/imported-offline.png' or '/imported.png'))
if not reopen then
    UI:close(menu);choose('Manage public account subscriptions')
    local accounts=assert(plugin._mp_link_menu);assert(#accounts.item_table==1,'public-account manager missing imported account')
    accounts:onMenuSelect(accounts.item_table[1])
    local function change(label)
        local state=assert(plugin._shelf_state_menu);local action
        for _i,row in ipairs(state.item_table) do
            if row.text==require('weread.lib.i18n').tr('Change cloud membership') then action=row end
        end
        assert(action,'subscription status action missing');state:onMenuSelect(action)
        pump(function() return plugin._shelf_membership_ui and plugin._shelf_membership_ui.dialog end)
        local dialog=assert(plugin._shelf_membership_ui.dialog)
        assert(dialog.ok_text==require('weread.lib.i18n').tr(label),'wrong subscription confirmation')
        dialog.ok_callback();pump(function() return not plugin._shelf_membership_ui end)
        assert(not plugin.shelf_membership:pending(),'confirmed subscription remained pending')
        local notice=UI:getTopmostVisibleWidget();if notice and notice.text then UI:close(notice) end
    end
    change('Subscribe');change('Unsubscribe')
    if plugin._shelf_state_menu then UI:close(plugin._shelf_state_menu) end
    local book={book_id='MP_WXS_900098',title='合成公众号'}
    assert(not plugin:getCachedMPArticles(book.book_id),'new account unexpectedly has a cached list')
    plugin:showMPAccount(book);pump(function() return not plugin.mp_catalog_job end)
    local first=assert(plugin._mp_article_list_view)
    assert(first.item_table[1].text=='合成导入文章标题','new public account did not load latest article')
    local saved=assert(plugin:getCachedMPArticles(book.book_id))
    saved[#saved+1]={reviewId='MP_WXS_900098_old',bookId=book.book_id,title='已有文章'}
    plugin:cacheMPArticles(book.book_id,saved,{latest=true})
    assert(plugin:fetchMPLatest(book));pump(function() return not plugin.mp_catalog_job end)
    local articles=assert(plugin._mp_article_list_view)
    assert(articles.item_table[1].text=='合成导入文章标题' and articles.item_table[2].text=='已有文章','latest erased saved article')
    local notice=false
    for _i,item in ipairs(articles.item_table) do
        if item.text==require('weread.lib.i18n').tr('Latest article and saved articles; earlier articles may be unavailable.') then notice=true end
    end
    assert(notice and plugin.settings:get('books',{})[book.book_id].mp_latest_only,'latest was presented as complete history')
    plugin:closeWeReadUI();plugin:showShelfView('public_account');view=assert(plugin.shelf_view)
    choose('Imported articles');menu=assert(plugin._mp_link_menu)
else
    local book={book_id='MP_WXS_900098',title='合成公众号'}
    plugin:showMPAccount(book)
    local articles=assert(plugin._mp_article_list_view)
    assert(articles.item_table[1].text=='合成导入文章标题' and articles.item_table[2].text=='已有文章','offline latest cache was lost')
    plugin:closeWeReadUI();plugin:showShelfView('public_account');view=assert(plugin.shelf_view)
    choose('Imported articles');menu=assert(plugin._mp_link_menu)
end
local opened;plugin.openFile=function(_self,path) opened=path end
menu:onMenuSelect(menu.item_table[1]);pump(function() return opened~=nil or not plugin.mp_download_job and not plugin.mp_records_job end)
assert(opened,'imported article did not open')
local file=assert(io.open(opened,'rb'));local content=file:read('*a');file:close()
assert(content:find('合成导入文章正文',1,true),'cached article body missing')
local document=require('document/documentregistry'):openDocument(opened)
assert(document and document:loadDocument(),'native reader could not load imported article')
document:render();assert(document:getPageCount()>0);document:close()
plugin:closeWeReadUI()
print('PASS: imported article native lookup, cache and offline reopen')
