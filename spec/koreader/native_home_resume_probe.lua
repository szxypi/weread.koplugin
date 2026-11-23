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
if input.mode=='record' then
    settings:set('account',{user_vid=vid,name='Synthetic',login_method='qr'})
    settings:set('cookies',{wr_vid=vid, wr_skey='synthetic'})
    local sync=settings:get('sync');sync.pull_on_open=false;sync.upload_on_close=false;sync.upload_interval_minutes=0;settings:set('sync',sync)
    local report=settings:get('read_report');report.enabled=false;settings:set('read_report',report)
    settings:set('books',{[id]={book_id=id,title='Synthetic book',author='Fixture'}});settings:flush()
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
if input.mode=='record' then
    Reader:showReader(input.path)
    pump(function() return Reader.instance and Reader.instance.weread end)
    local reader=Reader.instance
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
    local file=assert(io.open(home..'/anchor','wb'));assert(file:write(anchor));file:close()
    while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=reader do UI:close(UI:getTopmostVisibleWidget()) end
    reader.weread:onFlushSettings();reader:onClose(false)
    assert(not Reader.instance)
else
    FM:showFiles(home);local host=assert(FM.instance.weread)
    host:showHome();local view=assert(host.shelf_view);local selected
    for _,book in ipairs(view.books) do if book.bookId==id then selected=book end end
    if input.mode=='switch' then
        assert(not selected,'other account saw native home history')
        print('WEREAD_NATIVE_HOME='..json.encode{ok=true,mode=input.mode,network_blocked=true})
        os.exit(0)
    end
    if input.store_search then
        local saved=assert(host.settings:get_book(id))
        assert(selected and type(saved.title)=='string' and saved.title~='' and selected.title==saved.title,
            'native search book not listed on home')
    else assert(selected and selected.title=='Synthetic book','native chapter not listed on home') end
    local message
    local damage=input.mode=='damage' or input.mode=='detail_damage' or input.mode=='shelf_damage'
    local shelf=input.mode=='shelf_detail' or input.mode=='shelf_damage'
    if damage then host.showInfo=function(_,text) message=text end end
    if shelf then
        host.isNetworkOnline=function() return false end
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
    if shelf or input.mode=='detail' or input.mode=='detail_damage' or input.mode=='detail_closed' then
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
        pump(function() return message~=nil end)
        assert(not Reader.instance,'damaged native chapter opened')
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
