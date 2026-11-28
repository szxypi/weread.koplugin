-- Normal plugin selection with multiple real cached chapter files and a full
-- download. All traffic uses the isolated synthetic HTTP server.
require('setupkoenv')
local home,evidence=assert(os.getenv('KO_HOME')),assert(os.getenv('WEREAD_EVIDENCE'))
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
G_reader_settings:saveSetting('language','zh_CN');G_reader_settings:saveSetting('color_rendering',false)
require('gettext').changeLang('zh_CN')
package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
local Device=require('device');require('document/canvascontext'):init(Device)
assert(require('weread.lib.mock_environment').save{enabled=true,host='127.0.0.1',port=tonumber(os.getenv('WEREAD_MOCK_PORT'))})
local settings=require('weread.lib.settings'):new();assert(settings.mock_endpoint)
local cb_resume=os.getenv('WEREAD_TEST_CB_RESUME')=='1'
local cb_edit=os.getenv('WEREAD_TEST_CB_HIGHLIGHT_EDIT')=='1'
local sync=settings:get('sync');sync.pull_on_open=false;sync.upload_on_close=false;sync.upload_interval_minutes=0;settings:set('sync',sync)
local cache=settings:get('cache');cache.auto_prefetch_next_chapter=false;cache.download_book_images=false;cache.download_underlines_and_thoughts=false;settings:set('cache',cache)
local config=settings:get('read_report');config.enabled=false;settings:set('read_report',config);settings:flush()
local offline=os.getenv('WEREAD_READING_REOPEN')=='1'
local Common=require('weread.ui.common')
Common.isNetworkOnline=function() return not offline end;Common.isNetworkConnected=Common.isNetworkOnline
local Client=require('weread.lib.client');local request=Client.request
function Client:request(options) assert(not offline,'offline HTTP attempted');return request(self,options) end
local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
for _i,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
assert(#Loader.enabled_plugins==1)
package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
local UI=require('ui/uimanager');UI:setRunForeverMode();UI:setInputTimeout(0)
local socket,json=require('socket'),require('json')
local FM,Reader=require('apps/filemanager/filemanager'),require('apps/reader/readerui')
local Source,Dom=require('weread.lib.position_source'),require('weread.lib.source_dom')
local tr=require('weread.lib.plugin_util').tr
local id=cb_resume and 'CB_SyntheticResume' or (os.getenv('WEREAD_TEST_LARGE_BOOK_ID')=='1' and '9007199254740993' or '900001')
local format=os.getenv('WEREAD_TEST_CONTENT_FORMAT')=='txt' and 'web_txt' or 'web_xhtml'
local accept_read_prompt=true
local function tick()
    UI:setInputTimeout(0);UI:handleInput()
    local dialog=UI:getTopmostVisibleWidget()
    if dialog and dialog.ok_callback and (dialog.ok_text==tr('Download') or accept_read_prompt and dialog.ok_text==tr('Read now')) then
        UI:close(dialog);dialog.ok_callback()
    end
end
local function pump(predicate)
    local deadline=socket.gettime()+65
    while not predicate() do assert(socket.gettime()<deadline,'cached resume deadline');tick();socket.sleep(.01) end
end
local function clean(reader)
    while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=reader do UI:close(UI:getTopmostVisibleWidget()) end
end
local function shot(name) UI:forceRePaint();Device.screen:shot(evidence..'/'..name..'.png') end
local function close_reader()
    local reader=assert(Reader.instance)
    pump(function() return reader.weread.progress_sync.current_book_id==id end)
    clean(reader)
    reader.weread:onFlushSettings();reader:onClose(false)
    assert(not Reader.instance)
    if not FM.instance then FM:showFiles(home) end
end
local function press(view,label)
    for _i,buttons in ipairs({view._action_buttons or {},view._footer_actions or {}}) do
        for _j,button in ipairs(buttons) do if button.text==tr(label) then assert(button.enabled~=false);button.callback();return end end
    end
    error('missing cached reading action',0)
end
local function fallback_warning(accept)
    local dialog=assert(UI:getTopmostVisibleWidget())
    assert(dialog.ok_text==tr('Read cached copy') and dialog.ok_callback and dialog.cancel_callback)
    if not accept then UI:forceRePaint();Device.screen:shot(evidence..'/resume-warning.png') end
    if accept then dialog.ok_callback() else dialog.cancel_callback() end
    tick()
end
local function book(host) return assert(host.settings:get_book(id)) end
local function patch(host,values)
    local books=host.settings:get('books',{});local latest=book(host)
    for key,value in pairs(values) do if value==false then latest[key]=nil else latest[key]=value end end
    books[id]=latest;host.settings:set('books',books);host.settings:flush()
end
local function detail()
    if not FM.instance then FM:showFiles(home) end
    local host=assert(FM.instance.weread)
    host:closeWeReadUI();host:showBookshelf()
    local view=assert(host.shelf_view);local selected
    if cb_resume then
        for index,row in ipairs(view.books) do
            if tostring(row.bookId or row.book_id)==id then
                local page=math.floor((index-1)/view.page_size)+1
                if view.page~=page then host:showShelfView('books',nil,nil,{page=page});view=assert(host.shelf_view) end
                break
            end
        end
    end
    for _i,row in ipairs(view:getVisibleBooks()) do if tostring(row.bookId or row.book_id)==id then selected=row end end
    assert(selected);UI:forceRePaint();view.on_select(selected,'books')
    pump(function() return host._book_detail_view and not host.book_metadata_context end)
    return host,host._book_detail_view
end
local function read_from_shelf(expected,before_read)
    local selected_host,detail_view=detail()
    if before_read then before_read(selected_host) end
    press(detail_view,'▤ Read')
    pump(function() return Reader.instance and Reader.instance.document and (not expected or Reader.instance.document.file==expected) end)
    return Reader.instance,Reader.instance.weread
end
local function ready(reader)
    pump(function() return reader.weread.source_position:current()~=nil end)
    return assert(reader.weread.source_position:current())
end
local function filter_chapters(current, view, query)
    local button=assert(view._toolbar_buttons[3])
    assert(button.text==tr('Find chapter'))
    UI:forceRePaint()
    button:onTapSelectButton()
    local dialog=assert(view._shelf_popup)
    dialog:setInputText(query)
    dialog.buttons[1][2].callback()
    local filtered=assert(current._chapter_list_view)
    assert(filtered~=view and not view._shelf_popup)
    UI:forceRePaint()
    return filtered
end
local function check_full_chapter_status(current)
    local chapters=assert(current:ensureChaptersLoaded(book(current)))
    local manifest={}
    for _,chapter in ipairs(chapters) do manifest[#manifest+1]={chapter_uid=tostring(chapter.chapterUid or chapter.chapterId)} end
    assert(#manifest>1,'full-book catalog was empty')
    assert(dofile(debug.getinfo(1,'S').source:match('^@(.*/)')..'owner_full_cache_status_case.lua')(
        {book_id=id,full_manifest=manifest},current,current.ui,pump))
end
local function check_saved_chapter_picker(reader, with_standalone)
    local full,current=reader.document.file,reader.weread
    local function picker()
        clean(reader)
        local detail_view=assert(current:showBookMenu(book(current)))
        press(detail_view,'Downloaded chapters')
        local menu=assert(UI:getTopmostVisibleWidget())
        assert(menu.title==tr('Downloaded chapters'))
        return menu
    end
    local function turn_past_end(action)
        clean(reader)
        local previous=G_reader_settings:readSetting('end_document_action')
        G_reader_settings:saveSetting('end_document_action',action)
        reader.rolling:onGotoPage(reader.document:getPageCount())
        reader.rolling:onGotoViewRel(1)
        if previous then G_reader_settings:saveSetting('end_document_action',previous)
        else G_reader_settings:delSetting('end_document_action') end
    end
    local menu,standalone_next
    if with_standalone then
        local saved=book(current)
        local single=assert(saved.cached_chapters['2'])
        standalone_next=assert(saved.cached_chapters['4'])
        patch(current,{cached_full_book=false,cached_file=false,cached_chapters={['2']=single,['4']=single..'.missing'}})
        menu=picker()
        assert(#menu.item_table==1 and menu.item_table[1].text=='合成重复章节','offline picker included a missing chapter')
        menu:onMenuSelect(menu.item_table[1])
        pump(function() return Reader.instance and Reader.instance.document.file==single end)
        reader=assert(Reader.instance);current=assert(reader.weread)
        assert(Source.read_document(reader.document,id,2),'saved chapter opened a different EPUB')
        -- A stale mapping has valid EPUB bytes for another chapter.
        patch(current,{cached_chapters={['2']=single,['3']=standalone_next}})
        clean(reader);assert(current:onShowWeReadQuickMenu())
        local quick=assert(UI:getTopmostVisibleWidget());UI:forceRePaint()
        assert(quick:getButtonById('reader_progress')):onTapSelectButton()
        pump(function() return current._weread_reader_progress~=nil end)
        local progress=current._weread_reader_progress.dialog;UI:forceRePaint()
        local next_button=assert(progress:getButtonById('progress_next_chapter'))
        assert(next_button.enabled~=false);next_button:onTapSelectButton()
        pump(function() return current._saved_chapter_menu~=nil end)
        menu=assert(current._saved_chapter_menu)
        assert(Reader.instance==reader and menu.subtitle==tr('Chapter unavailable offline')
            and #menu.item_table==1 and menu.item_table[1].chapter_id=='2',
            'progress panel offered or opened a stale chapter copy')
        clean(reader)
        patch(current,{cached_chapters={['2']=single,['4']=single..'.missing'}})
    end
    assert(current.library_db:putChapters(id,{}))
    local catalog_path=assert(require('weread.lib.content').catalog_cache_path(current.settings,book(current)))
    assert(os.remove(catalog_path))
    if with_standalone then
        menu=picker()
        pump(function() return menu.item_table[1].text=='合成重复章节' end)
        assert(#menu.item_table==1 and menu.item_table[1].chapter_id=='2',
            'catalog-free single EPUB did not restore its own title')
        patch(current,{cached_chapters={['2']=reader.document.file,['4']=standalone_next}})
        turn_past_end('next_file')
        menu=assert(current._saved_chapter_menu,'automatic advance did not show the offline chapter picker')
        assert(Reader.instance==reader and UI:getTopmostVisibleWidget()==menu and #menu.item_table==2,
            'automatic advance left the current reader or missed the other saved chapter')
        local chosen=menu.item_table[2]
        assert(chosen.chapter_id=='4')
        menu:onMenuSelect(chosen)
        pump(function() return Reader.instance and Reader.instance.document.file==standalone_next end)
        reader=assert(Reader.instance);current=assert(reader.weread)
        assert(Source.read_document(reader.document,id,4),'automatic fallback opened the wrong standalone source')
    end
    patch(current,{cached_full_book=full,cached_file=full,cached_chapters={}})
    local previous_size=G_reader_settings:readSetting('items_per_page')
    G_reader_settings:saveSetting('items_per_page',3)
    if with_standalone then
        menu=picker()
    else
        turn_past_end('pop-up')
        local quick=assert(UI:getTopmostVisibleWidget())
        local downloaded=assert(quick:getButtonById('chapter_list'))
        assert(downloaded.text==tr('Downloaded chapters') and downloaded.enabled~=false)
        assert(quick:getButtonById('next_chapter').enabled==false)
        UI:forceRePaint()
        downloaded:onTapSelectButton()
        pump(function() return current._saved_chapter_menu~=nil end)
        menu=assert(current._saved_chapter_menu)
    end
    pump(function() return menu.item_table[4].text=='4. 合成重复章节' end)
    assert(#menu.item_table==6 and menu.item_table[2].text=='2. 合成重复章节',
        'the combined file did not supply ordered titles without the catalog')
    local last=menu:getPageNumber(5)
    assert(last>1)
    menu:onGotoPage(last)
    for y,row in ipairs(menu.layout) do
        if row[1] and row[1].entry and row[1].entry.chapter_id=='5' then
            menu:moveFocusTo(1,y,require('ui/widget/focusmanager').FORCED_FOCUS)
            break
        end
    end
    assert(menu:getFocusItem().entry.chapter_id=='5')
    local function query(value)
        UI:forceRePaint()
        assert(menu.title_bar.left_button).callback()
        local search=assert(menu._shelf_popup)
        search:setInputText(value);search.buttons[1][2].callback()
    end
    query('合成重复章节')
    assert(#menu.item_table==2 and menu.item_table[1].chapter_id=='2' and menu.item_table[2].chapter_id=='4')
    UI:forceRePaint()
    assert(menu.title_bar.left_button).callback()
    assert(menu._shelf_popup).buttons[1][1].callback()
    assert(menu.page==last and menu:getFocusItem().entry.chapter_id=='5',
        'clearing downloaded search lost the original page or focus')
    query('４')
    assert(#menu.item_table==1 and menu.item_table[1].chapter_id=='4','chapter ID no longer matches after title recovery')
    if previous_size then G_reader_settings:saveSetting('items_per_page',previous_size)
    else G_reader_settings:delSetting('items_per_page') end
    shot('downloaded-chapter-picker')
    local original_reader=reader
    menu:onMenuSelect(menu.item_table[1])
    pump(function() return Reader.instance and Reader.instance.document.file==full end)
    reader=assert(Reader.instance)
    local target=assert(Dom.chapter_start(reader.document,id,'4'))
    pump(function() return reader.document:isXPointerInCurrentPage(target) end)
    assert(with_standalone or reader==original_reader,'same-file chapter choice reopened the reader')
    assert(reader.weread.progress_sync.file_resume and reader.weread.progress_sync.file_resume.preserve_only,
        'unindexed whole-book position must not replace pending progress')
    print(with_standalone and 'PASS: downloaded chapter picker, offline single and catalog-free combined'
        or 'PASS: downloaded chapter picker, catalog-free combined after cache cleanup')
end
local function check_cb_notes(reader,current,seed)
    local Cache=require('weread.lib.my_cloud_marks_store')
    if seed then
        assert(Cache:new(current.library_db,current.client):write{schema=1,book_id=id,fetched_at=1000,
            updated={{bookmarkId='synthetic-highlight',type=1,chapterUid=2,markText='合成导入书划线',range='10-18'},
                {bookmarkId='synthetic-bookmark',type=0,chapterUid=2,range='25'}},chapters={{chapterUid=2,title='合成章节'}}})
        assert(Cache:new(current.library_db,current.client,'thoughts'):write{schema=1,book_id=id,fetched_at=1000,
            reviews={{reviewId='synthetic-thought',content='合成导入书想法',abstract='合成引用',isPrivate=1,type=1,chapterUid=2,range='10-18'}}})
    end
    local entries={}
    for _i,item in ipairs(current:getMainMenuItems()) do if item.text then entries[item.text]=item end end
    assert(entries[tr('Save cloud bookmark')], 'imported book bookmark entry is missing')
    for _i,case in ipairs({{'My cloud highlights','synthetic-highlight'},
        {'My cloud bookmarks','synthetic-bookmark'},{'My cloud thoughts','synthetic-thought'}}) do
        local item=assert(entries[tr(case[1])]);item.callback()
        local done_by=socket.gettime()+10
        while current._my_marks_loading_source do
            assert(socket.gettime()<done_by,'saved notes did not open');tick()
        end
        local owner=assert(current._my_marks_owner);assert(owner.value and not owner.writable and not owner.context)
        local selected
        for _j,row in ipairs(owner.menu.item_table) do if row.my_note_id==case[2] then selected=row end end
        assert(selected);selected.callback()
        local popup=assert(owner.menu._shelf_popup)
        local buttons=popup.button_table
        if case[2]=='synthetic-bookmark' then
            assert(buttons and buttons:getButtonById('delete_bookmark') and not buttons:getButtonById('open_bookmark'),
                'imported bookmark missing deletion or exposed navigation without a preview')
        else
            assert(buttons and buttons:getButtonById(case[2]=='synthetic-highlight' and 'open_highlight' or 'open_thought_quote'),
                'imported book did not expose source-verified navigation')
        end
        if buttons then
            if case[2]=='synthetic-highlight' then assert(buttons:getButtonById('delete_highlight'),
                'imported highlight deletion missing') end
            for _j,name in ipairs({'change_highlight_style','change_highlight_color'}) do
                assert(not buttons:getButtonById(name),'imported book exposed editing')
            end
        end
        current:cancelMyCloudMarks();clean(reader)
    end
end
FM:showFiles(home)
local host=assert(FM.instance.weread)
if offline then
    local file=assert(io.open(evidence..'/cached-resume-checkpoint.json','rb'));local expected=json.decode(file:read('*a'));file:close()
    local reader=read_from_shelf(expected.file)
    assert(reader.document:isXPointerInCurrentPage(expected.xpointer) and reader:getCurrentPage()==expected.page)
    local position=ready(reader);assert(position.chapter_uid==expected.chapter_uid and position.basis==Source.coordinate_basis(format))
    local current=reader.weread
    if os.getenv('WEREAD_TEST_DUPLICATE_CHAPTER_TITLES')=='1' then
        local candidate=book(current)
        assert(candidate.cached_full_book==reader.document.file)
        local preferences=current.settings:get('cache')
        local ensure, get_book=current.ensureChaptersLoaded,current.settings.get_book
        local old_prefetch=preferences.auto_prefetch_next_chapter
        preferences.auto_prefetch_next_chapter=true
        current.settings:set('cache',preferences)
        current.ensureChaptersLoaded=function() error('combined EPUB read a catalog for prefetch') end
        assert(not current:maybePrefetchNextChapter(id))
        current.settings.get_book=function(self,book_id,...)
            local result=get_book(self,book_id,...)
            if book_id==id then result.cached_chapters={['2']=expected.file,['4']=expected.file} end
            return result
        end
        assert(not current:maybePrefetchNextChapter(id),'shared combined copy queued a prefetch')
        current.ensureChaptersLoaded,current.settings.get_book=ensure,get_book
        preferences.auto_prefetch_next_chapter=old_prefetch
        current.settings:set('cache',preferences)
    end
    current:showChapterList(book(current))
    local view=assert(current._chapter_list_view)
    local title=assert(view._chapter_rows[1]).text
    view=filter_chapters(current,view,title)
    assert(#view._chapter_rows>=1 and view.chapters[1].source.title==title)
    local empty=filter_chapters(current,view,'unmatched synthetic chapter')
    assert(#empty._chapter_rows==0 and empty.empty_text==tr('No matching chapters.'))
    shot('chapter-filter-empty')
    empty:onClose();pump(function() return current._chapter_list_view==nil end)
    if os.getenv('WEREAD_TEST_DUPLICATE_CHAPTER_TITLES')=='1' then check_full_chapter_status(reader.weread) end
    if os.getenv('WEREAD_TEST_READER_TYPOGRAPHY')=='1' then
        dofile(debug.getinfo(1,'S').source:match('^@(.*/)')..'reader_typography_smoke.lua')(
            reader,reader.weread,pump,shot,clean,true,evidence)
    end
    if os.getenv('WEREAD_TEST_READER_MARGINS')=='1' then
        dofile(debug.getinfo(1,'S').source:match('^@(.*/)')..'reader_margins_smoke.lua')(
            reader,reader.weread,pump,shot,clean,true,evidence)
    end
    if cb_edit then dofile('/source/spec/koreader/cb_highlight_edit_smoke.lua')(reader,reader.weread,pump,clean,true)
    elseif cb_resume then check_cb_notes(reader,reader.weread,false) end
    UI:forceRePaint();Device.screen:shot(evidence..'/cached-resume-offline.png')
    if os.getenv('WEREAD_TEST_DUPLICATE_CHAPTER_TITLES')=='1' then
        -- The cleanup scenario downloads only a new full copy before restarting.
        check_saved_chapter_picker(reader, os.getenv('WEREAD_TEST_CACHE_CLEANUP')~='1')
    end
    close_reader()
    print('PASS: fresh offline plugin selection -> full cached EPUB -> saved page and chapter; zero HTTP')
    os.exit(0)
end
local loaded=false;host:refreshBookshelf(nil,{on_loaded=function(ok) loaded=ok end})
pump(function() return not host.shelf_refreshing end);assert(loaded)
local reader,current=read_from_shelf()
if cb_edit then
    dofile('/source/spec/koreader/cb_highlight_edit_smoke.lua')(reader,current,pump,clean,false)
    local position=ready(reader)
    local file=assert(io.open(evidence..'/cached-resume-checkpoint.json','wb'))
    file:write(json.encode{file=reader.document.file,page=reader:getCurrentPage(),xpointer=reader.document:getXPointer(),chapter_uid=position.chapter_uid});file:close()
    close_reader();print('PASS: imported highlight editing and offline checkpoint');os.exit(0)
end
if cb_resume then check_cb_notes(reader,current,true) end
local first=book(current).cached_chapters['2'];assert(first==reader.document.file)
if os.getenv('WEREAD_TEST_DUPLICATE_CHAPTER_TITLES')=='1' then
    assert(Source.read_document(reader.document,id,2),'first duplicate-title chapter has wrong source')
    reader,current=dofile(debug.getinfo(1,'S').source:match('^@(.*/)')..'chapter_cache_identity_smoke.lua')(
        reader,current,book(current),id,pump,clean,function(value) offline=value end)
    assert(reader.document.file==first,'combined navigation test did not restore the original reader')
end
local typography=os.getenv('WEREAD_TEST_READER_TYPOGRAPHY')=='1'
local margins=os.getenv('WEREAD_TEST_READER_MARGINS')=='1'
if typography then
    dofile(debug.getinfo(1,'S').source:match('^@(.*/)')..'reader_typography_smoke.lua')(
        reader,current,pump,shot,clean,false,evidence)
end
if margins then
    dofile(debug.getinfo(1,'S').source:match('^@(.*/)')..'reader_margins_smoke.lua')(
        reader,current,pump,shot,clean,false,evidence)
end
if os.getenv('WEREAD_TEST_READER_PROGRESS')=='1' or typography or margins then
    local function inspect_previous(previous,previous_host)
        if typography then
            dofile(debug.getinfo(1,'S').source:match('^@(.*/)')..'reader_typography_smoke.lua')(
                previous,previous_host,pump,shot,clean,true,evidence)
        end
        if margins then
            dofile(debug.getinfo(1,'S').source:match('^@(.*/)')..'reader_margins_smoke.lua')(
                previous,previous_host,pump,shot,clean,true,evidence)
        end
    end
    local function set_offline(value) offline=value end
    reader,current=dofile(debug.getinfo(1,'S').source:match('^@(.*/)')..'reader_progress_chapter_smoke.lua')(
        reader,current,pump,clean,id,inspect_previous,os.getenv('WEREAD_TEST_READER_PROGRESS')=='1' and set_offline)
    assert(reader.document.file==first)
end
if os.getenv('WEREAD_TEST_PREFETCH_CONDITION') then
    local fixtures=assert(debug.getinfo(1,'S').source:match('^@(.*/)'))
    local _,updated=dofile(fixtures..'prefetch_condition_case.lua')(reader,current,book(current),id,evidence)
    current=updated
end
local manual_kind=os.getenv('WEREAD_TEST_MANUAL_AUTH_RECOVERY')
local manual_case
if manual_kind then
    local fixtures=assert(debug.getinfo(1,'S').source:match('^@(.*/)'))
    manual_case=dofile(fixtures..'manual_auth_recovery_case.lua')(current,manual_kind,pump,tick)
    if manual_kind=='selected' then
        manual_case.selected(book(current),first)
        current=Reader.instance.weread
    end
end
current:showChapterList(book(current))
pump(function() return current._chapter_list_view~=nil end)
local view=assert(current._chapter_list_view);assert(view._chapter_rows[4])
if manual_case and manual_kind~='selected' then manual_case.arm_single(view) end
if manual_case then
    view._chapter_rows[4].callback()
else
    local title=view._chapter_rows[4].text
    local duplicates=os.getenv('WEREAD_TEST_DUPLICATE_CHAPTER_TITLES')=='1'
    if duplicates then
        view:moveFocusTo(1,4,require('ui/widget/focusmanager').FORCED_FOCUS)
        view=filter_chapters(current,view,title)
        view=filter_chapters(current,view,'')
        assert(view:getFocusItem()==view._chapter_rows[3] and view._chapter_rows[3].frame.invert,
            'clearing the chapter filter lost the original focus')
    end
    view=filter_chapters(current,view,'　'..title..'　')
    local index=duplicates and 2 or 1
    assert(#view._chapter_rows==index and view._chapter_rows[index].text==(duplicates and '4. '..title or title))
    if duplicates then assert(view._chapter_rows[1].text=='2. '..title) end
    shot('chapter-filter-result')
    if duplicates then accept_read_prompt=false end
    view._chapter_rows[index]:onTapChapterRow()
    if duplicates then
        pump(function()
            local dialog=UI:getTopmostVisibleWidget()
            return dialog and dialog.ok_text==tr('Read now') and view._chapter_rows[index].status==tr('Cached')
        end)
        assert(current._chapter_list_view==view and view.subtitle and view._chapter_rows[1].text=='2. '..title,
            'downloading from a filtered list reset the catalog')
        accept_read_prompt=true
    end
end
if manual_case and manual_kind=='single-repeat' then manual_case.recover_single(view) end
pump(function()
    local active=Reader.instance
    return active and active.document and active.document.file~=first and active.weread.settings:get_book(id).cached_chapters['4']==active.document.file
end)
reader,current=Reader.instance,Reader.instance.weread
if manual_case and manual_kind~='selected' then manual_case.check_single() end
local second=reader.document.file
if os.getenv('WEREAD_TEST_DUPLICATE_CHAPTER_TITLES')=='1' then
    assert(first~=second and Source.read_document(reader.document,id,4),'duplicate-title chapters shared a file or source')
end
local second_checkpoint={page=reader:getCurrentPage(),xpointer=reader.document:getXPointer()}
current:showChapterList(book(current));view=assert(current._chapter_list_view);view._chapter_rows[2].callback()
pump(function() return Reader.instance and Reader.instance.document.file==first end)
reader,current=Reader.instance,Reader.instance.weread
pump(function() return current.progress_sync.current_book_id==id end)
reader.rolling:onGotoPage(math.min(3,reader.document:getPageCount()));tick();ready(reader)
local expected={page=reader:getCurrentPage(),xpointer=reader.document:getXPointer()}
close_reader();host=assert(FM.instance.weread)
local saved=book(host);assert(tostring(saved.pending_upload_position.chapter_uid)=='2')
local local_pending=json.decode(json.encode(saved.pending_upload_position))
local last_local=json.decode(json.encode(saved.last_local_position))
local catalog=assert(host.library_db:getChapters(id))
local report={result='PASS',synthetic_only=true,content_format=format,chapter_files=2,full_chapters=6,
    pending_priority=false,last_local_priority=false,foreign_owner_ignored=false,native_position_restored=false,
    missing_catalog_uid=false,ambiguous_index_uses_last_local=false,
    explicit_cached_copy=false,missing_resume_chapter_downloaded=false,
    offline_missing_target_fallback=false,home_missing_target_downloaded=false,fallback_warning_cancel_preserved=false,
    full_download=false,full_source_records=false,full_native_navigation=false}
if cb_resume then report.cb_reading=true end
for _i,mode in ipairs({'pending','last_local','foreign_owner','no_catalog','duplicate_index'}) do
    host=assert(FM.instance.weread)
    local values={chapter_uid=4,chapter_idx=4,progress=70,pending_upload_position=local_pending,
        last_local_position=last_local,recent_read_account=saved.pending_upload_account,
        pending_upload_account=mode=='foreign_owner' and 'other-synthetic-owner' or saved.pending_upload_account}
    if mode=='last_local' then values.pending_upload_position=false end
    if mode=='foreign_owner' then
        values.pending_upload_position={book_id=id,chapter_uid=4,chapter_idx=4,percent=70}
    end
    if mode=='no_catalog' then
        values.chapters={};values.chapter_uid=2;values.chapter_idx=2
        values.pending_upload_position={book_id=id,chapter_uid=4,percent=70}
    end
    if mode=='duplicate_index' then
        values.chapters=false
        values.pending_upload_position={book_id=id,chapter_idx=0,percent=70}
    end
    patch(host,values)
    if mode=='no_catalog' then
        assert(host.library_db:putChapters(id,{}))
        local path=require('weread.lib.content').catalog_cache_path(host.settings,book(host))
        assert(path:sub(1,#home)==home);os.remove(path)
    end
    if mode=='last_local' then assert(not book(host).pending_upload_position) end
    reader,current=read_from_shelf(mode=='no_catalog' and second or first,function(selected_host)
        local snapshot=book(selected_host)
        if mode=='no_catalog' then assert(snapshot.chapters==nil and not selected_host.library_db:getChapters(id)) end
        if mode=='foreign_owner' then
            assert(snapshot.pending_upload_position and snapshot.pending_upload_position.chapter_uid==4
                and snapshot.pending_upload_account=='other-synthetic-owner')
        end
        if mode=='duplicate_index' then
            local duplicate=json.decode(json.encode(catalog))
            duplicate[2].chapterIdx=0;duplicate[4].chapterIdx=0
            assert(selected_host.library_db:putChapters(id,duplicate))
        end
    end)
    local checkpoint=mode=='no_catalog' and second_checkpoint or expected
    assert(reader:getCurrentPage()==checkpoint.page and reader.document:isXPointerInCurrentPage(checkpoint.xpointer))
    assert(book(current).cached_chapters['4']==second)
    report[mode=='pending' and 'pending_priority' or mode=='last_local' and 'last_local_priority'
        or mode=='no_catalog' and 'missing_catalog_uid' or mode=='duplicate_index' and 'ambiguous_index_uses_last_local'
        or 'foreign_owner_ignored']=true
    report.native_position_restored=true
    UI:forceRePaint()
    if mode=='pending' then Device.screen:shot(evidence..'/cached-resume-pending.png') end
    close_reader()
end
host=assert(FM.instance.weread);assert(host.library_db:putChapters(id,catalog))
if os.getenv('WEREAD_TEST_NUMERIC_CACHE_KEYS')=='1' then
    patch(host,{chapters=catalog,chapter_uid=2,chapter_idx=2,
        pending_upload_position={book_id=id,chapter_uid=4,chapter_idx=4,percent=70},
        pending_upload_account=saved.pending_upload_account,last_local_position=last_local,
        recent_read_account=saved.pending_upload_account,cached_chapters={['2']=first,['4']=second}})
    host,view=detail()
    -- Persisted JSON normalizes object keys to strings. Inject the legacy
    -- in-memory representation at the host boundary after loading the view.
    local original_get_book=host.settings.get_book
    host.settings.get_book=function(store,requested)
        local value=original_get_book(store,requested)
        if value and tostring(requested)==id then value.cached_chapters={[2]=first,[4]=second} end
        return value
    end
    assert(book(host).cached_chapters[4]==second,'fixture did not retain numeric cache keys')
    press(view,'Read cached copy')
    host.settings.get_book=original_get_book
    pump(function() return Reader.instance and Reader.instance.document and Reader.instance.document.file==second end)
    assert(book(Reader.instance.weread).pending_upload_position.chapter_uid==4,
        'opening the exact cached chapter changed the pending position')
    print('\nWEREAD_NUMERIC_CACHE_RESUME='..json.encode({result='PASS',exact_chapter=true,pending_preserved=true}))
    close_reader();host=assert(FM.instance.weread)
    patch(host,{cached_chapters={['2']=first,['4']=second}})
end
local function omit_target()
    patch(assert(FM.instance.weread),{chapters=false,chapter_uid=4,chapter_idx=4,
        pending_upload_position={book_id=id,chapter_uid=4,chapter_idx=4,percent=70},
        pending_upload_account=saved.pending_upload_account,last_local_position=last_local,
        recent_read_account=saved.pending_upload_account,cached_chapters={['2']=first}})
end
omit_target()
host,view=detail();press(view,'Read cached copy');fallback_warning(true)
pump(function() return Reader.instance and Reader.instance.document and Reader.instance.document.file==first end)
report.explicit_cached_copy=true;close_reader()
omit_target()
host,view=detail();offline=true;press(view,'▤ Read');fallback_warning(false)
local after_cancel=book(host)
assert(not Reader.instance and after_cancel.pending_upload_position.book_id==id
    and after_cancel.pending_upload_position.chapter_uid==4 and after_cancel.pending_upload_position.chapter_idx==4
    and after_cancel.pending_upload_position.percent==70 and after_cancel.pending_upload_account==saved.pending_upload_account
    and after_cancel.last_local_position.chapter_uid==last_local.chapter_uid)
report.fallback_warning_cancel_preserved=true
press(view,'▤ Read');fallback_warning(true)
pump(function() return Reader.instance and Reader.instance.document and Reader.instance.document.file==first end)
report.offline_missing_target_fallback=true;close_reader();offline=false
if os.getenv('WEREAD_TEST_DUPLICATE_CHAPTER_TITLES')=='1' then
    omit_target()
    host=assert(FM.instance.weread)
    local damaged=home..'/synthetic-damaged-resume.epub'
    local fixtures=assert(debug.getinfo(1,'S').source:match('^@(.*/)'))
    dofile(fixtures..'epub_member_damage.lua')(second,damaged,'OEBPS/text/chapter.xhtml',false)
    local input=assert(io.open(damaged,'rb'))
    local damaged_bytes=assert(input:read('*a'));assert(input:close())
    patch(host,{cached_chapters={['2']=first,['4']=damaged}})
    host,view=detail();offline=true
    local pending=book(host).pending_upload_position
    press(view,'▤ Read');fallback_warning(false)
    local kept=book(host).pending_upload_position
    assert(not Reader.instance and kept.chapter_uid==pending.chapter_uid
        and kept.chapter_idx==pending.chapter_idx and kept.percent==pending.percent,
        'cancelling a damaged resume changed the pending position')
    press(view,'▤ Read');fallback_warning(true)
    pump(function() return Reader.instance and Reader.instance.document.file==first end)
    input=assert(io.open(damaged,'rb'));assert(input:read('*a')==damaged_bytes);assert(input:close())
    report.damaged_resume_fallback=true
    close_reader();offline=false
    print('PASS: corrupt rendered chapter prompted before opening a different chapter in ReaderUI')
end
omit_target()
host=assert(FM.instance.weread)
require('weread.ui.download_library').show(host)
pump(function() return host.shelf_view and host.shelf_view._discovery_tab=='downloads' end)
local downloads=host.shelf_view
local cached
for _,row in ipairs(downloads.books) do if row.bookId==id then cached=row end end
assert(cached,'partial download missing from the downloads list')
local function choose_local_copy()
    downloads.on_hold(cached)
    local button=assert(downloads._shelf_popup).buttons[1][1]
    assert(button.text==tr('Read downloaded copy'))
    button.callback()
    pump(function() return host._missing_resume_confirmation or Reader.instance end)
    assert(not Reader.instance,'shortcut skipped the missing-chapter confirmation')
end
choose_local_copy();fallback_warning(false)
assert(not Reader.instance and book(host).pending_upload_position.chapter_uid==4,'cancelled shortcut changed the pending chapter')
choose_local_copy();fallback_warning(true)
pump(function() return Reader.instance and Reader.instance.document.file==first end)
report.downloads_missing_target_fallback=true;close_reader()
omit_target()
current=select(2,read_from_shelf(second))
assert(book(current).cached_chapters['4']==second,'missing target chapter was not added to the cache')
report.missing_resume_chapter_downloaded=true;close_reader()
omit_target()
host=assert(FM.instance.weread);host:closeWeReadUI();host:showHome()
local home_view=assert(host.shelf_view);local recent
for _i,row in ipairs(home_view.books) do if tostring(row.bookId or row.book_id)==id then recent=row end end
assert(recent and recent._cached,'missing cached book on home')
home_view.on_select(recent,'books')
pump(function() return Reader.instance and Reader.instance.document and Reader.instance.document.file==second end)
assert(book(Reader.instance.weread).cached_chapters['4']==second,'home did not download the missing chapter')
report.home_missing_target_downloaded=true;close_reader()
local handoff_position
if os.getenv('WEREAD_TEST_RESUME_HANDOFF')=='1' then
    current=select(2,read_from_shelf())
    current:showChapterList(book(current));view=assert(current._chapter_list_view);view._chapter_rows[2].callback()
    pump(function() return Reader.instance and Reader.instance.document.file==first end)
    reader,current=Reader.instance,Reader.instance.weread
    pump(function() return current.progress_sync.current_book_id==id end)
    local chapter_index=assert(Dom.open(reader.document,id,2))
    local quote=format=='web_txt' and '这是第2章的第8段。窗外的风穿过树梢' or '这是第2章的第8段。我们沿着小路慢慢前行'
    local point=assert(chapter_index.map:locate(quote))
    local original=assert(Source.read_document(reader.document,id,2))
    local target={book_id=id,chapter_uid='2',chapter_offset=point.co,basis=Source.coordinate_basis(format),upload_verified=false}
    for _i,key in ipairs({'file_id','book_version','raw_sha256','render_path'}) do target[key]=original[key] end
    local applied;assert(current:openSourcePosition(target,function(result) applied=result or false end))
    pump(function() return applied~=nil end);assert(applied)
    close_reader()
    handoff_position=assert(book(assert(FM.instance.weread)).last_local_position.source_position)
    assert(handoff_position.chapter_uid=='2' and handoff_position.chapter_offset==point.co)
end
if os.getenv('WEREAD_TEST_CATALOG_AUTH_RECOVERY') and os.getenv('WEREAD_TEST_CATALOG_AUTH_RECOVERY')~='refresh' then
    host=assert(FM.instance.weread)
    patch(host,{chapters=false})
    local saved_book=book(host)
    assert(host.library_db:putBook(saved_book) and host.library_db:putChapters(id,{}))
    os.remove(assert(require('weread.lib.content').catalog_cache_path(host.settings,saved_book)))
end
host,view=detail()
local rate_check
if os.getenv('WEREAD_TEST_CATALOG_AUTH_RECOVERY') then
    local fixtures=assert(debug.getinfo(1,'S').source:match('^@(.*/)'))
    rate_check=dofile(fixtures..'catalog_auth_recovery_case.lua')(host,view,book,pump,tick,press)
elseif os.getenv('WEREAD_TEST_DOWNLOAD_AUTH_RENEWAL') then
    local fixtures=assert(debug.getinfo(1,'S').source:match('^@(.*/)'))
    rate_check=dofile(fixtures..'download_auth_recovery_case.lua')(host,view,book,pump,tick,press)
elseif os.getenv('WEREAD_TEST_DOWNLOAD_RATE_LIMIT')=='1' or os.getenv('WEREAD_TEST_DOWNLOAD_AUTH_EXPIRY')=='1' then
    local fixtures=assert(debug.getinfo(1,'S').source:match('^@(.*/)'))
    rate_check=dofile(fixtures..'download_rate_limit_case.lua')(host,view,book,pump,tick,press)
else press(view,'⇩ Download full book') end
pump(function() return book(host).cached_full_book~=nil and not host.downloader._active_job end)
if rate_check then
    if os.getenv('WEREAD_TEST_CATALOG_AUTH_RECOVERY') then report.catalog_auth=rate_check()
    elseif os.getenv('WEREAD_TEST_DOWNLOAD_AUTH_RENEWAL') then report.auth_renewal=rate_check()
    elseif os.getenv('WEREAD_TEST_DOWNLOAD_AUTH_EXPIRY')=='1' then report.auth_expiry=rate_check()
    else report.rate_limit=rate_check() end
end
local full=assert(book(host).cached_full_book)
pump(function() return Reader.instance and Reader.instance.document.file==full end)
reader,current=Reader.instance,Reader.instance.weread;report.full_download=true
if os.getenv('WEREAD_TEST_DUPLICATE_CHAPTER_TITLES')=='1' then check_full_chapter_status(current) end
if os.getenv('WEREAD_TEST_READER_PROGRESS')=='1' then
    dofile(debug.getinfo(1,'S').source:match('^@(.*/)')..'reader_progress_smoke.lua')(
        reader,current,pump,shot,clean,true)
    local starting_point=reader.document:getXPointer()
    local chapter_two=assert(Dom.chapter_start(reader.document,id,'2'))
    local chapter_three=assert(Dom.chapter_start(reader.document,id,'3'))
    local function press_quick(button_id)
        clean(reader)
        assert(current:onShowWeReadQuickMenu())
        local menu=assert(UI:getTopmostVisibleWidget())
        local button=assert(menu:getButtonById(button_id));assert(button.enabled~=false)
        UI:forceRePaint();button:onTapSelectButton()
    end
    offline=true
    reader.rolling:onGotoXPointer(chapter_two)
    press_quick('next_chapter')
    pump(function() return reader.document:isXPointerInCurrentPage(chapter_three) end)
    assert(Reader.instance==reader,'native next reopened the entire EPUB')
    press_quick('previous_chapter')
    pump(function() return reader.document:isXPointerInCurrentPage(chapter_two) end)
    assert(Reader.instance==reader,'native previous reopened the entire EPUB')
    press_quick('next_chapter')
    local fourth=assert(Dom.chapter_start(reader.document,id,'4'))
    reader.rolling:onGotoXPointer(fourth)
    local settled=false;UI:scheduleIn(.3,function() settled=true end)
    pump(function() return settled end)
    assert(reader.document:isXPointerInCurrentPage(fourth),'deferred chapter action moved the new page')
    reader.rolling:onGotoXPointer(chapter_two)
    press_quick('next_chapter')
    current:onSuspend();current:onResume()
    settled=false;UI:scheduleIn(.3,function() settled=true end)
    pump(function() return settled end)
    assert(reader.document:isXPointerInCurrentPage(chapter_two),'quick action survived a suspend and resume')
    reader.rolling:onGotoXPointer(starting_point)
    offline=false
    report.native_quick_chapters=true
end
if handoff_position then
    local deadline=socket.gettime()+12
    while not current.progress_sync:current_source_target() and socket.gettime()<deadline do tick();socket.sleep(.01) end
    local retained=assert(current.progress_sync:current_source_target(),'single-chapter position was not restored in the full EPUB')
    assert(retained.chapter_uid==handoff_position.chapter_uid and retained.chapter_offset==handoff_position.chapter_offset
        and retained.raw_sha256==handoff_position.raw_sha256 and retained.file_id~=handoff_position.file_id
        and retained.upload_verified==false and current.progress_sync.verified==false)
    report.single_to_full_handoff=true
end
for uid=1,6 do
    local original=assert(Source.read_document(reader.document,id,uid));assert(original.format==format)
end
report.full_source_records=true
if handoff_position then
    local live_index=assert(Dom.open(reader.document,id,2))
    local quote=format=='web_txt' and '这是第2章的第12段。窗外的风穿过树梢' or '这是第2章的第12段。我们沿着小路慢慢前行'
    local point=assert(live_index.map:locate(quote))
    local located=assert(live_index:locate(point.co))
    local Task=require('weread.lib.source_position_worker')
    local capture=Task.capture
    Task.capture=function(input) socket.sleep(.8);return capture(input) end
    reader.rolling:onGotoXPointer(located.xpointer)
    current.source_position:on_view_changed(true)
    -- The chapter list navigates inside an open combined EPUB. Open the
    -- separate cached copy explicitly to exercise the handoff between files.
    assert(current:openFile(first,nil,book(current)))
    assert(Reader.instance==reader and current._read_resume_token and not current._read_resume_token.dispatched)
    pump(function() return current.source_position.worker and current.source_position.worker.job~=nil end)
    local pid=current.source_position.worker.job.pid
    clean(reader);reader.rolling:onGotoPage(reader:getCurrentPage()+1)
    Task.capture=capture
    pump(function() return require('ffi/util').isSubProcessDone(pid) end)
    assert(Reader.instance==reader and reader.document.file==full and not current._read_resume_token)
    report.cancelled_live_file_open=true

    reader.rolling:onGotoXPointer(located.xpointer)
    current.source_position:on_view_changed(true)
    local location=assert(require('weread.lib.source_context').location(reader.document,reader.view.view_mode))
    local live_expected=assert(live_index:capture(location.xpointer)).co
    assert(not current.source_position:current())
    assert(current:openFile(first,nil,book(current)))
    assert(Reader.instance==reader and current._read_resume_token and not current._read_resume_token.dispatched)
    pump(function() return Reader.instance and Reader.instance.document.file==first
        and Reader.instance.weread.progress_sync:current_source_target()~=nil end)
    current=Reader.instance.weread
    local retained=assert(current.progress_sync:current_source_target())
    assert(retained.chapter_uid=='2' and retained.chapter_offset==live_expected and retained.file_id==handoff_position.file_id)
    report.full_to_single_handoff=true;report.live_source_preparation=true
    current:showBookMenu(book(current))
    pump(function() return current._book_detail_view and not current.book_metadata_context end)
    press(current._book_detail_view,'▤ Read')
    pump(function() return Reader.instance and Reader.instance.document.file==full
        and Reader.instance.weread.progress_sync:current_source_target()~=nil end)
    reader,current=Reader.instance,Reader.instance.weread
    retained=assert(current.progress_sync:current_source_target())
    assert(retained.chapter_uid=='2' and retained.chapter_offset==live_expected and retained.file_id~=handoff_position.file_id)
    report.live_single_to_full_handoff=true
end
local index,why=Dom.open(reader.document,id,4);assert(index,why)
local quote=format=='web_txt' and '这是第4章的第8段。窗外的风穿过树梢' or '这是第4章的第8段。我们沿着小路慢慢前行'
local point=assert(index.map:locate(quote))
local original=assert(Source.read_document(reader.document,id,4))
local target={book_id=id,chapter_uid='4',chapter_offset=point.co,basis=Source.coordinate_basis(format),upload_verified=false}
for _i,key in ipairs({'file_id','book_version','raw_sha256','render_path'}) do target[key]=original[key] end
local applied;assert(current:openSourcePosition(target,function(result) applied=result or false end))
pump(function() return applied~=nil end);assert(applied and applied.chapter_uid=='4')
local bound=assert(current.progress_sync.source_anchor)
assert(assert(index:capture(bound.xpointer)).co==point.co and reader.document:isXPointerInCurrentPage(bound.xpointer))
assert(assert(current.source_position:current()).chapter_offset==point.co)
report.full_native_navigation=true
if os.getenv('WEREAD_TEST_DOWNLOAD_PACING')=='1' then
    local fixtures=assert(debug.getinfo(1,'S').source:match('^@(.*/)'))
    dofile(fixtures..'download_pacing_case.lua')(current,reader,id,report,pump,tick,press,evidence)
end
if os.getenv('WEREAD_TEST_CACHE_CLEANUP')=='1' then
    local fixtures=assert(debug.getinfo(1,'S').source:match('^@(.*/)'))
    local restored_xpointer
    reader,current,restored_xpointer=dofile(fixtures..'book_cache_cleanup_smoke.lua')(reader,current,id,report,pump,tick,press,evidence,detail,close_reader)
    full=reader.document.file;bound={xpointer=restored_xpointer}
end
UI:forceRePaint();Device.screen:shot(evidence..'/cached-resume-full.png')
local checkpoint={file=full,page=reader:getCurrentPage(),xpointer=bound.xpointer,chapter_uid='4'}
local file=assert(io.open(evidence..'/cached-resume-checkpoint.json','wb'));assert(file:write(json.encode(checkpoint)));file:close()
close_reader()
file=assert(io.open(evidence..'/cached-resume-result.json','wb'));assert(file:write(json.encode(report)));file:close()
print('PASS: plugin cached chapter selection prefers local intent; six-chapter full download -> bound native navigation')
