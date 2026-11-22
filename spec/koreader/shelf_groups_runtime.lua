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
-- Legacy numeric table keys must not alias adjacent large string book IDs.
local account_key=plugin.library_db.accountKey
local shelf_read,archives_read=plugin.library_db.getShelf,plugin.library_db.getShelfArchives
local settings_read=plugin.settings.get
local recent_saved={
    [42]={recent_read_at=30,recent_read_account='synthetic-owner'},
    [9007199254740992]={recent_read_at=100,recent_read_account='synthetic-owner'},
}
local recent_shelf={{bookId='9007199254740993',title='大编号',readUpdateTime=1},
                    {bookId='43',title='另一本',readUpdateTime=2},{bookId='42',title='旧缓存',readUpdateTime=0}}
plugin.library_db.accountKey=function() return 'synthetic-owner' end
plugin.library_db.getShelf=function() return recent_shelf end
plugin.library_db.getShelfArchives=function() return {} end
plugin.settings.get=function(self,key,default)
    if key=='books' then return recent_saved end
    return settings_read(self,key,default)
end
plugin:showHome()
local recent_view=assert(plugin.shelf_view)
assert(#recent_view.books==3 and recent_view.books[1].bookId=='42' and recent_view.books[2].bookId=='43'
    and recent_view.books[3].bookId=='9007199254740993' and recent_view.books[3]._recent_time==1,
    'legacy numeric key attached a different large book to the home page')
recent_saved['9007199254740993']={recent_read_at=90,recent_read_account='synthetic-owner'}
plugin:showHome();recent_view=assert(plugin.shelf_view)
assert(recent_view.books[1].bookId=='9007199254740993' and recent_view.books[1]._recent_time==90,
    'exact large string book key was not used on home')
plugin:closeWeReadUI()
plugin.library_db.accountKey=account_key;plugin.library_db.getShelf=shelf_read;plugin.library_db.getShelfArchives=archives_read
plugin.settings.get=settings_read
-- Persist an offline reading event in the real per-account book store, then
-- verify the native shelf and a fresh process use it without leaking accounts.
local account_a,account_b=string.rep('a',20),string.rep('b',20)
local active_account=account_a
local state_scope=plugin.settings.account_state_scope
plugin.settings.account_state_scope=function() return active_account end
plugin.library_db.accountKey=function() return active_account end
if mode=='live' then
    plugin.settings:set('books',{['901001']={book_id='901001',title='合成本机阅读'},
        ['901002']={book_id='901002',title='合成第二本'}})
    plugin.settings:flush()
    assert(plugin:recordRecentReading('901001'))
    assert(plugin.settings:patch_reading_state('901001',{home_recent_at=os.time()-100}))
end
local recent_options=plugin.settings:get('shelf')
local old_sort,old_view=recent_options.sort_order,recent_options.view_mode
recent_options.sort_order='time_desc';recent_options.view_mode='list'
plugin.settings:set('shelf',recent_options)
local local_shelf={{bookId='901001',title='合成本机阅读',readUpdateTime=10},
    {bookId='901002',title='合成第二本',readUpdateTime=20},
    {bookId='901003',title='合成云端阅读',readUpdateTime=30}}
plugin:applyShelfSnapshot(local_shelf,{})
plugin.shelf_multi_groups={};plugin.shelf_group_key=nil;plugin:showShelfView('books')
local local_view=assert(plugin.shelf_view)
local local_records=plugin.settings:get('books',{})
local expected_time=local_records[mode=='live' and '901001' or '901002'].home_recent_at
assert(local_view.books[1].bookId==(mode=='live' and '901001' or '901002')
    and local_view:itemStatus(local_view.books[1])==require('weread.lib.shelf_time').date(expected_time),
    'offline recent event did not sort or render on native shelf')
assert(local_shelf[1].readUpdateTime==10,'local event changed the cloud shelf snapshot')
UI:forceRePaint()
active_account=account_b;plugin:showShelfView('books')
assert(plugin.shelf_view.books[1].bookId=='901003','foreign account inherited local reading time')
active_account=account_a;plugin:showShelfView('books')
assert(plugin.shelf_view.books[1].bookId==(mode=='live' and '901001' or '901002'),
    'returning account lost local reading time')
if mode=='live' then
    local_view=plugin.shelf_view;local_view.on_page_changed(1);local_view=plugin.shelf_view
    local reopen=assert(local_view._prepare_detail_return())
    assert(plugin:recordRecentReading('901002'))
    reopen();assert(plugin.shelf_view.books[1].bookId=='901002','return from reading kept stale recent sorting')
end
plugin:closeWeReadUI()
recent_options.sort_order=old_sort;recent_options.view_mode=old_view;plugin.settings:set('shelf',recent_options)
plugin.settings.account_state_scope=state_scope;plugin.library_db.accountKey=account_key
-- Download indicators, filters and home selection use the same exact identity
-- check, including legacy numeric keys and changes after a page was drawn.
local downloaded_path=evidence..'/synthetic-identity.epub'
local downloaded_file=assert(io.open(downloaded_path,'wb'));assert(downloaded_file:write('fixture'));downloaded_file:close()
local cache_owner=string.rep('c',20)
local cached_records={[42]={book_id='42',cached_file=downloaded_path,recent_read_at=100,recent_read_account=cache_owner},
    ['43']={book_id='44',cached_file=downloaded_path},[9007199254740992]={cached_file=downloaded_path}}
local cache_shelf={{bookId='42',title='旧格式书籍',readUpdateTime=1},
    {bookId='43',title='错误归属',readUpdateTime=2},{bookId='9007199254740993',title='大编号',readUpdateTime=3}}
local old_filters=plugin.shelf_filters
plugin.library_db.accountKey=function() return cache_owner end
plugin.library_db.getShelf=function() return cache_shelf end;plugin.library_db.getShelfArchives=function() return {} end
plugin.settings.get=function(self,key,default) if key=='books' then return cached_records end return settings_read(self,key,default) end
plugin.shelf_filters={};plugin:applyShelfSnapshot(cache_shelf,{});plugin.shelf_multi_groups={};plugin:showShelfView('books')
local cache_view=assert(plugin.shelf_view);local states={}
for _,book in ipairs(cache_view.books) do states[book.bookId]=book._cached end
assert(states['42']==true and states['43']==false and states['9007199254740993']==false,
    'downloaded indicators used a foreign or rounded identity')
plugin.shelf_filters={download='downloaded'};plugin:showShelfView('books')
assert(#plugin.shelf_view.books==1 and plugin.shelf_view.books[1].bookId=='42','downloaded filter lost legacy cache')
plugin.shelf_filters={download='not_downloaded'};plugin:showShelfView('books')
assert(#plugin.shelf_view.books==2,'not-downloaded filter hid mismatched or rounded records')
plugin.shelf_filters={};plugin:showHome();local home_view=assert(plugin.shelf_view);local target
for _,book in ipairs(home_view.books) do if book.bookId=='42' then target=book end end
assert(target and target._cached,'legacy book not shown as downloaded on home')
local read,detail=plugin.startBookReading,plugin.showBookRecord;local opened,shown
plugin.startBookReading=function(_,book) opened=book end
plugin.showBookRecord=function(_,book) shown=book end
home_view.on_select(target,'books');assert(opened==cached_records[42],'home opened a different cached book')
opened=nil;cached_records[42].book_id='44';home_view.on_select(target,'books')
assert(not opened and shown==target,'home opened a record whose identity changed after drawing')
local show_info=plugin.showInfo;local notice
local set_settings=plugin.settings.set
plugin.showInfo=function(_,message) notice=message end
plugin.settings.set=function(self,key,value)
    assert(key~='books','conflicting cache was written while opening book details')
    return set_settings(self,key,value)
end
plugin.showBookRecord=detail;plugin:showBookRecord(target)
assert(notice and cached_records[42].book_id=='44','book details did not preserve conflicting cache')
plugin.showInfo=show_info;plugin.settings.set=set_settings;plugin.showBookRecord=function(_,book) shown=book end
cached_records[42].book_id='42';shown=nil;assert(os.remove(downloaded_path));home_view.on_select(target,'books')
assert(not opened and shown==target,'home opened a cache file removed after drawing')
plugin.startBookReading=read;plugin.showBookRecord=detail;plugin:closeWeReadUI()
plugin.settings.get=settings_read;plugin.library_db.accountKey=account_key
plugin.library_db.getShelf=shelf_read;plugin.library_db.getShelfArchives=archives_read;plugin.shelf_filters=old_filters
-- The same safe book identity rule protects prefetch and annotation lookup.
local cache_path=evidence..'/synthetic-prefetch.epub'
local cache_file=assert(io.open(cache_path,'wb'));assert(cache_file:write('synthetic'));cache_file:close()
local foreign={title='Other book',cached_chapters={['1']='/synthetic/original.epub'}}
local prefetch_books={[9007199254740992]=foreign}
local fake_settings={get=function() return prefetch_books end,set=function() end,flush=function() end}
local downloader=require('weread.lib.downloader'):new{settings=fake_settings,refresh_shelf=function() end}
local download={book={book_id='9007199254740993'},chapters={{chapterUid='2'}},prefetch=true,
    prefetch_book_id='9007199254740993',prefetch_chapter_uid='2'}
downloader._active_job=download
downloader:_applyPrefetchResult(download,{ok=true,value={path=cache_path,book_id='9007199254740993',chapter_uid='2'}})
assert(foreign.cached_chapters['2']==nil and prefetch_books['9007199254740993']~=foreign
    and prefetch_books['9007199254740993'].book_id=='9007199254740993','prefetch modified a different legacy book')
local Controller=require('weread.ui.annotation_sync_controller')
local annotation_path='/synthetic/document.epub'
foreign.annotation_documents={[annotation_path]={clean=true,chapters={}}}
local annotation_store={documentKey=function(value) return value end,get=function() return nil end,
    importLegacy=function() end,reconcileRanges=function() return {} end}
local annotation_host={ui={document={file=annotation_path,getToc=function() return {} end}},
    settings={get=function() return {[9007199254740992]=foreign} end},
    _annotationBinding=function() return {book_id='9007199254740993',automatic=true} end,
    _annotationStore=function() return annotation_store end,_xpointerOverlayPrototypeAvailable=function() return true end}
for key,value in pairs(Controller) do if annotation_host[key]==nil then annotation_host[key]=value end end
assert(not annotation_host:_usesUnifiedAnnotations(),'foreign annotation descriptor activated')
local annotation_context=assert(annotation_host:_prepareAnnotationContext(false))
assert(annotation_context.book==nil and annotation_context.descriptor==nil and #annotation_context.catalog==0,
    'foreign annotation data was associated with a different book')
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
local progress_fixture=assert(debug.getinfo(1,'S').source:match('^@(.*/)'))
assert(dofile(progress_fixture..'shelf_progress_sort_case.lua')(plugin,mode,pump,evidence))
if mode=='reopen' then
    assert(plugin.settings:get('shelf').sort_order=='author_desc','author sort did not survive a fresh process')
    reset();local remembered=assert(plugin.shelf_view)
    assert(#remembered.group_keys==2 and #remembered.books==21,'multi-group selection not restored in fresh offline process')
    remembered.on_select_group(nil);pump(function() return plugin.shelf_view~=remembered end)
    assert(#plugin.shelf_view.group_keys==0,'all-books selection failed to clear persisted groups')
end
-- A standard gateway may mix safe integer IDs with decimal strings. Exercise
-- both its current canonicalization and a pre-existing mixed SQLite snapshot.
local previous_multi=plugin.shelf_multi_groups
for _,case in ipairs({'gateway','legacy'}) do
    local account='synthetic-mixed-'..case
    local isolated_settings={data_dir=evidence,get=function(_,key,default)
        if key=='account' then return {user_vid=account} end
        if key=='shelf' then return {source='gateway'} end
        if key=='api_key' then return 'synthetic-key' end
        return default
    end}
    local database=require('weread.lib.library_db'):new(isolated_settings)
    if mode=='live' then
        local mixed={books={{bookId='100000000000000',title='Synthetic string'},
                            {bookId=100000000000001,title='Synthetic number'},
                            {bookId='9007199254740993',title='Synthetic other'}},
            archive={{archiveId=100000000000002,name='Synthetic mixed',
                bookIds={100000000000000,'100000000000001'}}}}
        if case=='gateway' then
            local client={settings=isolated_settings,json_decode=function() return {} end,
                get_gateway_shelf=function() return mixed,200,{} end}
            mixed=require('weread.lib.shelf_source').fetch(client)
            assert(mixed.books[2].bookId=='100000000000001' and mixed.archive[1].bookIds[1]=='100000000000000')
        else
            mixed.books[1].bookId='10000000000000'
            mixed.archive[1]={archiveId=77,name='Synthetic legacy',bookIds={10000000000000,'100000000000001'}}
        end
        assert(database:cacheShelf(mixed.books,mixed.archive),'mixed shelf snapshot was not saved')
        if case=='legacy' then
            -- Reproduce older precision-losing JSON while leaving the SQLite
            -- primary key intact, as it was in the old writer.
            local db=assert(database:open())
            local stmt=db:prepare('UPDATE books SET payload=? WHERE book_id=?')
            stmt:bind(json.encode({bookId=100000000000001,title='Synthetic number'}),'100000000000001'):step();stmt:close()
            stmt=db:prepare("UPDATE shelf_state SET payload=? WHERE name='archives'")
            stmt:bind(json.encode({{archiveId=77,name='Synthetic legacy',
                bookIds={10000000000000,'100000000000001',100000000000001}}})):step();stmt:close();db:close()
        end
    end
    local saved_books,saved_archives=assert(database:getShelf()),assert(database:getShelfArchives())
    plugin:closeWeReadUI();plugin:applyShelfSnapshot(saved_books,saved_archives)
    plugin.shelf_multi_groups={}
    plugin.shelf_group_key=case=='gateway' and 'archive:100000000000002' or 'archive:77';plugin:showShelfView('books')
    local view=assert(plugin.shelf_view)
    local identity=require('weread.lib.shelf_snapshot')
    local found={};for _,book in ipairs(view.books) do found[identity.id(book)]=true end
    assert(#view.books==2 and found[case=='gateway' and '100000000000000' or '10000000000000']
        and found['100000000000001'],
        'native group did not retain both exact mixed-format IDs: '..case..' '..tostring(#view.books))
    UI:forceRePaint()
    if case=='gateway' then
        plugin.shelf_group_key='__ungrouped__';plugin:showShelfView('books')
        assert(#plugin.shelf_view.books==1 and plugin.shelf_view.books[1].bookId=='9007199254740993',
            'mixed-format group changed the adjacent ungrouped book')
    else
        local tr=require('weread.lib.i18n').tr
        assert(view.group_membership_incomplete and view.group_label=='Synthetic legacy（信息不完整）',
            'incomplete group was not identified in the reading view')
        view:showSourceMenu('books');local picker=assert(view._shelf_popup)
        local warned,uncategorized=false,false
        for _,item in ipairs(picker.item_table) do
            if item.text==tr('Some group memberships are unknown. Refresh the bookshelf.') then
                warned=item.select_enabled==false
            end
            if item.text==tr('Uncategorized') then uncategorized=true end
        end
        assert(warned and not uncategorized,'uncertain membership was offered as ungrouped')
        require('weread.ui.shelf_popup').close(view)
        plugin.shelf_multi_groups={'__ungrouped__'};plugin.shelf_group_key=nil;plugin:showShelfView('books')
        assert(#plugin.shelf_view.books==3 and #plugin.shelf_view.group_keys==1
            and plugin.shelf_view.group_label==tr('Selected groups unavailable; showing all books'),
            'saved ungrouped selection hid books when membership was unknown')
        local multi_view=plugin.shelf_view;multi_view:showMultiGroupMenu()
        local multi_picker=assert(multi_view._shelf_popup);local multi_warning,unavailable=false,false
        for _,item in ipairs(multi_picker.item_table) do
            if item.text==tr('Some group memberships are unknown. Refresh the bookshelf.') then
                multi_warning=item.select_enabled==false
            elseif item.text==tr('Unavailable saved group') then unavailable=item.select_enabled~=false end
        end
        assert(multi_warning and unavailable,'multi-group menu did not explain the preserved unavailable selection')
        require('weread.ui.shelf_popup').close(multi_view)
        plugin.shelf_multi_groups={};plugin.shelf_group_key='__ungrouped__'
        plugin:applyShelfSnapshot(saved_books,saved_archives);plugin:showShelfView('books')
        assert(plugin.shelf_group_key==nil and #plugin.shelf_view.books==3,
            'single ungrouped selection narrowed an uncertain shelf')
        local refreshed={{archiveId='77',name='Synthetic legacy',bookIds={'10000000000000','100000000000001'}}}
        plugin:applyShelfSnapshot(saved_books,refreshed)
        assert(plugin.shelf_ungrouped_known,'a complete refresh did not restore ungrouped status')
        plugin.shelf_group_key='__ungrouped__';plugin:showShelfView('books')
        assert(#plugin.shelf_view.books==1 and plugin.shelf_view.books[1].bookId=='9007199254740993',
            'complete refresh did not restore the ungrouped view')
    end
end
plugin:closeWeReadUI();plugin.shelf_group_key=nil;plugin.shelf_multi_groups=previous_multi
local popup_cases=0
local fixtures=assert(debug.getinfo(1,'S').source:match('^@(.*/)'))
local portal=dofile(fixtures..'discovery_lifetime_case.lua')(plugin,evidence)
local saved_searches=dofile(fixtures..'saved_searches_case.lua')(plugin,mode,pump,evidence)
local recent_searches=dofile(fixtures..'recent_searches_case.lua')(plugin,mode,pump,evidence)
local home_refresh_cases=dofile(fixtures..'home_refresh_failure_case.lua')(plugin,pump)
local incomplete_shelf=dofile(fixtures..'shelf_incomplete_case.lua')(plugin)
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
search_dialog:setInputText(' 　\194\160 ');search_dialog.buttons[1][2].callback()
pump(function() return plugin.shelf_view and plugin.shelf_view~=search_view end)
assert(plugin.shelf_search_keyword==nil and #plugin.shelf_view.books==1 and plugin.shelf_view.books[1].bookId=='SYN-123456',
    'whitespace-only search did not restore the selected group')
-- Unicode case folding and compatibility characters work within the active
-- group using KOReader's own utf8proc implementation.
plugin:applyShelfSnapshot({
    {bookId='SYN-U1',title='Café des livres'},
    {bookId='SYN-U2',title='Die Straße',author='JOSÉ'},
    {bookId='SYN-U3',title='ＡＢＣ 全角'},
    {bookId='SYN-OUT',title='Café outside group'},
},{{archiveId=98,name='合成分组',bookIds={'SYN-U1','SYN-U2','SYN-U3'}},
   {archiveId=99,name='其他',bookIds={'SYN-OUT'}}})
plugin.shelf_group_key='archive:98';plugin:showShelfView('books')
for _,case in ipairs({{'CAFÉ','SYN-U1'},{'STRASSE','SYN-U2'},{'josé','SYN-U2'},{'　abc\194\160','SYN-U3'}}) do
    search_view=assert(plugin.shelf_view);search_view.on_search();search_dialog=assert(search_view._shelf_popup)
    search_dialog:setInputText(case[1]);search_dialog.buttons[1][2].callback()
    pump(function() return plugin.shelf_view and plugin.shelf_view~=search_view end)
    assert(#plugin.shelf_view.books==1 and plugin.shelf_view.books[1].bookId==case[2],
        'Unicode shelf search missed a grouped book or escaped the active group')
end
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
-- Title sorting uses the same Unicode normalization as shelf search and keeps
-- missing titles last without disturbing pinned books or equal-title order.
local titles={
    {bookId='SYN-TP',title='',isTop=1},
    {bookId='SYN-TB',title='beta'},
    {bookId='SYN-TA1',title=' Alpha '},
    {bookId='SYN-TA2',title='ＡＬＰＨＡ'},
    {bookId='SYN-TC',title='Charlie'},
    {bookId='SYN-TM',title=''},
}
plugin:applyShelfSnapshot(titles,{{archiveId=94,name='合成书名分组',bookIds={'SYN-TP','SYN-TB','SYN-TA1','SYN-TA2','SYN-TC','SYN-TM'}}})
plugin.shelf_group_key='archive:94';plugin:showShelfView('books');local title_view=assert(plugin.shelf_view)
title_view.on_sort();local title_dialog=assert(title_view._shelf_popup)
title_dialog.buttons[4][1].callback();pump(function() return plugin.shelf_view and plugin.shelf_view~=title_view end)
title_view=plugin.shelf_view
for index,id in ipairs({'SYN-TP','SYN-TA1','SYN-TA2','SYN-TB','SYN-TC','SYN-TM'}) do
    assert(title_view.books[index].bookId==id,'ascending normalized title order incorrect')
end
title_view.on_sort();title_dialog=assert(title_view._shelf_popup)
title_dialog.buttons[5][1].callback();pump(function() return plugin.shelf_view and plugin.shelf_view~=title_view end)
title_view=plugin.shelf_view
for index,id in ipairs({'SYN-TP','SYN-TC','SYN-TB','SYN-TA1','SYN-TA2','SYN-TM'}) do
    assert(title_view.books[index].bookId==id,'descending normalized title order incorrect')
end
assert(titles[2].bookId=='SYN-TB' and titles[3].bookId=='SYN-TA1','title sort changed source order')
UI:forceRePaint()
-- Author sorting uses Unicode folding, retains pin precedence and keeps
-- missing authors last. Exercise actual selector callbacks and group search.
local authors={
    {bookId='SYN-AP',title='置顶',isTop=1},
    {bookId='SYN-B',title='乙',author='Bob'},
    {bookId='SYN-A1',title='甲',author=' Alice '},
    {bookId='SYN-A2',title='丙',author='ＡＬＩＣＥ'},
    {bookId='SYN-C',title='丁',authors='Carol'},
    {bookId='SYN-M',title='未知作者'},
}
plugin:applyShelfSnapshot(authors,{{archiveId=95,name='合成作者分组',bookIds={'SYN-AP','SYN-B','SYN-A1','SYN-A2','SYN-C','SYN-M'}}})
plugin.shelf_group_key='archive:95';plugin:showShelfView('books');local author_view=assert(plugin.shelf_view)
author_view.on_sort();local author_dialog=assert(author_view._shelf_popup)
UI:forceRePaint();Device.screen:shot(evidence..'/author-sort.png')
author_dialog.buttons[6][1].callback();pump(function() return plugin.shelf_view and plugin.shelf_view~=author_view end)
author_view=plugin.shelf_view
for index,id in ipairs({'SYN-AP','SYN-A1','SYN-A2','SYN-B','SYN-C','SYN-M'}) do
    assert(author_view.books[index].bookId==id,'ascending author order incorrect')
end
author_view.on_sort();author_dialog=assert(author_view._shelf_popup)
author_dialog.buttons[7][1].callback();pump(function() return plugin.shelf_view and plugin.shelf_view~=author_view end)
author_view=plugin.shelf_view
for index,id in ipairs({'SYN-AP','SYN-C','SYN-B','SYN-A1','SYN-A2','SYN-M'}) do
    assert(author_view.books[index].bookId==id,'descending author order incorrect')
end
author_view.on_search();local author_search=assert(author_view._shelf_popup)
author_search:setInputText('CAROL');author_search.buttons[1][2].callback()
pump(function() return plugin.shelf_view and plugin.shelf_view~=author_view end)
assert(#plugin.shelf_view.books==1 and plugin.shelf_view.books[1].bookId=='SYN-C',
    'alternate author field escaped group search')
assert(authors[2].bookId=='SYN-B' and authors[3].bookId=='SYN-A1','author sort changed the source shelf')
UI:forceRePaint()
-- Old or malformed cached timestamps must not stop list rendering or promote
-- an out-of-range value to the top of the shelf.
local dated={
    {bookId='SYN-DATE-BAD',title='无效日期',readUpdateTime='bad'},
    {bookId='SYN-DATE-VALID',title='有效日期',readUpdateTime='1700000000'},
    {bookId='SYN-DATE-BOOL',title='错误类型',readUpdateTime=true},
    {bookId='SYN-DATE-LARGE',title='超大日期',readUpdateTime=253402300800},
}
assert(plugin.library_db:cacheShelf(dated,{}))
local dated_cached=assert(plugin.library_db:getShelf())
assert(#dated_cached==4 and dated_cached[2].readUpdateTime=='1700000000')
local time_options=plugin.settings:get('shelf');time_options.view_mode='list';time_options.sort_order='time_desc'
plugin.settings:set('shelf',time_options);plugin:applyShelfSnapshot(dated_cached,{})
plugin:showShelfView('books');local time_view=assert(plugin.shelf_view)
assert(time_view.books[1].bookId=='SYN-DATE-VALID')
assert(time_view:itemStatus(time_view.books[1])==os.date('%Y-%m-%d',1700000000))
for index=2,4 do assert(time_view:itemStatus(time_view.books[index])=='') end
UI:forceRePaint()
assert(plugin.library_db:cacheShelf(books,archives))
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
local all_picker=assert(all_view._shelf_popup)
assert(#all_picker.item_table==1+(all_view.on_manage_local_groups and 1 or 0),'empty group shelf offered an unavailable multi-group picker')
if all_view.on_manage_local_groups then
    assert(all_picker.item_table[2].text==require('weread.lib.i18n').tr('Manage local groups'))
end
UI:close(all_picker)
reset();local initial=plugin.shelf_view
local duplicate_archives={{archiveId=777,name='重复甲',bookIds={books[1].bookId}},
    {archiveId=777,name='重复乙',bookIds={books[2].bookId}}}
plugin:applyShelfSnapshot(books,duplicate_archives);plugin:showShelfView('books',nil,initial)
local duplicate_view=assert(plugin.shelf_view);duplicate_view:showSourceMenu('books')
local duplicate_menu=assert(duplicate_view._shelf_popup);local duplicate_row=assert(duplicate_menu.item_table[3])
assert(duplicate_row.text==require('ffi/util').template(require('weread.lib.i18n').tr('Unavailable: %1'),'重复甲'))
UI:forceRePaint();Device.screen:shot(evidence..'/duplicate-group-selector.png')
local old_info=plugin.showInfo;local warning
plugin.showInfo=function(_self,text) warning=text end
duplicate_menu:onMenuSelect(duplicate_row)
pump(function() return warning~=nil end)
assert(warning==require('weread.lib.i18n').tr('This group is unavailable. Refresh the bookshelf and try again.')
    and plugin.shelf_view==duplicate_view and not plugin.shelf_group_key and #duplicate_view.books==48,
    'ambiguous group was selected or did not report the problem')
plugin.showInfo=old_info
reset()
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
    selected=plugin.shelf_view;selected.on_select_group('__ungrouped__')
    pump(function() return plugin.shelf_view and plugin.shelf_view~=selected end)
    assert(#plugin.shelf_view.books>0 and plugin.shelf_group_key=='__ungrouped__')
    selected=plugin.shelf_view;plugin:applyShelfSnapshot(books,{{archiveId='1',name='Synthetic',bookIds=all_ids}})
    plugin:showShelfView('books',nil,selected)
    assert(#plugin.shelf_view.books==0 and plugin.shelf_group_key=='__ungrouped__',
        'single ungrouped selection unexpectedly showed all books')
    selected=plugin.shelf_view;plugin:applyShelfSnapshot(books,archives);plugin:showShelfView('books',nil,selected)
    assert(#plugin.shelf_view.books>0 and plugin.shelf_group_key=='__ungrouped__',
        'single ungrouped selection did not recover')
    local system_archives={{archiveId='1',name='归档',bookIds={books[1].bookId,books[2].bookId}},
                           {archiveId='2',name='Synthetic group',bookIds={books[2].bookId}}}
    selected=plugin.shelf_view;plugin:applyShelfSnapshot(books,system_archives);plugin:showShelfView('books',nil,selected)
    assert(plugin.shelf_group_key=='__ungrouped__' and #plugin.shelf_view.books==47,
        'system archive incorrectly assigned ungrouped books')
    for _,book in ipairs(plugin.shelf_view.books) do assert(book.bookId~=books[2].bookId,'user-group member in ungrouped') end
    source=plugin.shelf_view;source:showSourceMenu('books');picker=assert(source._shelf_popup)
    assert(picker.item_table[3].text=='归档');picker:onMenuSelect(picker.item_table[3])
    pump(function() return plugin.shelf_view and plugin.shelf_view~=source end)
    assert(plugin.shelf_group_key=='archive:1' and #plugin.shelf_view.books==2,'system archive is not selectable')
    source=plugin.shelf_view;source:showSourceMenu('books');picker=assert(source._shelf_popup)
    assert(picker.item_table[5].text==require('weread.lib.i18n').tr('Uncategorized'))
    picker:onMenuSelect(picker.item_table[5]);pump(function() return plugin.shelf_view and plugin.shelf_view~=source end)
    assert(plugin.shelf_group_key=='__ungrouped__' and #plugin.shelf_view.books==47,
        'native ungrouped selection lost system archive books')
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
    local saved=plugin.settings:get('shelf');saved.sort_order='author_desc'
    plugin.settings:set('shelf',saved);plugin.settings:flush()
end
if mode=='reopen' then
    local saved=plugin.settings:get('shelf');saved.sort_order='progress_desc'
    plugin.settings:set('shelf',saved);plugin.settings:flush()
end
assert(requests==0)
report.result,report.mode,report.http_requests,report.popup_cases,report.fresh_db_read='PASS',mode,requests,popup_cases,true
report.portal=portal;report.search_sparse_fields=true;report.sort_ties_stable=true;report.author_sort=true;report.title_sort=true;report.recent_identity=true;report.prefetch_identity=true;report.annotation_identity=true;report.shelf_dates=true;report.home_refresh_cases=home_refresh_cases
report.volatile_restart=true;report.saved_searches=saved_searches;report.recent_searches=recent_searches;report.incomplete_shelf=incomplete_shelf
report.mixed_group_identities=true
report.uncertain_group_membership=true
report.download_identity=true
report.progress_sort=true
io.write('\nWEREAD_GROUP_UI_RESULT='..json.encode(report)..'\n')
os.exit(0)
