require('ffi').log=function() end
require('setupkoenv')
local home=assert(os.getenv('KO_HOME'))
package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
local Device=require('device');require('document/canvascontext'):init(Device)
local UI=require('ui/uimanager')
local count=assert(tonumber(arg[1]));local offline=arg[2]=='offline'
local shots=assert(os.getenv('WEREAD_CATALOG_SHOTS'))
local scope={vid='123',epoch=1}
local selected={scope=scope,fingerprint=('a'):rep(64),credentials={vid='123'}}
local Access=require('weread.lib.native_read_access')
Access.capture=function() return selected end
Access.matches=function(_,value) return value==selected end
package.loaded['weread.lib.native_authorization']={new=function() return {cancel=function() end} end}
local chapters={}
for i=1,count do
    chapters[i]={chapterUid=tostring(i),title=('Synthetic chapter %05d'):format(i),
        chapterIdx=i,downloadable=i~=count}
end
local model={book_id='42',version=7,reading_digest=('b'):rep(64),reading_chapters=chapters}
package.loaded['weread.lib.native_book_catalog']={read=function() return model end}
local picked
package.loaded['weread.lib.native_direct_reader']={build=function(_,_,_,chapter)
    picked=chapter.chapterUid
    return {path=home..'/native-reader-v1/synthetic.epub',book_version=7,
        source_sha256=('c'):rep(64),missing_images=0}
end}
if offline then
    local entries={}
    for i=1,count do
        entries[i]={key=('%064x'):format(i),copy=0,title=('Synthetic chapter %05d'):format(i),
            book_version=7,chapter_uid=tostring(i),missing_images=i%2,pending_offline=i==count and true or nil}
    end
    package.loaded['weread.lib.native_direct_cache']={MAX_ENTRIES=2000,
        list=function() return entries end,valid_entry=function() return true end,
        open=function(_,_,_,entry)
            picked=entry.chapter_uid
            return {path=home..'/native-reader-v1/synthetic.epub',book_version=7,
                source_sha256=('c'):rep(64),missing_images=entry.missing_images}
        end}
end
local settings={data_dir=home,get_auth_scope=function() return scope end,
    auth_scope_matches=function(_,value) return value==scope end}
local view={}
local host={settings=settings,client={},ui={},discovery_epoch=1,_reader_session_gen=1,
    _book_detail_view=view,isNetworkConnected=function() return not offline end,
    showBusy=function(self) self.busy_message={} end,closeBusy=function(self) self.busy_message=nil end,
    showInfo=function(_,message) error(message) end,showOffline=function() error('offline') end,
    showList=require('weread.ui.common').showList,openFile=function(self,path) self.opened=path end,
    _native_direct_worker={start=function(_,task,callback) callback(task());return true end,cancel=function() end}}
local Reading=require('weread.ui.native_direct_reading')
collectgarbage('collect');collectgarbage('collect')
local memory=collectgarbage('count');local started=os.clock()
assert(Reading.start(host,{book_id='42',title='Synthetic book',author='Test'},view))
local elapsed=os.clock()-started
local menu=assert(host._native_direct_reading.menu)
collectgarbage('collect');collectgarbage('collect')
local retained=collectgarbage('count')-memory
assert(#chapters==count and #menu.item_table==count)
UI:forceRePaint();Device.screen:shot(shots..'/first.png')
menu:onGotoPage(menu.page_num);UI:forceRePaint();Device.screen:shot(shots..'/last.png')
if offline then
    assert(menu.item_table[count].text:find('Offline position to review',1,true),'pending state missing')
    menu:onMenuSelect(menu.item_table[count])
else
    menu:onMenuSelect(menu.item_table[count])
    assert(not picked and host._native_direct_reading.menu==menu,'unavailable chapter selected')
    menu:onMenuSelect(menu.item_table[count-1])
end
assert(picked==tostring(offline and count or count-1) and host.opened==home..'/native-reader-v1/synthetic.epub')
assert(not host._native_direct_reading,'selection did not close the menu')
print('\nWEREAD_NATIVE_CATALOG_MENU='..require('json').encode({result='PASS',count=count,
    seconds=elapsed,retained_lua_kib=retained,selection=true,unavailable=true})..'\n')
