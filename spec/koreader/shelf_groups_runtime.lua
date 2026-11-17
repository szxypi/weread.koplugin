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
if mode=='reopen' then assert(not plugin._volatile_shelf,'unsaved shelf survived a fresh process') end
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
if mode=='reopen' then
    reset();local remembered=assert(plugin.shelf_view)
    assert(#remembered.group_keys==2 and #remembered.books==21,'multi-group selection not restored in fresh offline process')
    remembered.on_select_group(nil);pump(function() return plugin.shelf_view~=remembered end)
    assert(#plugin.shelf_view.group_keys==0,'all-books selection failed to clear persisted groups')
end
local popup_cases=0
local fixtures=assert(debug.getinfo(1,'S').source:match('^@(.*/)'))
local portal=dofile(fixtures..'discovery_lifetime_case.lua')(plugin,evidence)
local saved_searches=dofile(fixtures..'saved_searches_case.lua')(plugin,mode,pump,evidence)
local home_refresh_cases=dofile(fixtures..'home_refresh_failure_case.lua')(plugin,pump)
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
-- Exercise identifier search through the real input dialog and group view
-- when the author field is absent in an older or incomplete shelf entry.
reset()
local sparse={bookId='SYN-123456',title='合成稀疏书目'}
plugin:applyShelfSnapshot({sparse, {bookId='SYN-OTHER',title='其他合成书目'}},
    {{archiveId=97,name='合成分组',bookIds={'SYN-123456'}}})
plugin.shelf_group_key='archive:97';plugin:showShelfView('books')
local search_view=assert(plugin.shelf_view);search_view.on_search()
local search_dialog=assert(search_view._shelf_popup);search_dialog:setInputText('  syn-123456  ')
search_dialog.buttons[1][2].callback();pump(function() return plugin.shelf_view and plugin.shelf_view~=search_view end)
assert(plugin.shelf_search_keyword=='syn-123456' and #plugin.shelf_view.books==1 and plugin.shelf_view.books[1].bookId=='SYN-123456',
    'identifier search missed a grouped book without an author')
UI:forceRePaint()
search_view=plugin.shelf_view;search_view.on_search();search_dialog=assert(search_view._shelf_popup)
search_dialog:setInputText('   ');search_dialog.buttons[1][2].callback()
pump(function() return plugin.shelf_view and plugin.shelf_view~=search_view end)
assert(plugin.shelf_search_keyword==nil and #plugin.shelf_view.books==1 and plugin.shelf_view.books[1].bookId=='SYN-123456',
    'whitespace-only search did not restore the selected group')
-- Real paged shelf: equal values keep original order within pinned/unpinned
-- sections after page changes and after switching the sort field.
local tied,expected,pinned,unpinned={},{},{},{}
for index=1,48 do
    local book={bookId='SYN-TIE-'..index,title='相同合成书名',readUpdateTime=1700000000,isTop=index%7==0 and 1 or 0}
    tied[#tied+1]=book;local bucket=book.isTop==1 and pinned or unpinned;bucket[#bucket+1]=book
end
for _,book in ipairs(pinned) do expected[#expected+1]=book end
for _,book in ipairs(unpinned) do expected[#expected+1]=book end
plugin:applyShelfSnapshot(tied,{})
local shelf_options=plugin.settings:get('shelf');shelf_options.sort_order='time_desc';plugin.settings:set('shelf',shelf_options)
plugin:showShelfView('books',nil,nil,{page=1});local tied_view=assert(plugin.shelf_view)
for index,book in ipairs(expected) do assert(tied_view.books[index]==book,'equal time changed shelf order') end
assert(tied_view.page_size<#expected);local page_size=tied_view.page_size
tied_view.on_page_changed(2);pump(function() return plugin.shelf_view and plugin.shelf_view~=tied_view end)
tied_view=plugin.shelf_view;assert(tied_view.page==2)
for index,book in ipairs(tied_view:getVisibleBooks()) do
    assert(book==expected[page_size+index],'equal-time page changed shelf order')
end
shelf_options.sort_order='name_desc';plugin.settings:set('shelf',shelf_options)
plugin:showShelfView('books',nil,tied_view,{page=1});tied_view=plugin.shelf_view
for index,book in ipairs(expected) do assert(tied_view.books[index]==book,'equal title changed shelf order') end
UI:forceRePaint()
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
dofile(fixtures..'shelf_groups_ui_case.lua')(plugin,input,mode,report,pump,paint,manifest)
reset();local all_view=plugin.shelf_view;plugin:applyShelfSnapshot(books,{})
plugin:showShelfView('books',nil,all_view);all_view=plugin.shelf_view;all_view:showSourceMenu('books')
local all_picker=assert(all_view._shelf_popup);assert(#all_picker.item_table==1,'empty group shelf offered an unavailable multi-group picker')
UI:close(all_picker)
if mode=='live' then
    reset();local source=assert(plugin.shelf_view);source:showSourceMenu('books')
    local picker=assert(source._shelf_popup);local multiple=assert(picker.item_table[2])
    assert(multiple.text==require('weread.lib.i18n').tr('Select multiple groups'))
    picker:onMenuSelect(multiple);pump(function() return source._shelf_popup and source._shelf_popup~=picker end)
    local chooser=assert(source._shelf_popup);assert(chooser:getSize().h<=source.screen_h and chooser:getSize().w<=source.screen_w)
    local before=json.encode(plugin.library_db:getProfileState('shelf_multi_groups_v1'))
    local cancelled=chooser.item_table[3];chooser:onMenuSelect(cancelled);pump(function() return cancelled.mandatory=='✓' end)
    UI:close(chooser);cancelled.callback();for _i=1,3 do tick() end
    assert(plugin.shelf_view==source and not source._shelf_popup
        and json.encode(plugin.library_db:getProfileState('shelf_multi_groups_v1'))==before,'cancelled multi-group chooser saved changes')
    source:showSourceMenu('books');picker=assert(source._shelf_popup);picker:onMenuSelect(picker.item_table[2])
    pump(function() return source._shelf_popup and source._shelf_popup~=picker end);chooser=assert(source._shelf_popup)
    local first,last=chooser.item_table[3],chooser.item_table[23]
    chooser:onMenuSelect(first);pump(function() return first.mandatory=='✓' end)
    local page=math.floor((23-1)/chooser.items_per_page)+1
    while chooser.page<page do chooser:onNextPage() end
    chooser:onMenuSelect(last);pump(function() return last.mandatory=='✓' end)
    while chooser.page>1 do chooser:onPrevPage() end
    UI:forceRePaint();Device.screen:shot(evidence..'/multi-group-selector.png')
    chooser:onMenuSelect(chooser.item_table[1]);pump(function() return plugin.shelf_view and plugin.shelf_view~=source end)
    assert(#plugin.shelf_view.group_keys==2 and #plugin.shelf_view.books==21,'native multi-group union incorrect')
    local selected=plugin.shelf_view;first.callback();for _i=1,3 do tick() end
    assert(plugin.shelf_view==selected,'closed multi-group selector applied a stale callback')
    local partial={};for _,archive in ipairs(archives) do if tostring(archive.archiveId)~='21' then partial[#partial+1]=archive end end
    plugin:applyShelfSnapshot(books,partial);plugin:showShelfView('books',nil,selected)
    local fallback=assert(plugin.shelf_view);assert(#fallback.books==48 and #fallback.group_keys==2,'missing group hid shelf books')
    fallback:showSourceMenu('books');picker=assert(fallback._shelf_popup);picker:onMenuSelect(picker.item_table[2])
    pump(function() return fallback._shelf_popup and fallback._shelf_popup~=picker end);chooser=assert(fallback._shelf_popup)
    local missing=assert(chooser.item_table[3]);assert(missing.text==require('weread.lib.i18n').tr('Unavailable saved group'))
    chooser:onMenuSelect(missing);pump(function() return missing.mandatory=='' end)
    chooser:onMenuSelect(chooser.item_table[1]);pump(function() return plugin.shelf_view and plugin.shelf_view~=fallback end)
    assert(#plugin.shelf_view.group_keys==1 and #plugin.shelf_view.books==20,'unavailable selection could not be removed')
    selected=plugin.shelf_view;plugin:applyShelfSnapshot(books,archives);plugin:showShelfView('books',nil,selected)
    source=plugin.shelf_view;source:showSourceMenu('books');picker=assert(source._shelf_popup);picker:onMenuSelect(picker.item_table[2])
    pump(function() return source._shelf_popup and source._shelf_popup~=picker end);chooser=assert(source._shelf_popup)
    last=assert(chooser.item_table[23]);page=math.floor((23-1)/chooser.items_per_page)+1
    while chooser.page<page do chooser:onNextPage() end
    chooser:onMenuSelect(last);pump(function() return last.mandatory=='✓' end)
    while chooser.page>1 do chooser:onPrevPage() end
    chooser:onMenuSelect(chooser.item_table[1]);pump(function() return plugin.shelf_view and plugin.shelf_view~=source end)
    assert(#plugin.shelf_view.group_keys==2 and #plugin.shelf_view.books==21,'multi-group selection was not restored')
    selected=plugin.shelf_view;selected.on_select_groups({'__ungrouped__'})
    pump(function() return plugin.shelf_view and plugin.shelf_view~=selected end)
    local all_ids={};for _,book in ipairs(books) do
        if tostring(book.bookId):sub(1,7)~='MP_WXS_' then all_ids[#all_ids+1]=book.bookId end
    end
    selected=plugin.shelf_view;plugin:applyShelfSnapshot(books,{{archiveId='1',name='Synthetic',bookIds=all_ids}})
    plugin:showShelfView('books',nil,selected);assert(#plugin.shelf_view.books==0 and #plugin.shelf_view.group_keys==1,
        'empty remembered ungrouped selection unexpectedly showed all books')
    selected=plugin.shelf_view;plugin:applyShelfSnapshot(books,archives);plugin:showShelfView('books',nil,selected)
    selected=plugin.shelf_view;selected.on_select_groups({'archive:1','archive:21'})
    pump(function() return plugin.shelf_view and plugin.shelf_view~=selected end)
    assert(#plugin.shelf_view.group_keys==2 and #plugin.shelf_view.books==21)
end
if mode=='live' then file=assert(io.open(manifest_path,'wb'));assert(file:write(json.encode(manifest)));file:close() end
if mode=='live' then
    local ephemeral={books={{bookId='SYN-RESTART',title='合成未保存书籍',readUpdateTime=2000000000}},archives={}}
    assert(require('weread.lib.volatile_shelf').remember(plugin,ephemeral,{_shelf_source='native'}))
    plugin:showHome();assert(plugin.shelf_view.books[1].bookId=='SYN-RESTART')
end
assert(requests==0)
report.result,report.mode,report.http_requests,report.popup_cases,report.fresh_db_read='PASS',mode,requests,popup_cases,true
report.portal=portal;report.search_sparse_fields=true;report.sort_ties_stable=true;report.home_refresh_cases=home_refresh_cases
report.volatile_restart=true;report.saved_searches=saved_searches
io.write('\nWEREAD_GROUP_UI_RESULT='..json.encode(report)..'\n')
os.exit(0)
