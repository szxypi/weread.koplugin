-- Open an off-shelf synthetic book through the plugin, then resume from home.
-- The second process has no server and reuses only the isolated test profile.
require('setupkoenv')
local home,evidence=assert(os.getenv('KO_HOME')),assert(os.getenv('WEREAD_EVIDENCE'))
local switch=os.getenv('WEREAD_TEST_HOME_ACCOUNT_SWITCH')=='1'
local switch_reopen=os.getenv('WEREAD_TEST_HOME_ACCOUNT_REOPEN')=='1'
local unknown=os.getenv('WEREAD_TEST_HOME_UNKNOWN_LEGACY')=='1'
local claim_reopen=os.getenv('WEREAD_TEST_HOME_CLAIM_REOPEN')=='1'
local scroll_reopen=os.getenv('WEREAD_TEST_HOME_SCROLL_REOPEN')=='1'
local claim_scroll=os.getenv('WEREAD_TEST_CLAIM_SCROLL')=='1'
local reopen=os.getenv('WEREAD_TEST_HOME_REOPEN')=='1' or switch or switch_reopen or unknown or claim_reopen or scroll_reopen
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
G_reader_settings:saveSetting('language','zh_CN')
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
require('gettext').changeLang('zh_CN')
local Device=require('device');require('document/canvascontext'):init(Device)
package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
local settings=require('weread.lib.settings'):new()
assert(settings.mock_endpoint and settings.data_dir:match('/weread%-mock$'))
if not reopen then
    settings:update_auth({account={user_vid='900000',name='Synthetic'},
        cookies={wr_vid='900000',wr_skey='synthetic-home-session'}},{replace_cookies=true})
    local sync=settings:get('sync');sync.pull_on_open=false;sync.upload_on_close=false;sync.upload_interval_minutes=0;settings:set('sync',sync)
    local cache=settings:get('cache');cache.auto_prefetch_next_chapter=false;cache.download_book_images=false;cache.download_underlines_and_thoughts=false;settings:set('cache',cache)
    local report=settings:get('read_report');report.enabled=false;settings:set('read_report',report);settings:flush()
end
local ffi=require('ffi');pcall(ffi.cdef,'void *mmap(void *, unsigned long, int, int, int, long);')
local memory=ffi.C.mmap(nil,4096,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1))
local requests=ffi.cast('int *',memory);requests[0]=0
local Client=require('weread.lib.client')
function Client:request() requests[0]=requests[0]+1;error('local home attempted a network request',0) end
local Common=require('weread.ui.common')
Common.isNetworkOnline=function() return false end;Common.isNetworkConnected=Common.isNetworkOnline
local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
for _i,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
assert(#Loader.enabled_plugins==1)
local UI=require('ui/uimanager');UI:setRunForeverMode();UI:setInputTimeout(0)
local socket,json=require('socket'),require('json')
local FM,Reader=require('apps/filemanager/filemanager'),require('apps/reader/readerui')
local id='900099'
local function tick() UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01) end
local function pump(predicate)
    local deadline=socket.gettime()+45
    while not predicate() do assert(socket.gettime()<deadline,'home local reading deadline');tick() end
end
local function host() if not FM.instance then FM:showFiles(home) end;return assert(FM.instance.weread) end
local function close_reader()
    local reader=assert(Reader.instance)
    while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=reader do UI:close(UI:getTopmostVisibleWidget()) end
    reader.weread:onFlushSettings();reader:onClose(false);assert(not Reader.instance)
end
local function press(view,label)
    local tr=require('weread.lib.plugin_util').tr
    for _i,buttons in ipairs({view._action_buttons or {},view._footer_actions or {}}) do
        for _j,button in ipairs(buttons) do if button.text==tr(label) then assert(button.enabled~=false);button.callback();return end end
    end
    error('missing reading action',0)
end
local function synthetic_note(reader)
    for _i,item in ipairs(reader.annotation.annotations or {}) do
        if item.note=='synthetic note preserved across account reads' then return true end
    end
    return false
end
local function same(left,right)
    if type(left)~=type(right) then return false end
    if type(left)~='table' then return left==right end
    for key,value in pairs(left) do if not same(value,right[key]) then return false end end
    for key in pairs(right) do if left[key]==nil then return false end end
    return true
end
FM:showFiles(home)
local plugin=host();local account=assert(plugin.library_db:accountKey())
if scroll_reopen then
    local book=assert(plugin.settings:get_book(id));local path=assert(book.cached_full_book)
    local map=assert(require('docsettings'):open(path):readSetting('weread_account_locations'))
    local point=assert(map.entries[account].xpointer)
    assert(plugin:startBookReading(book))
    pump(function() return Reader.instance and Reader.instance.weread
        and Reader.instance.weread.progress_sync.current_book_id==id end)
    local reader=Reader.instance;assert(reader.view.view_mode=='scroll')
    local Position=require('weread.lib.reader_position')
    local frame=Position.snapshot(reader.document,'scroll',reader.weread.progress_sync.get_viewport_height())
    assert(Position.contains_anchor(reader.document,frame,point),'saved scroll anchor was not restored')
    assert(synthetic_note(reader),'scroll reopen lost the native note')
    close_reader();assert(requests[0]==0)
    print('\nWEREAD_NATIVE_SCROLL_REOPEN='..json.encode({result='PASS',fresh_process=true,visible_anchor=true,
        native_note_preserved=true,requests=0}))
    os.exit(0)
end
if claim_reopen then
    local book=assert(plugin.settings:get_book(id));local path=assert(book.cached_full_book)
    local claims=assert(book.native_location_claims)
    local key=require('weread.lib.crypto').sha256_hex(path);local claim=assert(claims[key])
    local other_file=assert(io.open(evidence..'/account-second-xpointer.txt','rb'))
    local other=other_file:read('*a');other_file:close();assert(other~=claim.xpointer)
    local DocSettings=require('docsettings');local sidecar=DocSettings:open(path)
    assert(not sidecar:readSetting('weread_account_locations'))
    sidecar:saveSetting('last_xpointer',other);assert(sidecar:flush())
    assert(plugin:startBookReading(book))
    pump(function() return Reader.instance and Reader.instance.weread
        and Reader.instance.weread.progress_sync.current_book_id==id end)
    local reader=Reader.instance
    local visible
    if reader.view.view_mode=='scroll' then
        local Position=require('weread.lib.reader_position')
        local frame=Position.snapshot(reader.document,'scroll',reader.weread.progress_sync.get_viewport_height())
        visible=Position.contains_anchor(reader.document,frame,claim.xpointer)
    else visible=reader.document:isXPointerInCurrentPage(claim.xpointer) end
    assert(visible,'durable account claim did not restore the chosen page')
    assert(synthetic_note(Reader.instance),'account claim discarded the native note')
    local scroll_anchor
    if reader.view.view_mode=='scroll' then
        local dimen=reader.view.dimen
        local selection=assert(reader.document:getTextFromPositions({x=0,y=0},{x=dimen.w-1,y=dimen.h-1},true))
        scroll_anchor=assert(selection.pos0)
    end
    close_reader()
    local after=DocSettings:open(path):readSetting('weread_account_locations')
    assert(after and after.entries[account] and after.legacy.xpointer==other,
        'account claim did not preserve the previous native page')
    if scroll_anchor then assert(after.entries[account].xpointer==scroll_anchor,'scroll close saved an offscreen origin') end
    assert(requests[0]==0)
    print('\nWEREAD_NATIVE_CLAIM_REOPEN='..json.encode({result='PASS',fresh_process=true,chosen_page=true,
        previous_page_preserved=true,native_note_preserved=true,requests=0}))
    os.exit(0)
end
if unknown then
    local book=assert(plugin.settings:get_book(id));local path=assert(book.cached_full_book)
    local DocSettings=require('docsettings');local sidecar=DocSettings:open(path)
    local original=assert(sidecar:readSetting('last_xpointer'))
    sidecar:delSetting('weread_account_locations');assert(sidecar:flush())
    assert(plugin.settings:patch_reading_state(id,{last_local_position={book_id=id,chapter_uid='1',percent=33},
        last_local_account=account}))
    assert(plugin:startBookReading(assert(plugin.settings:get_book(id))))
    pump(function() return Reader.instance and Reader.instance.weread
        and Reader.instance.weread.progress_sync.current_book_id==id end)
    assert(Reader.instance.document:isXPointerInCurrentPage(original),'unknown legacy page did not open normally')
    assert(synthetic_note(Reader.instance),'legacy reading discarded the native note')
    close_reader()
    local after=DocSettings:open(path)
    assert(not after:readSetting('weread_account_locations') and after:readSetting('last_xpointer')==original,
        'unknown legacy page was automatically claimed or lost')
    plugin=host()
    assert(plugin.settings:patch_reading_state(id,{last_local_position={book_id=id,chapter_uid='1',percent=33},
        last_local_account=account}))
    assert(plugin:startBookReading(assert(plugin.settings:get_book(id))))
    pump(function() return Reader.instance and Reader.instance.weread
        and Reader.instance.weread.progress_sync.current_book_id==id end)
    local reader=Reader.instance;local before=assert(reader.weread.settings:get_book(id))
    assert(before.pending_upload_position and before.source_dispatch
        and before.source_dispatch.id=='synthetic-original-dispatch','missing pending-state fixture')
    local pending=json.decode(json.encode(before.pending_upload_position))
    local dispatch=json.decode(json.encode(before.source_dispatch))
    if claim_scroll then
        reader:handleEvent(require('ui/event'):new('SetViewMode','scroll'))
        for _i=1,5 do tick() end
        assert(reader.view.view_mode=='scroll','native reader did not enter scroll mode')
        reader.document.configurable.view_mode=1
        reader:saveSettings()
    end
    assert(reader.weread:showEndOfBookDialog(id));local quick=assert(UI:getTopmostVisibleWidget())
    local claim_button;local tr=require('weread.lib.plugin_util').tr
    for _i,row in ipairs(quick.buttons) do for _j,button in ipairs(row) do
        if button.text==tr('Save this page locally for this account') then claim_button=button end
    end end
    assert(claim_button and claim_button.enabled~=false,'native claim action was not offered')
    UI:forceRePaint();Device.screen:shot(evidence..'/native-claim-menu.png');claim_button.callback()
    local key=require('weread.lib.crypto').sha256_hex(path)
    pump(function() local current=reader.weread.settings:get_book(id)
        return current and current.native_location_claims and current.native_location_claims[key] end)
    local saved=assert(reader.weread.settings:get_book(id))
    assert(same(saved.pending_upload_position,pending),
        'claim changed the pending cloud position')
    assert(same(saved.source_dispatch,dispatch),
        'claim changed the unconfirmed dispatch journal')
    assert(not DocSettings:open(path):readSetting('weread_account_locations'),
        'claim unexpectedly rewrote the shared native sidecar')
    if reader.weread.source_position then reader.weread.source_position:stop() end
    assert(requests[0]==0)
    print('\nWEREAD_UNKNOWN_NATIVE_LEGACY='..json.encode({result='PASS',original_page=true,not_claimed=true,
        explicit_claim=true,pending_preserved=true,native_note_preserved=true,requests=0}))
    os.exit(0)
end
if switch or switch_reopen then
    -- Mock settings intentionally reset to account 900000 on construction;
    -- select the second synthetic account again in the fresh process.
    if switch_reopen then
        plugin.settings:update_auth({account={user_vid='900002',name='Other synthetic'},
            cookies={wr_vid='900002',wr_skey='synthetic-other-session'}},{replace_cookies=true})
    end
    if switch then
        local books=plugin.settings:get('books',{});local book=assert(books[id])
        -- Simulate upgrading a native sidecar made before account locations.
        -- The prior account's source-bound viewport is independently saved.
        local old_xp_file=assert(io.open(evidence..'/home-recent-xpointer.txt','rb'))
        local old_xp=old_xp_file:read('*a');old_xp_file:close()
        assert(book.last_local_position and book.last_local_position.source_view
            and book.last_local_position.source_view.view.xpointer==old_xp,'missing legacy source-bound viewport')
        local DocSettings=require('docsettings')
        local legacy_sidecar=DocSettings:open(assert(book.cached_full_book))
        assert(legacy_sidecar:readSetting('weread_account_locations'))
        legacy_sidecar:delSetting('weread_account_locations');assert(legacy_sidecar:flush())
        assert(plugin:startBookReading(book))
        pump(function() return Reader.instance and Reader.instance.weread
            and Reader.instance.weread.progress_sync.current_book_id==id end)
        assert(Reader.instance.document:isXPointerInCurrentPage(old_xp),'legacy native page was lost')
        close_reader();plugin=host()
        local migrated=DocSettings:open(assert(book.cached_full_book)):readSetting('weread_account_locations')
        assert(migrated and migrated.entries[account] and migrated.entries[account].xpointer==old_xp
            and migrated.legacy.xpointer==old_xp,'verified legacy page was not migrated')
        books=plugin.settings:get('books',{});book=assert(books[id])
        book.recent_read_account=account;book.recent_read_at=10
        book.home_recent_account=nil;book.home_recent_at=nil;book.last_local_account=nil
        book.last_local_position={book_id=id,chapter_uid='1',percent=33}
        book.pending_upload_position={book_id=id,chapter_uid='1',percent=33}
        book.pending_upload_account=nil;book.pending_upload_reason='synthetic-legacy'
        book.source_dispatch={account=account,id='synthetic-original-dispatch'}
        -- Recreate an old-version on-disk record, retaining the normal book
        -- index and EPUB while forcing the legacy migration path.
        local legacy_dir=assert(book.cache_dir)
        os.remove(legacy_dir..'/.weread-accounts/'..account..'/reading_state.json')
        os.remove(legacy_dir..'/.weread-accounts/legacy_metadata.json')
        assert(require('weread.lib.book_store').save({cache_dir=plugin.settings.cache_dir},id,book))
        assert(plugin.settings:get_book(id).pending_upload_position.percent==33)
        plugin.settings:update_auth({account={user_vid='900002',name='Other synthetic'},
            cookies={wr_vid='900002',wr_skey='synthetic-other-session'}},{replace_cookies=true})
        assert(plugin.settings:get_auth_scope(true).vid=='900002','synthetic account switch not persisted')
        assert(plugin.library_db:accountKey()~=account)
        assert(plugin:recordRecentReading(id))
        local foreign=assert(plugin.settings:get_book(id))
        assert(not foreign.pending_upload_position and not foreign.last_local_position and not foreign.source_dispatch,
            'second account inherited original reading state')
        local current=assert(plugin.library_db:accountKey())
        assert(plugin.settings:patch_reading_state(id,{pending_upload_position={book_id=id,chapter_uid='1',percent=61},
            pending_upload_account=current,last_local_position={book_id=id,chapter_uid='1',percent=62},last_local_account=current,
            source_dispatch={account=current,id='synthetic-second-dispatch'}}))
        plugin:showBookRecord(assert(plugin.settings:get_book(id)),{verified_metadata=true})
        -- The mock always installs account 900000 on new Settings instances.
        -- Re-select B for the ReaderUI instance created by the normal button.
        local Settings=require('weread.lib.settings');local construct=Settings.new
        function Settings:new(...)
            local value=construct(self,...)
            value:update_auth({account={user_vid='900002',name='Other synthetic'},
                cookies={wr_vid='900002',wr_skey='synthetic-other-session'}},{replace_cookies=true})
            return value
        end
        press(assert(plugin._book_detail_view),'▤ Read')
        pump(function() return Reader.instance and Reader.instance.weread
            and Reader.instance.weread.progress_sync.current_book_id==id end)
        local reader=Reader.instance
        assert(synthetic_note(reader),'native note disappeared after account switch')
        local legacy=assert(io.open(evidence..'/home-recent-xpointer.txt','rb'))
        local original_xpointer=legacy:read('*a');legacy:close()
        assert(not reader.document:isXPointerInCurrentPage(original_xpointer),
            'second account opened at the first account\'s native page')
        local pages_before=reader.document:getPageCount()
        assert(reader.font:onSetFontSize(reader.font.configurable.font_size+4))
        for _i=1,5 do tick() end
        assert(reader.document:getPageCount()~=pages_before,'font change did not repaginate synthetic book')
        reader.rolling:onGotoPage(5);tick();reader.weread.progress_sync:on_page_update()
        local second_xpointer=assert(reader.document:getXPointer())
        local second=assert(io.open(evidence..'/account-second-xpointer.txt','wb'));second:write(second_xpointer);second:close()
        close_reader();Settings.new=construct
        local after=assert(plugin.settings:get_book(id))
        assert(after.pending_upload_position and after.last_local_position and after.pending_upload_account==current,
            'second account reading did not save its own checkpoint')
        local f=assert(io.open(evidence..'/account-second-checkpoint.json','wb'))
        f:write(json.encode({pending=after.pending_upload_position.percent,position=after.last_local_position.percent}));f:close()
    end
    local book=assert(plugin.settings:get_book(id));local current=assert(plugin.library_db:accountKey())
    local f=assert(io.open(evidence..'/account-second-checkpoint.json','rb'));local checkpoint=json.decode(f:read('*a'));f:close()
    assert(book.home_recent_account==current and book.pending_upload_account==current)
    assert(book.last_local_position.percent==checkpoint.position and book.pending_upload_position.percent==checkpoint.pending
        and book.source_dispatch.id=='synthetic-second-dispatch','second account checkpoint was not preserved')
    if switch_reopen then
        local second=assert(io.open(evidence..'/account-second-xpointer.txt','rb'))
        local second_xpointer=second:read('*a');second:close()
        local Settings=require('weread.lib.settings');local construct=Settings.new
        function Settings:new(...)
            local value=construct(self,...)
            value:update_auth({account={user_vid='900002',name='Other synthetic'},
                cookies={wr_vid='900002',wr_skey='synthetic-other-session'}},{replace_cookies=true})
            return value
        end
        assert(plugin:startBookReading(book))
        pump(function() return Reader.instance and Reader.instance.weread
            and Reader.instance.weread.progress_sync.current_book_id==id end)
        assert(Reader.instance.document:isXPointerInCurrentPage(second_xpointer),
            'second account native page did not survive a fresh process')
        assert(synthetic_note(Reader.instance),'native note disappeared after process restart')
        close_reader();Settings.new=construct;plugin=host()
        plugin.settings:update_auth({account={user_vid='900000',name='Synthetic'},
            cookies={wr_vid='900000',wr_skey='synthetic-home-session'}},{replace_cookies=true})
        assert(plugin.settings:get_auth_scope(true).vid=='900000','synthetic account restoration not persisted')
        local original=assert(plugin.library_db:accountKey())
        book=assert(plugin.settings:get_book(id))
        assert(original==book.recent_read_account and book.last_local_position.percent==33
            and book.pending_upload_position.percent==33 and book.source_dispatch.id=='synthetic-original-dispatch',
            'original account lost its reading state')
        assert(plugin:startBookReading(book))
        pump(function() return Reader.instance and Reader.instance.weread
            and Reader.instance.weread.progress_sync.current_book_id==id end)
        local first=assert(io.open(evidence..'/home-recent-xpointer.txt','rb'))
        local original_xpointer=first:read('*a');first:close()
        assert(Reader.instance.document:isXPointerInCurrentPage(original_xpointer),
            'original account did not recover its own native page')
        assert(synthetic_note(Reader.instance),'native note disappeared on returning to original account')
        close_reader();plugin=host()
        plugin.settings:update_auth({account={},cookies={}},{replace_cookies=true})
        assert(plugin:recordRecentReading(id))
        book=assert(plugin.settings:get_book(id))
        assert(book.home_recent_account=='' and not book.pending_upload_position and not book.source_dispatch,
            'signed-out event inherited an account checkpoint')
    end
    assert(requests[0]==0)
    print('\nWEREAD_HOME_ACCOUNT_SWITCH='..json.encode({result='PASS',reopen=switch_reopen,
        independent_pending=true,independent_position=true,independent_dispatch=true,
        native_pages=true,native_note_preserved=true,repagination=true,requests=0}))
    os.exit(0)
end
local path,xpointer
if not reopen then
    local chapters={{chapterUid='1',chapterIdx=1,title='合成章节',wordCount=1000}}
    local paragraphs={};for i=1,200 do paragraphs[#paragraphs+1]='<p>合成测试段落 '..i..'，仅用于验证本地阅读。</p>' end
    local body='<html><body>'..table.concat(paragraphs)..'</body></html>'
    local book={book_id=id,bookId=id,bookVersion=1,title='合成本机读物',author='合成作者',chapters=chapters,cached_chapters={}}
    local Source=require('weread.lib.position_source');local Identity=require('weread.lib.book_file_identity')
    local source={['1']=assert(Source.capture(book,chapters[1],body,'web_xhtml'))}
    local Content=require('weread.lib.content')
    path=assert(Content.save_book_epub(settings,book,chapters,{['1']=body},'home-recent',{},nil,nil,Identity.capture(book),source))
    book.cached_full_book=path;book.cached_file=path;book.cached_chapters['1']=path
    assert(Content.save_catalog_cache(plugin.client,settings,book,chapters))
    local books=plugin.settings:get('books',{});books[id]=book
    books[1]={book_id='1',cache_dir=home,cached_file=home..'/legacy-sibling.epub',_library_account_key='other-owner'}
    books['900098']={book_id='900098',title='其他账号',recent_read_at=os.time()+10,recent_read_account='other-owner'}
    books['900097']={book_id='900097',title='其他账号资料',recent_read_at=os.time()+20,recent_read_account=account,_library_account_key='other-owner'}
    local foreign_dir=plugin.settings.cache_dir..'/900097'
    assert(require('util').makePath(foreign_dir))
    local foreign_path=foreign_dir..'/foreign-cache.epub'
    local foreign=assert(io.open(foreign_path,'wb'));assert(foreign:write('Synthetic foreign cache'));assert(foreign:close())
    books['900097'].cached_file=foreign_path
    local shelf_book={book_id='900001',bookVersion=1,title='合成书架',author='不同作者',chapters=chapters}
    shelf_book.cached_full_book=assert(Content.save_book_epub(settings,shelf_book,chapters,{['1']=body},'shelf-download',{},nil,nil,
        Identity.capture(shelf_book),{['1']=assert(Source.capture(shelf_book,chapters[1],body,'web_xhtml'))}))
    books['900001']=shelf_book
    plugin.settings:set('books',books);plugin.settings:flush()
    assert(plugin.settings:find_book_by_file(path)==id,'legacy parent directory claimed the downloaded book')
    assert(plugin.library_db:cacheShelf({{bookId='900001',title='合成书架',readUpdateTime=1}},{}))
    plugin:showHome();assert(#plugin.shelf_view.books==1,'unread off-shelf book appeared')
    plugin:closeWeReadUI();plugin:showBookRecord(book,{verified_metadata=true})
    press(assert(plugin._book_detail_view),'▤ Read')
    pump(function() return Reader.instance and Reader.instance.document and Reader.instance.document.file==path end)
    pump(function() local b=Reader.instance.weread.settings:get_book(id);return b and b.home_recent_account==account end)
    local reader=Reader.instance;assert(reader.document:getPageCount()>3)
    reader.rolling:onGotoPage(3);tick();xpointer=assert(reader.document:getXPointer())
    pump(function() return reader.weread.progress_sync.current_book_id==id and reader.weread.source_position:current()~=nil end)
    assert(reader.weread.progress_sync:checkpoint_local('synthetic_legacy',reader.weread.source_position:current()))
    local last=assert(reader.document:getNextVisibleChar(xpointer))
    reader.annotation:addItem({page=xpointer,pos0=xpointer,pos1=last,drawer='underscore',text='synthetic text',
        note='synthetic note preserved across account reads',datetime='2026-11-11 12:00:00'})
    assert(reader.weread:onShowWeReadQuickMenu())
    local dialog=assert(UI:getTopmostVisibleWidget())
    local close=assert(dialog:getButtonById('close_book'))
    assert(close.text==require('weread.lib.plugin_util').tr('Close book and return home'))
    UI:forceRePaint();close:onTapSelectButton()
    pump(function()
        local next_host=FM.instance and FM.instance.weread
        return not Reader.instance and next_host and next_host.shelf_view and next_host.shelf_view._discovery_tab=='home'
    end)
    assert(FM.instance.file_chooser.path==home,'closing a WeRead EPUB revealed its cache directory')
    local f=assert(io.open(evidence..'/home-recent-xpointer.txt','wb'));f:write(xpointer);f:close()
else
    local f=assert(io.open(evidence..'/home-recent-xpointer.txt','rb'));xpointer=f:read('*a');f:close()
    path=assert(settings:get_book(id).cached_full_book)
end
plugin=host()
if reopen then plugin:closeWeReadUI();plugin:showHome() end
local view=assert(plugin.shelf_view);local selected
for _i,row in ipairs(view.books) do
    local row_id=tostring(row.bookId or row.book_id)
    assert(row_id~='900098' and row_id~='900097','foreign account appeared on home')
    if row_id==id then selected=row end
end
assert(selected and selected._cached and view.books[1]==selected,'local recent book missing or not first')
assert(#assert(plugin.library_db:getShelf())==1 and plugin.library_db:getShelf()[1].bookId=='900001','cloud shelf changed')
UI:forceRePaint();view.on_select(selected,'books')
pump(function() return Reader.instance and Reader.instance.document and Reader.instance.document.file==path end)
local reader=Reader.instance
pump(function() return reader.weread.progress_sync.current_book_id==id end)
assert(reader.document:isXPointerInCurrentPage(xpointer),'home selection lost the saved page')
close_reader();plugin=host()
assert(#assert(plugin.library_db:getShelf())==1 and plugin.library_db:getShelf()[1].bookId=='900001','reading altered cloud shelf')
plugin:showHome()
plugin:showHomeQuickSettings()
local tr=require('weread.lib.plugin_util').tr
local quick=assert(plugin._home_controls_menu)
local opened_downloads
for _,item in ipairs(quick.item_table) do
    if item.text==tr('Downloaded books') then item.callback();opened_downloads=true;break end
end
assert(opened_downloads and plugin._download_library_job and plugin._download_library_job.worker.job)
pump(function() return plugin.shelf_view and plugin.shelf_view._discovery_tab=='downloads' end)
local downloads=plugin.shelf_view
local downloaded, ids={},{}
for _,row in ipairs(downloads.books) do downloaded[row.bookId]=true;ids[#ids+1]=row.bookId;assert(row._cached) end
assert(#downloads.books==2 and downloaded['900001'] and downloaded[id], 'unexpected synthetic downloads: '..table.concat(ids,','))
local LibraryView=require('weread.ui.library_view')
local function replace_download_view()
    local previous=downloads
    pump(function() return plugin.shelf_view and plugin.shelf_view~=previous
        and plugin.shelf_view._discovery_tab=='downloads' end)
    downloads=plugin.shelf_view
end
local function focus_download()
    local mode=require('ui/widget/focusmanager').FORCED_FOCUS
    for y, row in ipairs(downloads.layout) do
        for x, widget in ipairs(row) do
            if widget.book and widget.book.bookId==id then
                downloads:moveFocusTo(x,y,mode)
                assert(downloads:getFocusedBookId()==id,'could not focus the downloaded book')
                return
            end
        end
    end
    error('the target download is outside the visible page')
end
local function search_downloads(value)
    downloads.on_search()
    local dialog=assert(downloads._shelf_popup)
    dialog:setInputText(value);dialog.buttons[1][2].callback()
    replace_download_view()
end
local original_download_books=plugin.settings.download_books
local page_size=downloads.page_size
local fixture_count=page_size+1
plugin.settings.download_books=function(book_settings)
    local books=original_download_books(book_settings)
    for index=1,fixture_count do
        local key=tostring(950000+index)
        books[key]={book_id=key,title=('00 合成离线条目 %03d'):format(index),cached_file=path,
            _library_account_key=plugin.library_db:accountKey()}
    end
    return books
end
downloads.on_refresh();replace_download_view()
local real_index=assert(LibraryView.bookIndex(downloads.books,id))
local original_page=math.ceil(real_index/downloads.page_size)
assert(original_page>1,'multiple download pages were not available')
downloads.on_page_changed(original_page);replace_download_view()
assert(downloads:getFocusedBookId()~=id and downloads:getBrowsePosition().book_id~=id,
    'touch-return fixture did not distinguish the opened book from the first visible book')
downloads.on_select(downloads.books[real_index])
fixture_count=fixture_count+original_page*downloads.page_size-real_index+1
assert(plugin._book_detail_view):onClose();replace_download_view()
real_index=assert(LibraryView.bookIndex(downloads.books,id))
assert(downloads.page==original_page+1 and downloads.page==math.ceil(real_index/downloads.page_size),
    'return from a tap followed the first visible book instead of the opened book')
original_page=downloads.page
focus_download()
downloads.on_select(downloads.books[real_index])
fixture_count=fixture_count+page_size
assert(plugin._book_detail_view):onClose();replace_download_view()
assert(downloads.page>original_page and downloads:getFocusedBookId()==id,
    'return from details did not follow the focused book after a cache change')
local restored_page=downloads.page
search_downloads('合成作者')
assert(#downloads.books==1 and downloads.books[1].bookId==id,'download search missed the off-shelf book')
search_downloads('')
assert(downloads.page==restored_page and downloads:getFocusedBookId()==id,
    'clearing download search did not restore the unfiltered page and book focus')
plugin.settings.download_books=original_download_books
search_downloads('合成作者')
assert(#downloads.books==1 and downloads.books[1].bookId==id,'download search missed the off-shelf book')
focus_download()
for _,item in ipairs(downloads._navigation_buttons) do
    if item.text==tr('Home') then item.callback();break end
end
pump(function() return plugin.shelf_view and plugin.shelf_view._discovery_tab=='home' end)
require('weread.ui.download_library').show(plugin);replace_download_view()
assert(#downloads.books==1 and downloads.books[1].bookId==id and downloads:getFocusedBookId()==id,
    'returning from Home lost the downloaded search or focus')
UI:forceRePaint();Device.screen:shot(evidence..'/downloaded-books.png')
downloads.on_select(downloads.books[1]);assert(plugin._book_detail_view):onClose()
replace_download_view()
assert(#downloads.books==1 and downloads.books[1].bookId==id,'return from details lost the downloaded search')
local function download_action()
    downloads.on_hold(downloads.books[1])
    local popup=assert(downloads._shelf_popup)
    assert(popup.buttons[1][1].text==tr('Read downloaded copy'))
    return popup.buttons[1][1].callback
end
local stale_action=download_action()
require('weread.ui.shelf_popup').close(downloads)
stale_action();tick()
assert(not Reader.instance and not plugin._book_detail_view,'closed shortcut opened the book')
local blocked_action=download_action()
local backup=path..'.fixture'
assert(os.rename(path,backup))
local show_info=plugin.showInfo
local missing
plugin.showInfo=function(_self,text) missing=text end
blocked_action()
pump(function() return missing or Reader.instance end)
assert(os.rename(backup,path));plugin.showInfo=show_info
assert(not Reader.instance and missing==tr('No cached file.'),'shortcut opened a removed download')
download_action()()
pump(function() return Reader.instance and Reader.instance.document and Reader.instance.document.file==path end)
assert(Reader.instance.document:isXPointerInCurrentPage(xpointer),'download shortcut lost the saved page')
close_reader();plugin=host()
require('weread.ui.download_library').show(plugin)
replace_download_view()
assert(#downloads.books==1 and downloads.books[1].bookId==id and downloads:getFocusedBookId()==id,
    'reopening after offline reading lost the downloaded search or focus')
do
    local Cache=require('weread.lib.native_direct_cache')
    local Crypto=require('weread.lib.crypto')
    local scope=assert(plugin.settings:get_auth_scope())
    local function live() return plugin.settings:auth_scope_matches(scope) end
    local native_id='900096'
    local native_paths={}
    for _,book_id in ipairs({id,native_id}) do
        local book={book_id=book_id,title='Synthetic E-Ink '..book_id,author='Fixture'}
        local row={chapterUid='1',chapterIdx=1,title='Synthetic E-Ink chapter',catalog_order=1,catalog_count=1}
        local xhtml='<html><body><p>Synthetic offline download inventory.</p></body></html>'
        local digest=Crypto.sha256_hex('synthetic download catalog '..book_id)
        local prepared={book_id=book_id,chapter_uid='1',book_version=1,catalog_sha256=digest,
            reading_catalog_sha256=digest,source_sha256=Crypto.sha256_hex(xhtml),source_channel='eink',
            coordinate_source_authoritative=false,missing_images=0,xhtml=xhtml,css='',assets={}}
        native_paths[book_id]=assert(Cache.publish(plugin.settings,scope.vid,book,row,prepared,live)).path
    end
    local function expect(expected)
        assert(#downloads.books==#expected,'unexpected number of filtered downloads')
        for _,book_id in ipairs(expected) do
            assert(LibraryView.bookIndex(downloads.books,book_id),'missing download '..book_id)
        end
    end
    local function choose(filter)
        UI:forceRePaint();assert(downloads.settings_button):onTapSelectButton()
        pump(function() return downloads._shelf_popup end)
        local popup=downloads._shelf_popup
        local button
        for _,row in ipairs(popup.buttons) do if row[1].text==tr(filter) then button=row[1];break end end
        assert(button and not button.checked_func(),'could not select the expected download filter')
        button.callback()
        replace_download_view()
        assert(not plugin._download_library_job,'filter reopened the disk inventory')
    end
    local function hold(book_id, label)
        downloads.on_hold(downloads.books[assert(LibraryView.bookIndex(downloads.books,book_id))])
        for _,row in ipairs(assert(downloads._shelf_popup).buttons) do
            if row[1].text==tr(label) then row[1].callback();return end
        end
        error('missing download action '..label)
    end
    downloads.on_refresh();replace_download_view();search_downloads('')
    expect({id,native_id,'900001'})
    choose('Standard downloads');expect({id,'900001'})
    choose('Saved E-Ink chapters');expect({id,native_id})
    search_downloads('900096');expect({native_id})
    choose('Both download types');expect({})
    search_downloads('');expect({id})
    hold(id,'Clear standard download cache')
    pump(function() return plugin.book_cache_cleanup_job and plugin.book_cache_cleanup_job.dialog end)
    local cleanup=plugin.book_cache_cleanup_job
    assert(cleanup.files>0 and cleanup.items[1].id==id,'preview targeted the wrong standard download')
    UI:close(cleanup.dialog)
    assert(not plugin.book_cache_cleanup_job and require('libs/libkoreader-lfs').attributes(path,'mode')=='file',
        'cancelled cleanup removed the standard download')
    focus_download()
    downloads.on_select(downloads.books[1]);assert(plugin._book_detail_view):onClose()
    replace_download_view();expect({id})
    assert(downloads:getFocusedBookId()==id and downloads.title==tr('Both download types'),
        'returning from details lost the download type or book focus')
    choose('Saved E-Ink chapters');expect({id,native_id})
    hold(native_id,'Clear unused E-Ink chapters')
    pump(function() return plugin._native_cleanup and plugin._native_cleanup.dialog end)
    assert(plugin._native_cleanup.id==native_id,'preview targeted the wrong E-Ink download')
    UI:close(plugin._native_cleanup.dialog)
    assert(not plugin._native_cleanup and require('libs/libkoreader-lfs').attributes(native_paths[native_id],'mode')=='file',
        'cancelled cleanup removed the E-Ink download')
    assert(plugin._book_detail_view):onClose();replace_download_view();expect({id,native_id})
    require('weread.ui.download_library').show(plugin);replace_download_view();expect({id,native_id})
    UI:forceRePaint();Device.screen:shot(evidence..'/downloaded-books-filtered.png')
    for _,file in pairs(native_paths) do assert(os.remove(file)) end
    downloads.on_refresh();replace_download_view();expect({})
    assert(downloads.empty_text==tr('No downloads match this filter.'),'empty filter lost its explanation')
end
downloads.on_refresh()
local previous_job=assert(plugin._download_library_job)
plugin.settings:update_auth({account={user_vid='900002',name='Other synthetic'},
    cookies={wr_vid='900002',wr_skey='synthetic-other-session'}},{replace_cookies=true})
plugin:onWeReadAccountChanged()
assert(not previous_job.worker.job and not plugin._download_library_job,'account change did not stop the old download scan')
require('weread.ui.download_library').show(plugin)
pump(function() return plugin.shelf_view and plugin.shelf_view._discovery_tab=='downloads' end)
assert(#plugin.shelf_view.books==0,'another account saw a private off-shelf download')
assert(plugin.shelf_view.title==tr('Downloaded books'),'another account inherited the download search')
plugin.settings:update_auth({account={user_vid='900000',name='Synthetic'},
    cookies={wr_vid='900000',wr_skey='synthetic-home-session'}},{replace_cookies=true})
plugin:onWeReadAccountChanged()
assert(#assert(plugin.library_db:getShelf())==1 and plugin.library_db:getShelf()[1].bookId=='900001',
    'downloaded list altered cloud shelf membership')
local legacy=assert(plugin.settings:get_book('1',true))
assert(not legacy.home_recent_at and not legacy.last_local_position and not legacy.pending_upload_position,
    'reading wrote a position to the legacy sibling book')
do
    local record=assert(plugin.settings:get_book(id))
    local recent_count=plugin:homePreferences().recent_limit
    local stamp=assert(record.home_recent_at)
    local shelf={books={},archives={}}
    for i=1,recent_count do
        shelf.books[i]={bookId=tostring(920000+i),title='合成最近书目 '..i,readUpdateTime=stamp+60}
    end
    local metadata=record.cache_dir..'/metadata.json'
    local open,reads=io.open,0
    rawset(io,'open',function(filename,...)
        if filename==metadata then reads=reads+1 end
        return open(filename,...)
    end)
    local ok,err=pcall(plugin.showHome,plugin,false,shelf)
    rawset(io,'open',open)
    assert(ok,err)
    local recent=assert(plugin.shelf_view).books
    assert(#recent==recent_count and recent[1].bookId=='920001' and reads==0,
        'a newer cloud list still hydrated an older local book')
    for _,book in ipairs(shelf.books) do book.readUpdateTime=stamp end
    plugin:showHome(false,shelf)
    recent=assert(plugin.shelf_view).books
    assert(#recent==recent_count and recent[1].bookId==id and recent[1]._recent_time==stamp,
        'an off-shelf book lost its place in a cloud timestamp tie')
    UI:forceRePaint()
end
print('PASS: downloaded books, offline search and resume shortcut, account isolation')
assert(requests[0]==0,'local home attempted network')
print('\nWEREAD_HOME_LOCAL_RECENT='..json.encode({result='PASS',reopen=reopen,home_selection=true,
    account_isolation=true,shelf_unchanged=true,saved_page=true,downloads_resume=true,requests=0}))
os.exit(0)
