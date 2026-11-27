-- Fresh KOReader process: choose a saved chapter without credentials or network.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
assert(os.getenv('WEREAD_SYNTHETIC')=='1')
package.path=assert(arg[1])..'/?.lua;'..package.path
assert(dofile(arg[1]..'/spec/koreader/offline_network_guard.lua')())
G_reader_settings=require('luasettings'):wrap({});G_defaults=require('luadefaults'):open()
local Device=require('device');require('document/canvascontext'):init(Device)
local UI=require('ui/uimanager');local socket=require('socket');local home=assert(os.getenv('KO_HOME'))
local test=assert(arg[2]);local path=assert(arg[3]);local scope={vid=test=='other' and '87654321' or '12345678',epoch=1}
local settings={data_dir=home,cache_dir=home,get=function(_,_,default) return default end,
    get_auth_scope=function() return scope end,auth_scope_matches=function(_,value) return value==scope end}
require('weread.lib.native_read_access').capture=function() error('offline lookup requested credentials') end
local client=require('weread.lib.client'):new(settings)
client.request=function() error('offline lookup attempted a network request') end
local Common=require('weread.ui.common')
local host={settings=settings,client=client,discovery_epoch=1,_reader_session_gen=1,
    library_db={accountKey=function() return scope.vid end},ui={},isNetworkConnected=function() return false end,
    showBusy=Common.showBusy,closeBusy=Common.closeBusy,refreshUI=function() end,
    showInfo=function(self,message) self.message=message end,showOffline=function() error('unexpected offline error') end,
    showInputDialog=Common.showInputDialog,showList=Common.showList,showBookMenu=require('weread.ui.library').showBookMenu,
    getFullBookCachePath=function() return home..'/missing.epub' end,bookRecordHasDownload=function() return false end,
    safeCallback=function(_,_,callback) return callback end,openFile=function(self,file) self.opened=file end}
local function wait(predicate)
    local deadline=socket.gettime()+90
    while not predicate() do
        assert(socket.gettime()<deadline,'offline chapter UI timeout')
        UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
    end
end
host:showBookMenu({book_id='42',title='Synthetic native book',author='Fixture',chapters={}})
local detail=assert(host._book_detail_view);local action
local tr=require('weread.lib.plugin_util').tr
local damage_message=tr('The saved E-Ink chapter is damaged or has changed. The file was kept.')
local label=test=='normal' and 'Read E-Ink chapter' or 'Read saved E-Ink chapter'
for _,button in ipairs(detail._action_buttons) do if button.text==tr(label) then action=button end end
assert(action and action.enabled~=false);action.callback()
wait(function() return host.message or host._native_direct_reading and host._native_direct_reading.menu end)
if test=='other' or test=='bad-entry' then
    assert(host.message==tr('No usable saved E-Ink chapters for this book and account. Existing files are kept.') and not host.opened)
else
    local ctx=assert(host._native_direct_reading)
    local menu=assert(ctx.menu)
    if arg[4] then
        local marker=arg[4]=='1' and tr('%1 images unavailable'):gsub('%%1','1') or tr('No missing images')
        for _,item in ipairs(menu.item_table) do assert(item.text:find(marker,1,true),'missing image state not shown') end
    end
    if test=='copies' then
        assert(#menu.item_table==2 and menu.item_table[1].text~=menu.item_table[2].text)
        local first,second=menu.item_table[1].text,menu.item_table[2].text
        assert(menu.title_bar.left_button).callback()
        local search=assert(menu._shelf_popup)
        search:setInputText(assert(first:match('^(.-)  ·  ')));search.buttons[1][2].callback()
        assert(#menu.item_table==2 and menu.item_table[1].chapter_index==1 and menu.item_table[2].chapter_index==2)
        assert(menu.item_table[1].text:sub(-#first)==first and menu.item_table[2].text:sub(-#second)==second,
            'filter changed the saved copy labels')
        local items,subtitle,page=menu.item_table,menu.subtitle,menu.page
        menu:onMenuSelect(items[1])
        wait(function() return host.opened or host.message end)
        assert(not host.opened and host.message==damage_message and not host.busy_message)
        assert(ctx.menu==menu and menu.item_table==items and menu.subtitle==subtitle and menu.page==page,
            'failed copy lost the active filtered chapter list')
        host.message=nil
    else assert(#menu.item_table==1) end
    if test=='damage' then local file=assert(io.open(path,'ab'));assert(file:write('corrupt'));assert(file:close()) end
    if test=='switch' then scope={vid='87654321',epoch=2} end
    if test=='cancel' then
        menu:onMenuSelect(menu.item_table[1])
        assert(host._native_direct_worker.job,'file check did not start')
        assert(host.busy_message):onTapClose()
        assert(not host.opened and not host.busy_message and not host._native_direct_worker.job
            and host._native_direct_reading==ctx and ctx.menu==menu,'cancel did not restore the saved list')
    end
    menu:onMenuSelect(menu.item_table[test=='copies' and 2 or 1])
    if test=='switch' then
        assert(not host.opened and not host._native_direct_worker.job)
    else
        wait(function() return host.opened or host.message end)
        if test=='damage' or test=='bad-receipt' then
            assert(not host.opened and host.message==damage_message and ctx.menu==menu and not host.busy_message)
            assert(require('libs/libkoreader-lfs').attributes(path))
        else assert(host.opened==path and not host._native_direct_reading and not host.busy_message) end
    end
end
print('WEREAD_DIRECT_CACHED_UI='..require('json').encode{ok=true,case=test,network_blocked=true})
