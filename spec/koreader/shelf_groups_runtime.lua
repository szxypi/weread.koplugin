-- Synthetic native Menu/InputDialog lifetime, SQLite groups and fresh offline pages.
require('setupkoenv')
local home,evidence=assert(os.getenv('KO_HOME')),assert(os.getenv('WEREAD_EVIDENCE'))
local mode=assert(os.getenv('WEREAD_GROUP_MODE'))
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
G_reader_settings:saveSetting('language','zh_CN');require('gettext').changeLang('zh_CN')
package.path=assert(os.getenv('WEREAD_SOURCE'))..'/?.lua;'..package.path
local Device=require('device');require('document/canvascontext'):init(Device)
assert(require('weread.lib.mock_environment').save{enabled=true,host='127.0.0.1',port=8765})
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
local Loader=require('pluginloader')
Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
for _entry_index,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
assert(#Loader.enabled_plugins==1)
local UI=require('ui/uimanager');UI:setRunForeverMode();UI:setInputTimeout(0)
local FileManager=require('apps/filemanager/filemanager');FileManager:showFiles(home)
local plugin=assert(FileManager.instance.weread)

local json,socket=require('json'),require('socket')
local file=assert(io.open(evidence..'/fixture.json','rb'));local raw=file:read(256*1024+1);file:close();assert(#raw<=256*1024)
local input=json.decode(raw);local shelf=require('weread.lib.shelf_source').normalize(input.shelf,'web')
local requests=0
plugin.client.request=function() requests=requests+1;error('offline group fixture attempted HTTP',0) end
plugin.isNetworkOnline=function() return false end;plugin.isNetworkConnected=plugin.isNetworkOnline
if mode=='live' then assert(plugin.library_db:cacheShelf(shelf.books,shelf.archive)) end
local books=assert(plugin.library_db:getShelf());local archives=assert(plugin.library_db:getShelfArchives())
assert(#books==#shelf.books and #archives==#shelf.archive)
local function tick() UI:setInputTimeout(0);UI:handleInput();socket.sleep(.005) end
local function pump(predicate)
    local deadline=socket.gettime()+20
    while not predicate() do assert(socket.gettime()<deadline,'synthetic group UI deadline');tick() end
end
local function reset()
    plugin:closeWeReadUI()
    local settings=plugin.settings:get('shelf');settings.view_mode='cover';settings.paginated=true
    settings.sort_order='default';settings.filter_reading=nil;settings.filter_download=nil
    plugin.settings:set('shelf',settings);plugin.settings:flush()
    plugin:applyShelfSnapshot(books,archives);plugin:showShelfView('books')
end
local popup_cases=0
for _kind_index,kind in ipairs({'sort','filter','search'}) do
    for _event_index,event in ipairs({'current','closed','session'}) do
        reset();local view=assert(plugin.shelf_view)
        if kind=='sort' then view.on_sort() elseif kind=='filter' then view.on_filter() else view.on_search() end
        local dialog=assert(view._shelf_popup)
        local callback
        if kind=='search' then dialog:setInputText('合成书籍 1');callback=dialog.buttons[1][2].callback
        else callback=dialog.buttons[2][1].callback end
        UI:forceRePaint()
        local before=json.encode(plugin.settings:get('shelf'))
        local writes=0;local set=plugin.settings.set
        plugin.settings.set=function(self,...) writes=writes+1;return set(self,...) end
        if event=='closed' then plugin:closeWeReadUI()
        elseif event=='session' then plugin._reader_session_gen=(plugin._reader_session_gen or 0)+1 end
        callback()
        if event=='current' then
            pump(function() return plugin.shelf_view and plugin.shelf_view~=view end)
            assert(view._shelf_closed and not view._shelf_popup)
            if kind=='search' then
                assert(plugin.shelf_search_keyword=='合成书籍 1' and #plugin.shelf_view.books>0)
                for _book_index,book in ipairs(plugin.shelf_view.books) do assert(book.title:find('合成书籍 1',1,true)) end
            else assert(writes==1 and json.encode(plugin.settings:get('shelf'))~=before) end
        else
            for _i=1,5 do tick() end
            assert(writes==0 and json.encode(plugin.settings:get('shelf'))==before)
            assert(event~='closed' or not plugin.shelf_view)
        end
        plugin.settings.set=set;popup_cases=popup_cases+1
    end
end
reset();local view=plugin.shelf_view;view:showOptions();local old=assert(view._shelf_popup)
local old_choice=old.buttons[1][1].callback
view:showSourceMenu();local replacement=assert(view._shelf_popup)
old_choice();for _i=1,5 do tick() end
assert(view._shelf_popup==replacement);popup_cases=popup_cases+1
UI:forceRePaint();Device.screen:shot(evidence..'/groups-selector.png')
reset();view=plugin.shelf_view;view:showSourceMenu();local cached_popup=assert(view._shelf_popup)
plugin:showBookshelf()
assert(plugin.shelf_view~=view and view._shelf_closed and not view._shelf_popup and UI:getTopmostVisibleWidget()~=cached_popup)
popup_cases=popup_cases+1
reset()
local manifest_path=evidence..'/group-pages.json'
local manifest={pages={}}
if mode=='reopen' then file=assert(io.open(manifest_path,'rb'));manifest=json.decode(file:read('*a'));file:close() end
local report={painted_views=0}
local function paint(tag,reverse)
    local current=assert(plugin.shelf_view);local entries=json.decode('[]')
    for _book_index,book in ipairs(current:getVisibleBooks()) do entries[#entries+1]={book.bookId,book.title} end
    local key=tag..':'..current.page;local encoded=json.encode(entries)
    if mode=='live' then assert(not manifest.pages[key]);manifest.pages[key]=encoded else assert(manifest.pages[key]==encoded) end
    UI:forceRePaint();report.painted_views=report.painted_views+1
    if tag=='group:24' and not reverse then Device.screen:shot(evidence..'/groups-unavailable.png') end
end
local fixtures=assert(debug.getinfo(1,'S').source:match('^@(.*/)'))
dofile(fixtures..'shelf_groups_ui_case.lua')(plugin,input,mode,report,pump,paint,manifest)
if mode=='live' then file=assert(io.open(manifest_path,'wb'));assert(file:write(json.encode(manifest)));file:close() end
assert(requests==0)
report.result,report.mode,report.http_requests,report.popup_cases,report.fresh_db_read='PASS',mode,requests,popup_cases,true
io.write('\nWEREAD_GROUP_UI_RESULT='..json.encode(report)..'\n')
os.exit(0)
