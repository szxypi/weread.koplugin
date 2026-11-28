-- Offline search and cross-chapter navigation in a real synthetic reader.
require('setupkoenv')
io.stdout:setvbuf('no')
local home,evidence=assert(os.getenv('KO_HOME')),assert(os.getenv('WEREAD_EVIDENCE'))
local signed_out=os.getenv('WEREAD_TEST_CACHED_SIGNED_OUT')=='1'
local no_catalog=os.getenv('WEREAD_TEST_CACHED_NO_CATALOG')=='1'
local full=os.getenv('WEREAD_TEST_CACHED_FULL')=='1'
local incomplete=os.getenv('WEREAD_TEST_CACHED_INCOMPLETE')=='1'
local dual=os.getenv('WEREAD_TEST_CACHED_DUAL')=='1'
local ignore_case=os.getenv('WEREAD_TEST_CACHED_IGNORE_CASE')=='1'
local unicode_case=os.getenv('WEREAD_TEST_CACHED_UNICODE_CASE')=='1'
local txt_source=os.getenv('WEREAD_TEST_CACHED_TXT_SOURCE')=='1'
local canonical_case=os.getenv('WEREAD_TEST_CACHED_CANONICAL_CASE') or ''
assert(canonical_case=='' or unicode_case and (canonical_case=='source' or canonical_case=='query'))
local accented=canonical_case=='source' and ('E'..string.char(204,129)..'clair') or 'Éclair'
assert(not txt_source or unicode_case)
assert(not unicode_case or ignore_case)
local restore_catalog=os.getenv('WEREAD_TEST_CACHED_RESTORE_CATALOG')=='1'
local limit_test=os.getenv('WEREAD_TEST_CACHED_LIMIT')=='1'
local large_uid=os.getenv('WEREAD_TEST_CACHED_LARGE_UID')=='1'
local long_full=tonumber(os.getenv('WEREAD_TEST_CACHED_LONG_FULL'))
local long_catalog=long_full or tonumber(os.getenv('WEREAD_TEST_SEARCH_LONG_CATALOG'))
local second_uid=long_catalog and tostring(long_catalog) or large_uid and '9007199254740993' or '2'
local target_uid=incomplete and '1' or second_uid
local imported=os.getenv('WEREAD_TEST_SEARCH_CB')=='1'
local book_id=imported and 'CB_SyntheticCached' or '900001'
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
G_reader_settings:saveSetting('language','zh_CN')
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
require('gettext').changeLang('zh_CN')
local Device=require('device');require('document/canvascontext'):init(Device)
local Loader=require('pluginloader')
Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
for _i,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
assert(#Loader.enabled_plugins==1)
package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
local Content=require('weread.lib.content')
local Source=require('weread.lib.position_source')
local Identity=require('weread.lib.book_file_identity')
local Settings=require('weread.lib.settings')
local settings=Settings:new()
assert(settings.mock_endpoint and settings.data_dir:match('/weread%-mock$'))
if signed_out then
    -- Mock settings inject a synthetic login on each construction. Preserve
    -- the explicit logout across reader and process reopening without changing
    -- the auth epoch when another settings instance is created.
    local function clear_mock_login(instance)
        instance.store:saveSetting('api_key','')
        instance.store:saveSetting('cookies',{})
        instance.store:saveSetting('account',{})
        instance.store:flush()
    end
    if os.getenv('WEREAD_TEST_CACHED_REOPEN')=='1' or os.getenv('WEREAD_TEST_CACHED_STALE')=='1' then
        clear_mock_login(settings)
    else
        settings:reset_account()
    end
    local original_new=Settings.new
    function Settings:new(...)
        local instance=original_new(self,...)
        clear_mock_login(instance)
        return instance
    end
end
if os.getenv('WEREAD_TEST_CACHED_REOPEN')=='1' or os.getenv('WEREAD_TEST_CACHED_STALE')=='1' then
    local stale=os.getenv('WEREAD_TEST_CACHED_STALE')=='1'
    local persisted=assert(settings:get_book(book_id))
    local path=assert(full and persisted.cached_full_book or persisted.cached_chapters[second_uid])
    if stale then
        assert(persisted.unindexed_resume.raw_sha256~=string.rep('f',64))
        persisted.unindexed_resume.raw_sha256=string.rep('f',64)
        assert(settings:patch_reading_state(book_id,{unindexed_resume=persisted.unindexed_resume}))
    end
    local input=assert(io.open(evidence..'/cached-synthetic-xpointer.txt','rb'))
    local xpointer=input:read('*a');input:close();assert(#xpointer>0 and #xpointer<4096)
    local Client=require('weread.lib.client')
    local ffi=require('ffi')
    pcall(ffi.cdef,'void *mmap(void *, unsigned long, int, int, int, long);')
    local memory=ffi.C.mmap(nil,4096,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1))
    local requests=ffi.cast('int *',memory);requests[0]=0
    function Client:request() requests[0]=requests[0]+1;error('offline reopen attempted a network request') end
    local UI=require('ui/uimanager');UI:setRunForeverMode();UI:setInputTimeout(0)
    local socket=require('socket');local FM=require('apps/filemanager/filemanager')
    FM:showFiles(home);UI:shiftScheduledTasksBy(-1e9);UI:handleInput()
    local host=assert(FM.instance.weread)
    assert(host:startBookReading(persisted))
    local Reader=require('apps/reader/readerui');local deadline=socket.gettime()+45
    if stale then
        local label=require('weread.lib.i18n').tr('Could not verify the saved chapter. Open a cached copy instead?')
        local function confirmation()
            while true do
                UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
                assert(socket.gettime()<deadline,'stale chapter confirmation timed out')
                local dialog=UI:getTopmostVisibleWidget()
                if dialog and dialog.text==label then return dialog end
            end
        end
        local dialog=confirmation();assert(not Reader.instance);dialog.cancel_callback()
        assert(not Reader.instance and not host._unindexed_resume_job)
        assert(host:startBookReading(assert(host.settings:get_book(book_id))))
        dialog=confirmation();assert(not Reader.instance);dialog.ok_callback()
        local previous=assert(full and persisted.cached_full_book or persisted.cached_chapters['1'])
        while not (Reader.instance and Reader.instance.document and Reader.instance.document.file==previous) do
            UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01);assert(socket.gettime()<deadline,'fallback timed out')
        end
        if signed_out then assert(not Reader.instance.weread.settings:get_auth_scope()
            and not Reader.instance.weread.library_db:accountKey(), 'fallback reader was not signed out') end
        local saved=assert(Reader.instance.weread.settings:get_book(book_id))
        assert(saved.pending_upload_position.chapter_uid=='1' and saved.pending_upload_reason=='synthetic_pending')
        local active_reader=Reader.instance
        local plugin=active_reader.weread
        assert(not plugin.library_db:getChapters(book_id))
        local catalog_path=assert(Content.catalog_cache_path(plugin.settings,saved))
        if full then
            local broken=assert(io.open(catalog_path,'wb'))
            assert(broken:write('{broken catalog'));assert(broken:close())
        end
        assert(not Content.load_catalog_cache(plugin.client,plugin.settings,saved))
        assert(plugin:onShowWeReadQuickMenu())
        local quick=assert(UI:getTopmostVisibleWidget())
        local chapter_button=assert(quick:getButtonById('chapter_list'))
        assert(chapter_button.enabled~=false)
        chapter_button.callback()
        deadline=socket.gettime()+45
        while not plugin._saved_chapter_menu do
            UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01);assert(socket.gettime()<deadline,'saved chapter list timed out')
        end
        local picker=plugin._saved_chapter_menu
        local tr=require('weread.lib.i18n').tr
        local label_for_chapter=require('ffi/util').template(tr('Chapter ID %1'),second_uid)
        local selected
        for _,item in ipairs(picker.item_table) do if item.text==label_for_chapter then selected=item end end
        assert(#picker.item_table==2 and selected,'saved chapter picker lost the other downloaded chapter')
        local target_path=assert(full and saved.cached_full_book or saved.cached_chapters[second_uid])
        local target
        if full then
            local proof=assert(require('weread.lib.chapter_cache_claim').combined(saved,target_path))
            target=assert(require('weread.lib.source_dom').chapter_start(active_reader.document,book_id,second_uid,proof))
        end
        picker:onMenuSelect(selected)
        deadline=socket.gettime()+45
        while not (Reader.instance and Reader.instance.document and Reader.instance.document.file==target_path
            and (not target or Reader.instance.document:isXPointerInCurrentPage(target))) do
            UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01);assert(socket.gettime()<deadline,'saved chapter picker timed out')
        end
        saved=assert(Reader.instance.weread.settings:get_book(book_id))
        assert(saved.pending_upload_position.chapter_uid=='1' and saved.pending_upload_reason=='synthetic_pending')
        assert(requests[0]==0,'offline fallback attempted a network request')
        print('\nWEREAD_CACHED_SEARCH_STALE='..require('json').encode({result='PASS',cancel_preserved=true,explicit_fallback=true,saved_picker=true}))
        os.exit(0)
    end
    while not (Reader.instance and Reader.instance.document and Reader.instance.document.file==path
        and Reader.instance.weread and Reader.instance.weread.progress_sync.file_resume) do
        UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01);assert(socket.gettime()<deadline,'bookshelf reopen timed out')
    end
    local reader=Reader.instance
    if signed_out then assert(not reader.weread.settings:get_auth_scope()
        and not reader.weread.library_db:accountKey(), 'new-process reader was not signed out') end
    assert(reader.document:isXPointerInCurrentPage(xpointer),'reopened chapter lost its saved page')
    assert(reader.weread.progress_sync.file_resume.local_only and not reader.weread.progress_sync.verified)
    local saved=assert(reader.weread.settings:get_book(book_id))
    assert(saved.pending_upload_position.chapter_uid=='1' and saved.pending_upload_position.chapter_offset==19
        and saved.pending_upload_reason=='synthetic_pending' and saved.last_local_position.chapter_uid=='1')
    assert(saved.unindexed_resume.chapter_uid==target_uid)
    assert(reader.weread.progress_sync:sync_now()==false)
    reader.weread:onFlushSettings();reader:onClose(false)
    saved=assert(settings:get_book(book_id))
    assert(saved.pending_upload_position.chapter_uid=='1' and saved.pending_upload_reason=='synthetic_pending')
    assert(requests[0]==0,'offline reopen attempted a network request')
    print('\nWEREAD_CACHED_SEARCH_REOPEN='..require('json').encode({result='PASS',file_position=true,pending_preserved=true}))
    os.exit(0)
end
if not signed_out then
    settings:update_auth({account={user_vid='900000',name='Synthetic'},
        cookies={wr_vid='900000',wr_skey='synthetic-search-session'}},{replace_cookies=true})
end
local chapters={{chapterUid='1',chapterIdx=1,title='合成第一章',wordCount=1000},
    {chapterUid=second_uid,chapterIdx=long_catalog or 2,title='合成第二章',wordCount=1000},
    {chapterUid='3',chapterIdx=3,title='未下载章节',wordCount=1000}}
local book={book_id=book_id,bookId=book_id,bookVersion=7,title='合成本地搜索',chapters=chapters,cached_chapters={}}
local bodies,sources={},{}
for i=1,2 do
    local chapter=chapters[i];local uid=chapter.chapterUid
    local text='chapter '..uid..' '..string.rep('ordinary synthetic text ',80)
        ..(unicode_case and ('Straße '..accented..' Σίσυφος') or 'amberneedle')
        ..(limit_test and ' amberneedle amberneedle' or '')
        ..(limit_test and i==1 and ' quartzneedle quartzneedle' or '')
        ..(canonical_case~='' and (' S'..string.char(204,135,204,163)..' canonical') or '')..' distinct ending '..uid
    local raw=txt_source and ('chapter '..uid..'\n\n    '..text) or '<html><body><p>'..text..'</p></body></html>'
    bodies[uid]=txt_source and Content.txt_to_xhtml(raw) or raw
    sources[uid]=assert(Source.capture(book,chapter,raw,txt_source and 'web_txt' or 'web_xhtml'))
    book.cached_chapters[uid]=assert(Content.save_book_epub(settings,book,{chapter},bodies,'cached-search-'..uid,{},nil,nil,Identity.capture(book),sources))
end
if long_catalog then
    local last=chapters[2]
    for i=2,long_catalog-1 do
        local uid=tostring(i)
        local chapter={chapterUid=uid,chapterIdx=i,title='合成章节 '..i,wordCount=1000}
        chapters[i]=chapter
        if long_full then
            local raw='<html><body><p>Ordinary synthetic chapter '..uid..'</p></body></html>'
            bodies[uid]=raw;sources[uid]=assert(Source.capture(book,chapter,raw,'web_xhtml'))
        end
    end
    chapters[long_catalog]=last
end
if unicode_case then
    local Search=require('weread.lib.cached_book_search')
    local Target=require('weread.lib.cached_search_target')
    local cases={{'éCLAIR',accented},{'ΣΊΣΥΦΟΣ','Σίσυφος'}}
    if canonical_case~='' then cases[#cases+1]={'s'..string.char(204,163,204,135),'S'..string.char(204,135,204,163)} end
    for _,test in ipairs(cases) do
        local found=Search.scan({book=book_id,chapter='1',paths={book.cached_chapters['1']},
            keyword=test[1],from=1,ignore_ascii_case=true})
        assert(found and #found.hits==1 and found.hits[1].context:find(test[2],1,true))
        local row=assert(Target.row(book_id,test[1],found.hits[1]))
        assert(Target.bind_file(book.cached_chapters['1'],book_id,row,17).position)
    end
end
book.cached_file=book.cached_chapters['1']
if full then
    local full_sources=incomplete and {['1']=sources['1']} or sources
    local full_chapters=long_full and chapters or {chapters[1],chapters[2]}
    book.cached_full_book=assert(Content.save_book_epub(settings,book,full_chapters,bodies,
        'cached-search-full',{},nil,nil,Identity.capture(book),full_sources))
    book.cached_file=book.cached_full_book
    if not dual then book.cached_chapters={} end
end
if no_catalog then
    book.chapters=nil
    book.last_local_position={book_id=book_id,chapter_uid='1',chapter_offset=19,percent=12}
    book.pending_upload_position={book_id=book_id,chapter_uid='1',chapter_offset=19,percent=12}
    book.pending_upload_reason='synthetic_pending'
    if not signed_out then
        book.pending_upload_account=require('weread.lib.crypto').sha256_hex('weread-library:900000'):sub(1,20)
    end
end
settings:set('books',{[book_id]=book});settings:set('sync',{pull_on_open=false,upload_on_close=false})
local cache=settings:get('cache',{});cache.auto_prefetch_next_chapter=false;settings:set('cache',cache)
local report=settings:get('read_report',{});report.enabled=false;settings:set('read_report',report);settings:flush()
if not no_catalog then assert(Content.save_catalog_cache(require('weread.lib.client'):new(settings),settings,book,chapters)) end
if long_full then
    for uid in pairs(bodies) do bodies[uid],sources[uid]=nil,nil end
    chapters=nil
    collectgarbage()
end
local Client=require('weread.lib.client')
local ffi=require('ffi')
pcall(ffi.cdef,'void *mmap(void *, unsigned long, int, int, int, long);')
local memory=ffi.C.mmap(nil,4096,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1))
local requests=ffi.cast('int *',memory);requests[0]=0
if long_full then
    requests[1]=0
    local Archive=require('weread.lib.source_archive')
    local read_batch=Archive.read_batch
    function Archive.read_batch(...)
        requests[1]=requests[1]+1
        return read_batch(...)
    end
end
local request=Client.request
function Client:request(options)
    requests[0]=requests[0]+1
    if restore_catalog then
        local Protocol=require('weread.lib.protocol')
        if options.method=='GET' and options.url==Protocol.reader_url(book_id) and not options.body then
            return request(self,options)
        end
        if options.method=='POST' and options.url=='https://weread.qq.com/web/book/chapterInfos' then
            local body=self:json_decode(options.body)
            if type(body)=='table' and type(body.bookIds)=='table' and #body.bookIds==1 and body.bookIds[1]==book_id then
                return request(self,options)
            end
        end
    end
    error('offline cached search attempted an unexpected network request')
end
local UI=require('ui/uimanager');UI:setRunForeverMode();UI:setInputTimeout(0)
local socket=require('socket')
local reader=require('apps/reader/readerui'):new{dimen=Device.screen:getSize(),
    document=require('document/documentregistry'):openDocument(book.cached_file)}
UI:show(reader);UI:shiftScheduledTasksBy(-1e9);UI:handleInput()
local function wait(predicate)
    local deadline=socket.gettime()+(long_full and 160 or 45)
    while not predicate() do
        UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
        assert(socket.gettime()<deadline,'cached search UI timed out')
    end
end
local plugin=assert(reader.weread)
if signed_out then
    assert(not plugin.settings:get_auth_scope() and not plugin.library_db:accountKey(), 'mock session was not signed out')
end
plugin.isNetworkOnline=function() return restore_catalog end;plugin.isNetworkConnected=plugin.isNetworkOnline
assert(plugin:showEndOfBookDialog(book_id))
local quick=assert(UI:getTopmostVisibleWidget());local button
for _i,row in ipairs(quick.buttons) do for _j,item in ipairs(row) do
    if item.text==require('weread.lib.i18n').tr('Search downloaded chapters') then button=item end
end end
assert(button and button.enabled~=false);button.callback()
wait(function() return plugin._cached_book_search_owner and plugin._cached_book_search_owner.input end)
local Search=require('weread.lib.cached_book_search');local original=Search.scan;local original_discover=Search.discover
if full then Search.discover=function(...) socket.sleep(.8);return original_discover(...) end
else Search.scan=function(...) socket.sleep(.8);return original(...) end end
local owner=plugin._cached_book_search_owner
if limit_test then require('weread.ui.cached_book_search').MAX_RESULTS=2 end
if ignore_case then UI:forceRePaint();Device.screen:shot(evidence..'/cached-search-options.png') end
if unicode_case then
    assert(Search.unicode_casefold_available())
    if canonical_case~='' then assert(require('weread.lib.unicode_search').canonical_available()) end
    assert(owner.input.buttons[2][1].text==require('weread.lib.i18n').tr('Search (ignore case)'))
end
local keyword=canonical_case=='source' and 'ÉCLAIR'
    or canonical_case=='query' and ('E'..string.char(204,129)..'CLAIR')
    or unicode_case and 'STRASSE' or ignore_case and 'AmBeRnEeDlE' or 'amberneedle'
owner.input:setInputText(keyword)
if ignore_case then owner.input.buttons[2][1].callback() else owner.input.buttons[1][2].callback() end
wait(function() return owner.worker and owner.worker.job end)
local pid=owner.worker.job.pid;assert(plugin.busy_message);plugin.busy_message:onTapClose()
wait(function() return require('ffi/util').isSubProcessDone(pid) end)
assert(not owner.job and #owner.value==0);Search.scan=original;Search.discover=original_discover
local search_start=socket.gettime()
owner.menu:onMenuSelect(owner.menu.item_table[1])
wait(function() return (owner.finished or limit_test and owner.limit) and not owner.job end)
local search_ms=math.floor((socket.gettime()-search_start)*1000+.5)
local count=incomplete and 1 or 2
local unavailable=(no_catalog or long_full) and 0 or #chapters-2
local checked=long_full or (limit_test and 1 or count)
assert(#owner.value==count and owner.checked==checked and owner.missing==unavailable)
if limit_test then
    local _=require('weread.lib.i18n').tr
    assert(owner.limit and not owner.finished and owner.menu.item_table[1].text==
        _('Downloaded search result limit reached; results may be incomplete.'))
    local action,index
    for i,item in ipairs(owner.menu.item_table) do
        if item.text==_('Download full book and search again') then action,index=item,i end
    end
    assert(action and index<=4,'download action was hidden behind search results')
    plugin.isNetworkOnline=function() return true end;plugin.isNetworkConnected=plugin.isNetworkOnline
    owner.menu:onMenuSelect(action);assert(owner.download and owner.download.confirm)
    owner.download.confirm.cancel_callback()
    assert(owner.limit and #owner.value==2 and not owner.download and requests[0]==0)
    local function select_action(label)
        for _i,item in ipairs(owner.menu.item_table) do if item.text==_(label) then owner.menu:onMenuSelect(item);return end end
        error('missing search action: '..label)
    end
    local first=owner.value
    assert(owner.overflow and #owner.overflow==1)
    select_action('Search next batch (keeps only the previous batch)')
    wait(function() return owner.limit and not owner.job and owner.page==2 end)
    assert(#owner.value==2 and owner.value[1].chapter_uid=='1' and owner.value[1].offset>first[2].offset
        and owner.value[2].chapter_uid=='2' and owner.overflow and #owner.overflow==2)
    select_action('Show previous result batch');assert(owner.show_previous and owner.previous==first)
    select_action('Show current result batch');assert(not owner.show_previous)
    select_action('Search next batch (keeps only the previous batch)')
    wait(function() return owner.finished and not owner.job and owner.page==3 end)
    assert(#owner.value==2 and owner.value[1].chapter_uid=='2' and owner.value[2].chapter_uid=='2'
        and owner.value[1].offset>owner.previous[2].offset and owner.value[2].offset>owner.value[1].offset)
    select_action('Show previous result batch');assert(owner.show_previous and #owner.previous==2)
    assert(requests[0]==0,'continued local search attempted a network request')
    UI:forceRePaint();Device.screen:shot(evidence..'/cached-search-batches.png')
    owner.menu:onClose()
    plugin.isNetworkOnline=function() return false end;plugin.isNetworkConnected=plugin.isNetworkOnline
    assert(plugin:showEndOfBookDialog(book_id))
    assert(UI:getTopmostVisibleWidget():getButtonById('search_cached')).callback()
    wait(function() return plugin._cached_book_search_owner and plugin._cached_book_search_owner.input end)
    owner=assert(plugin._cached_book_search_owner)
    owner.input:setInputText('quartzneedle');owner.input.buttons[1][2].callback()
    wait(function() return owner.limit and not owner.job end)
    assert(#owner.value==2 and owner.value[2].chapter_uid=='1')
    local kept_batch=owner.value
    select_action('Search next batch (keeps only the previous batch)')
    assert(owner.value==kept_batch and owner.page==1,'looking for more matches hid the visible batch')
    wait(function() return owner.finished and not owner.job end)
    assert(owner.value==kept_batch and owner.page==1 and not owner.previous and not owner.limit
        and not owner.next_batch and requests[0]==0,'a later chapter without matches created an empty batch')
    print('\nWEREAD_CACHED_SEARCH_LIMIT='..require('json').encode({result='PASS',warning_first=true,
        download_available=true,cancel_preserved=true,continued_batches=3,previous_batch=true,no_empty_batch=true,network_requests=0}))
    os.exit(0)
end
if unicode_case then for _i,hit in ipairs(owner.value) do
    assert(hit.context:find(canonical_case~='' and accented or 'Straße',1,true))
end end
if restore_catalog then
    local function action(label)
        for _i,item in ipairs(owner.menu.item_table) do if item.text==require('weread.lib.i18n').tr(label) then return item end end
        error('catalog restore action missing: '..label)
    end
    local original_reader=Content.ensure_reader_state
    Content.ensure_reader_state=function(...) socket.sleep(.8);return original_reader(...) end
    owner.menu:onMenuSelect(action('Fetch chapter list for this search'))
    wait(function() return owner.catalog_worker and owner.catalog_worker.job end)
    local cancelled=owner.catalog_worker.job.pid;plugin.busy_message:onTapClose()
    wait(function() return require('ffi/util').isSubProcessDone(cancelled) end)
    assert(not owner.job and owner.catalog_missing and requests[0]==0,'cancelled catalog request sent network traffic')
    Content.ensure_reader_state=original_reader
    owner.menu:onMenuSelect(action('Fetch chapter list for this search'))
    local total=long_catalog or 6
    wait(function() return owner.finished and not owner.job and not owner.catalog_missing and owner.total==total end)
    assert(owner.missing==total-2 and #owner.value==2 and owner.value[2].chapter_uid==second_uid
        and requests[0]==2 and action('Download full book and search again'))
    local saved=assert(plugin.settings:get_book(book_id))
    assert(saved.pending_upload_position.chapter_offset==19 and saved.pending_upload_reason=='synthetic_pending')
    assert(plugin.library_db:getChapters(book_id) and Content.load_catalog_cache(plugin.client,plugin.settings,saved))
    print('\nWEREAD_CACHED_CATALOG_RESTORE='..require('json').encode({result='PASS',catalog_restored=true,
        rescan=true,cancel_safe=true,missing=total-2,pending_preserved=true}))
    os.exit(0)
end
if full and no_catalog then
    assert(owner.discovered and owner.discovery_incomplete==incomplete and owner.queue[long_full or count].uid==target_uid)
    if incomplete then
        local found=false
        for _i,item in ipairs(owner.menu.item_table) do
            if item.text==require('weread.lib.i18n').tr('Some chapters in the downloaded book could not be indexed.') then found=true end
        end
        assert(found)
    end
end
UI:forceRePaint();Device.screen:shot(evidence..'/cached-search-results.png')
local expected=owner.value[count].offset
local target=owner.value[count];local selected
local label=owner.titles[target.chapter_uid]..' · '..target.context
for _i,item in ipairs(owner.menu.item_table) do if item.text==label then selected=item end end
assert(selected,'cached search result missing');owner.menu:onMenuSelect(selected)
wait(function()
    local instance=require('apps/reader/readerui').instance
    if instance and instance.weread then reader=instance;plugin=instance.weread end
    local held=reader and plugin.progress_sync and plugin.progress_sync:current_source_target()
    return reader and reader.document and reader.document.file==(full and book.cached_full_book or book.cached_chapters[second_uid])
        and plugin.source_navigation and plugin.source_navigation.state=='ready'
        and held and held.chapter_uid==target_uid and held.chapter_offset==expected
end)
if signed_out then
    assert(not plugin.settings:get_auth_scope() and not plugin.library_db:accountKey(), 'reopened reader was not signed out')
end
assert(reader.document:isXPointerInCurrentPage(assert(plugin.progress_sync.source_anchor).xpointer))
assert(not plugin.progress_sync.verified and not plugin.read_report.job)
if no_catalog then
    assert(plugin.progress_sync.file_resume and plugin.progress_sync.file_resume.local_only)
    local saved=assert(plugin.settings:get_book(book_id))
    assert(saved.pending_upload_position.chapter_uid=='1' and saved.pending_upload_position.chapter_offset==19
        and saved.pending_upload_reason=='synthetic_pending' and saved.last_local_position.chapter_uid=='1')
    assert(plugin.progress_sync:sync_now()==false)
    local xpointer=assert(plugin.progress_sync.source_anchor.xpointer)
    local output=assert(io.open(evidence..'/cached-synthetic-xpointer.txt','wb'))
    assert(output:write(xpointer));assert(output:close())
    plugin:onFlushSettings();reader:onClose(false)
    saved=assert(settings:get_book(book_id))
    assert(saved.pending_upload_position.chapter_uid=='1' and saved.pending_upload_position.chapter_offset==19
        and saved.pending_upload_reason=='synthetic_pending' and saved.last_local_position.chapter_uid=='1')
end
assert(requests[0]==0,'offline cached search attempted a network request')
if long_full then
    assert(owner.total==long_full and owner.checked==long_full and requests[1]>0 and requests[1]<500)
    if not no_catalog then
        assert(owner.catalog and owner.titles[target_uid]=='合成第二章','whole-book batch replaced the catalog title')
    end
    print('\nWEREAD_CACHED_LONG_FULL='..require('json').encode({chapters=owner.checked,
        batch_reads=tonumber(requests[1]),search_ms=search_ms}))
end
print('\nWEREAD_CACHED_SEARCH_UI='..require('json').encode({result='PASS',results=count,unavailable=unavailable,
    navigation=true,cancel_resume=true,signed_out=signed_out,imported=imported,no_catalog=no_catalog,
    full=full,incomplete=incomplete,dual=dual,ignore_ascii_case=ignore_case}))
os.exit(0)
