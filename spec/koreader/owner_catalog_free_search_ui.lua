-- Read-only real-source UI probe. Input, source, and account data never appear
-- in output; EPUBs and settings are created only in an isolated memory profile.
require('setupkoenv')
local home=assert(os.getenv('KO_HOME'))
local result={result='UNVERIFIED'}
local ok=pcall(function()
    local raw=io.stdin:read(8*1024*1024+1);assert(#raw<=8*1024*1024)
    local input=require('json').decode(raw)
    assert(type(input.book)=='string' and type(input.chapter)=='string' and type(input.local_chapter)=='string'
        and input.chapter~=input.local_chapter and type(input.source)=='string' and type(input.keyword)=='string'
        and type(input.offset)=='number')
    G_defaults=require('luadefaults'):open()
    G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
    G_reader_settings:saveSetting('language','zh_CN');G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
    require('gettext').changeLang('zh_CN')
    local Device=require('device');require('document/canvascontext'):init(Device)
    Device.screen.shot=function() error('screenshots_disabled',0) end
    local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
    for _i,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
    assert(#Loader.enabled_plugins==1)
    package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
    local Content=require('weread.lib.content');local Source=require('weread.lib.position_source')
    local Identity=require('weread.lib.book_file_identity');local settings=require('weread.lib.settings'):new()
    assert(not settings.mock_endpoint)
    if os.getenv('WEREAD_OWNER_UNINDEXED_REOPEN')=='1' then
        local book=assert(settings:get_book(input.book));local path=assert(book.cached_chapters[input.chapter])
        local file=assert(io.open(home..'/resume-xpointer.txt','rb'));local xpointer=file:read('*a');file:close()
        assert(#xpointer>0 and #xpointer<4096)
        local ffi=require('ffi');pcall(ffi.cdef,'void *mmap(void *, unsigned long, int, int, int, long);')
        local memory=ffi.C.mmap(nil,4096,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1))
        local requests=ffi.cast('int *',memory);requests[0]=0
        local Client=require('weread.lib.client')
        function Client:request() requests[0]=requests[0]+1;error('offline_network_request',0) end
        local UI=require('ui/uimanager');UI:setRunForeverMode();UI:setInputTimeout(0)
        local socket=require('socket');local FM=require('apps/filemanager/filemanager')
        FM:showFiles(home);UI:shiftScheduledTasksBy(-1e9);UI:handleInput()
        local host=assert(FM.instance.weread);assert(host:startBookReading(book))
        local Reader=require('apps/reader/readerui');local deadline=socket.gettime()+90
        while not (Reader.instance and Reader.instance.document and Reader.instance.document.file==path
            and Reader.instance.weread and Reader.instance.weread.progress_sync.file_resume) do
            UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01);assert(socket.gettime()<deadline,'reopen_timeout')
        end
        local reader=Reader.instance
        assert(reader.document:isXPointerInCurrentPage(xpointer) and reader.weread.progress_sync.file_resume.local_only
            and not reader.weread.progress_sync.verified)
        local saved=assert(reader.weread.settings:get_book(input.book))
        assert(saved.pending_upload_position.chapter_uid==input.local_chapter and saved.pending_upload_position.chapter_offset==19
            and saved.pending_upload_reason=='synthetic_pending' and saved.last_local_position.chapter_uid==input.local_chapter)
        assert(reader.weread.progress_sync:sync_now()==false and requests[0]==0)
        reader.weread:onFlushSettings();reader:onClose(false)
        assert(requests[0]==0)
        result={result='PASS',bookshelf_resume=true,prior_position_preserved=true,offline=true}
        return
    end
    local book={book_id=input.book,bookId=input.book,bookVersion=0,title='合成标题',cached_chapters={}}
    local chapters={{chapterUid=input.local_chapter,title='合成章节'}, {chapterUid=input.chapter,title='本地章节'}}
    local bodies={[input.local_chapter]='<html><body><p>合成本地起始章节。</p></body></html>',[input.chapter]=input.source}
    for _i,chapter in ipairs(chapters) do
        local uid=chapter.chapterUid
        local source={[uid]=assert(Source.capture(book,chapter,bodies[uid],'web_xhtml'))}
        book.cached_chapters[uid]=assert(Content.save_book_epub(settings,book,{chapter},bodies,'owner-local',{},nil,nil,Identity.capture(book),source))
    end
    book.cached_file=book.cached_chapters[input.local_chapter]
    book.last_local_position={book_id=input.book,chapter_uid=input.local_chapter,chapter_offset=19,percent=12}
    book.pending_upload_position={book_id=input.book,chapter_uid=input.local_chapter,chapter_offset=19,percent=12}
    book.pending_upload_reason='synthetic_pending'
    settings:set('books',{[input.book]=book});settings:set('sync',{pull_on_open=false,upload_on_close=false})
    local cache=settings:get('cache',{});cache.auto_prefetch_next_chapter=false;settings:set('cache',cache)
    local reporting=settings:get('read_report',{});reporting.enabled=false;settings:set('read_report',reporting);settings:flush()
    local ffi=require('ffi');pcall(ffi.cdef,'void *mmap(void *, unsigned long, int, int, int, long);')
    local memory=ffi.C.mmap(nil,4096,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1))
    local requests=ffi.cast('int *',memory);requests[0]=0
    local Client=require('weread.lib.client')
    function Client:request() requests[0]=requests[0]+1;error('offline_network_request',0) end
    local UI=require('ui/uimanager');UI:setRunForeverMode();UI:setInputTimeout(0)
    local socket=require('socket');local reader=require('apps/reader/readerui'):new{dimen=Device.screen:getSize(),
        document=require('document/documentregistry'):openDocument(book.cached_file)}
    UI:show(reader);UI:shiftScheduledTasksBy(-1e9);UI:handleInput()
    local plugin=assert(reader.weread)
    plugin.isNetworkOnline=function() return false end;plugin.isNetworkConnected=plugin.isNetworkOnline
    local function wait(predicate)
        local deadline=socket.gettime()+90
        while not predicate() do
            UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
            assert(socket.gettime()<deadline,'ui_timeout')
        end
    end
    assert(plugin:showEndOfBookDialog(input.book))
    local quick=assert(UI:getTopmostVisibleWidget());local button
    for _i,row in ipairs(quick.buttons) do for _j,item in ipairs(row) do
        if item.text==require('weread.lib.i18n').tr('Search downloaded chapters') then button=item end
    end end
    assert(button and button.enabled~=false);button.callback()
    wait(function() return plugin._cached_book_search_owner and plugin._cached_book_search_owner.input end)
    local owner=plugin._cached_book_search_owner;assert(owner.catalog_missing)
    owner.input:setInputText(input.keyword);owner.input.buttons[1][2].callback()
    wait(function() return owner.finished and not owner.job end)
    assert(#owner.value==1 and owner.value[1].chapter_uid==input.chapter and owner.value[1].offset==input.offset)
    owner.menu:onMenuSelect(owner.menu.item_table[1])
    wait(function()
        local instance=require('apps/reader/readerui').instance
        if instance and instance.weread then reader=instance;plugin=instance.weread end
        local held=reader and plugin.progress_sync and plugin.progress_sync:current_source_target()
        return reader and reader.document and reader.document.file==book.cached_chapters[input.chapter]
            and plugin.source_navigation and plugin.source_navigation.state=='ready' and not plugin._read_resume_active
            and held and held.chapter_uid==input.chapter and held.chapter_offset==input.offset
    end)
    assert(reader.document:isXPointerInCurrentPage(assert(plugin.progress_sync.source_anchor).xpointer))
    assert(plugin.progress_sync.file_resume and plugin.progress_sync.file_resume.local_only and not plugin.progress_sync.verified)
    local alert=assert(UI:getTopmostVisibleWidget())
    assert(alert.text==require('weread.lib.i18n').tr('Chapter list unavailable. This chapter will reopen from the bookshelf; the previous pending sync is preserved. Refresh the chapter list before syncing.'))
    assert(plugin.progress_sync:sync_now()==false and requests[0]==0)
    local xpointer=assert(plugin.progress_sync.source_anchor.xpointer)
    local output=assert(io.open(home..'/resume-xpointer.txt','wb'));assert(output:write(xpointer));assert(output:close())
    plugin:onFlushSettings();reader:onClose(false)
    local saved=assert(settings:get_book(input.book))
    assert(saved.pending_upload_position.chapter_uid==input.local_chapter and saved.pending_upload_position.chapter_offset==19
        and saved.pending_upload_reason=='synthetic_pending' and saved.last_local_position.chapter_uid==input.local_chapter)
    assert(requests[0]==0)
    result={result='PASS',native_navigation=true,prior_position_preserved=true,offline=true}
end)
if not ok then result.result='UNVERIFIED' end
print('\nWEREAD_OWNER_CATALOG_FREE_UI='..require('json').encode(result))
os.exit(result.result=='PASS' and 0 or 1)
