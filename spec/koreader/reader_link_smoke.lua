-- Actual native input/menu/dialog, independent worker, HTTP, SQLite and accounts.
return function(plugin,count,flush_tasks,home,pump)
    local UIManager=require('ui/uimanager')
    local Screen=require('device').screen
    local Store=require('weread.lib.reader_link_store')
    local Protocol=require('weread.lib.protocol')
    local Settings=require('weread.lib.settings')
    local Library=require('weread.lib.library_db')
    local socket=require('socket')
    local settings,client=plugin.settings,plugin.client
    local http,ltn12=require('socket.http'),require('ltn12')
    local id='900024'
    local url=Protocol.reader_url(id)
    local kept_path=home..'/weread-mock/reader-link-kept/kept.epub'
    local original_reader_url='https://example.invalid/legacy'
    local store=Store:new(plugin.library_db,client)
    local tr=require('weread.lib.i18n').tr
    local function control(options)
        local body=client:json_encode(options)
        local _,code=http.request{url=settings.mock_endpoint..'/__control',proxy=settings.mock_endpoint,method='POST',
            headers={['content-type']='application/json',['content-length']=#body},source=ltn12.source.string(body),sink=ltn12.sink.null()}
        assert(code==200)
    end
    local function row(widget,label)
        for _,item in ipairs(widget.item_table) do if item.text==tr(label) then return item end end
        error('native menu item missing: '..label)
    end
    local function choose(widget,label) widget:onMenuSelect(row(widget,label)) end
    local function close_info()
        local widget=UIManager:getTopmostVisibleWidget()
        if widget and widget~=plugin._book_detail_view and widget~=plugin.ui then UIManager:close(widget) end
    end
    local before_books=settings:get('books',{})
    local old_book=before_books[id]
    before_books[id]={book_id=id,title='Synthetic local state',reader_url=original_reader_url,progress=83,chapter_uid=99,chapter_offset=123,bookVersion=47,
        pending_upload_position={book_id=id,percent=83},pending_upload_account=plugin.library_db:accountKey(),
        cached_chapters={['1']=kept_path}}
    settings:set('books',before_books);settings:flush()
    local writes=count('/web/book/read')
    local shelf_before=#plugin.library_db:getShelf()
    local online=plugin.isNetworkOnline
    plugin.isNetworkOnline=function() return true end
    plugin:closeWeReadUI()
    local entry
    for _,item in ipairs(plugin:getMainMenuItems()) do if item.text==tr('Imported books') then entry=item end end
    assert(entry and not entry.keep_menu_open,'imported-book menu entry missing')
    entry.callback()
    choose(assert(plugin._reader_link_menu),'Import reader link')
    local input=assert(plugin._reader_link_input)
    input:setInputText(Protocol.reader_url(id,'2')..'?wvid=discarded#discarded')
    control{match='/web/reader/',times=0,delay=0.3}
    local before=count('/web/reader/'..Protocol.e(id))
    input.buttons[1][2].callback()
    assert(not plugin._reader_link_input and plugin.reader_link_context and plugin.reader_link_worker.job,'native input did not hand off to worker')
    local heartbeat=false
    UIManager:scheduleIn(0.1,function() heartbeat=true end)
    pump(function() return heartbeat end)
    assert(plugin.reader_link_context,'reader-link request blocked UI heartbeat')
    local changed=settings:get('books',{});changed[id].progress=84;changed[id].pending_upload_position.percent=84
    settings:set('books',changed);settings:flush()
    pump(function() return not plugin.reader_link_context end);flush_tasks()
    local saved=assert(store:get(id))
    assert(saved.reader_url==url and saved.metadata.token==nil and saved.metadata.psvts==nil
        and saved.metadata.progress==nil and saved.metadata.bookVersion==nil,'import stored reader session or positions')
    assert(plugin._book_detail_view and count('/web/reader/'..Protocol.e(id))==before+1,'import did not open native detail or duplicated metadata HTTP')
    local live=settings:get_book(id)
    -- The imported list owns its canonical URL; metadata never replaces the
    -- reading session URL in the latest per-book checkpoint.
    assert(live.reader_url==original_reader_url and live.progress==84 and live.chapter_uid==99 and live.chapter_offset==123 and live.bookVersion==47
        and live.pending_upload_position.percent==84 and live.cached_chapters['1']==kept_path,
        'import replaced current local reading or download state')
    close_info();UIManager:forceRePaint();Screen:shot(home..'/../evidence/reader-link-imported-detail.png')
    control{match='',times=0,delay=0}

    -- Reopen with a new Settings/SQLite instance; cached import works offline.
    local reopened=Store:new(Library:new(Settings:new()),client)
    assert(reopened:find(url).metadata.bookId==id,'import did not survive a fresh settings/database instance')
    plugin.isNetworkOnline=function() return false end
    plugin:showImportedBooks();choose(plugin._reader_link_menu,saved.metadata.title)
    choose(plugin._reader_link_actions,'Open book')
    assert(plugin._book_detail_view and count('/web/reader/'..Protocol.e(id))==before+1,'offline reopen fetched the reader')
    plugin:closeWeReadUI();plugin.isNetworkOnline=function() return true end

    -- A failed refresh and dismissal preserve the saved entry.
    local imported_at=store:get(id).imported_at
    control{match='/web/reader/',times=1,status=429,delay=0}
    assert(require('weread.ui.reader_link').start(plugin,url,true))
    pump(function() return not plugin.reader_link_context end)
    assert(store:get(id).imported_at==imported_at and not plugin._book_detail_view,'429 replaced or opened stored import')
    close_info();control{match='/web/reader/',times=0,delay=0.5}
    assert(require('weread.ui.reader_link').start(plugin,url,true))
    plugin.busy_message:onTapClose()
    assert(not plugin.reader_link_context and not plugin.reader_link_worker.job and not plugin.busy_message,'dismiss retained import worker')
    local deadline=socket.gettime()+0.6
    while socket.gettime()<deadline do flush_tasks();socket.sleep(0.01) end
    assert(store:get(id).imported_at==imported_at and not plugin._book_detail_view,'cancelled import reopened UI')
    control{match='',times=0,delay=0}

    -- Same-account auth revision and suspend must drop late results.
    control{match='/web/reader/',times=0,delay=0.4}
    assert(require('weread.ui.reader_link').start(plugin,url,true))
    local cookies=settings:get('cookies');cookies.wr_skey='synthetic-link-replacement'
    settings:set('cookies',cookies);settings:flush()
    pump(function() return not plugin.reader_link_context end)
    assert(store:get(id).imported_at==imported_at and not plugin._book_detail_view,'changed cookie accepted import result')
    assert(require('weread.ui.reader_link').start(plugin,url,true));plugin:onSuspend()
    assert(not plugin.reader_link_context and not plugin.reader_link_worker.job,'suspend retained import')
    plugin:onResume();control{match='',times=0,delay=0}

    -- Import list is account-local, bounded and independent of cloud shelf state.
    local account=settings:get('account')
    control{match='/web/reader/',times=0,delay=0.4}
    assert(require('weread.ui.reader_link').start(plugin,url,true))
    settings:set('account',{user_vid='90009999'});settings:flush();plugin:onWeReadAccountChanged()
    assert(not plugin.reader_link_context and not plugin.reader_link_worker.job,'account switch retained import worker')
    control{match='',times=0,delay=0}
    assert(store:get(id)==nil and #store:list(0,20).books==0,'another account saw imported book')
    assert(store:put({reader_url=url,metadata={bookId=id,title='Other account synthetic'}}))
    settings:set('account',account);settings:flush();plugin:onWeReadAccountChanged()
    assert(store:get(id).metadata.title==saved.metadata.title,'account switch replaced original import')
    for i=1,22 do
        local book_id=tostring(901000+i)
        assert(store:put({reader_url=Protocol.reader_url(book_id),metadata={bookId=book_id,title='合成导入书籍 '..i,author='合成作者'}},1000+i))
    end
    local database=assert(plugin.library_db:open())
    local statement=database:prepare('INSERT INTO reader_links (book_id,reader_url,payload,imported_at) VALUES (?,?,?,?)')
    statement:bind('999999',Protocol.reader_url('999999'),'{broken',2000):step();statement:reset()
    local wrong={reader_url=Protocol.reader_url('999997'),metadata={bookId='999997',title='Different synthetic source'}}
    statement:bind('999998',Protocol.reader_url('999998'),client:json_encode(wrong),2001):step();statement:close();database:close()
    assert(not store:get('999998') and not store:find(Protocol.reader_url('999998')),'mismatched row identity accepted cached link')
    local page=assert(store:list(0,20));assert(#page.books==18 and page.has_more,'corrupt row blocked bounded pagination')
    plugin:showImportedBooks();UIManager:forceRePaint();Screen:shot(home..'/../evidence/reader-link-imported-list.png')
    choose(plugin._reader_link_menu,'Next batch')
    assert(plugin._reader_link_menu and row(plugin._reader_link_menu,'Previous batch'),'next import batch lost return action')

    require('weread.ui.reader_link').actions(plugin,id,0)
    choose(plugin._reader_link_actions,'Remove imported book')
    plugin._reader_link_confirm:onClose()
    assert(store:get(id),'declining local removal deleted entry')
    require('weread.ui.reader_link').actions(plugin,id,0)
    choose(plugin._reader_link_actions,'Remove imported book')
    local old_confirm=plugin._reader_link_confirm
    settings:set('account',{user_vid='90009999'});settings:flush();plugin:onWeReadAccountChanged()
    old_confirm.ok_callback()
    assert(store:get(id).metadata.title=='Other account synthetic','stale confirmation removed other account entry')
    settings:set('account',account);settings:flush();plugin:onWeReadAccountChanged()
    require('weread.ui.reader_link').actions(plugin,id,0)
    choose(plugin._reader_link_actions,'Remove imported book')
    plugin._reader_link_confirm.ok_callback()
    assert(not store:get(id) and plugin._reader_link_menu,'local removal did not refresh list')
    assert(settings:get_book(id).cached_chapters['1']==kept_path and #plugin.library_db:getShelf()==shelf_before,
        'local removal deleted download state or changed shelf membership')
    assert(count('/web/book/read')==writes,'reader-link import wrote reading state')
    plugin:closeWeReadUI();plugin.isNetworkOnline=online
    local current=settings:get('books',{});current[id]=old_book;settings:set('books',current);settings:flush()
    local report={result='PASS',synthetic_only=true,native_input=true,background_http=true,same_link_identity=true,
        filtered_metadata=true,offline_reopen=true,sqlite_reopen=true,account_isolated=true,pagination=true,
        existing_local_state_preserved=true,rate_no_retry=true,dismiss_cancelled=true,cookie_change_rejected=true,
        suspend_cancelled=true,account_cancelled=true,corrupt_row_skipped=true,cache_row_identity_checked=true,stale_remove_confirmation_rejected=true,local_remove_only=true,reading_writes=0}
    local file=assert(io.open(home..'/../evidence/reader-link.json','w'));file:write(client:json_encode(report));file:close()
    print('PASS: Reader-link native input -> background HTTP -> identity/metadata -> per-account SQLite -> offline details/list/pagination/local remove; cancel/auth/suspend/stale prompt guards')
end
