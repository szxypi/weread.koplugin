-- Actual native menus/dialogs/workers/SQLite, using a separate synthetic ledger.
return function(reader,request_count,flush_tasks)
    local plugin=reader.weread;local UI=require('ui/uimanager');local socket=require('socket')
    local C=require('weread.lib.readtime_transfer_contract');local Store=require('weread.lib.offline_time_store')
    local Coverage=require('weread.lib.readtime_coverage');local tr=require('weread.lib.i18n').tr
    local account=assert(plugin.library_db:accountKey());local home=assert(os.getenv('KO_HOME'))
    local root=plugin.settings.data_dir..'/review-fixture';assert(require('libs/libkoreader-lfs').mkdir(root))
    local original_store,original_coverage=plugin.offline_time.store,plugin.readtime_coverage
    assert(not plugin.offline_time.active,'review fixture requires a stopped collector')
    local original_summary=C.digest(assert(original_store:summary(account)))
    assert(plugin.library_db:putBook({bookId='904201',title='山谷中的离线阅读记录 · '..string.rep('这是一段很长的中文书名，用于检查原生排版与截断。',8)}))
    local ledger=Store:new(root);local now=os.time();local start=now-20000
    for index=1,146 do
        local known=index>121;local duration=known and 60 or 1;local at=start+index*61
        local window=assert(ledger:begin(account,{book_id='904201',stats_book=1,start_time=at,time_zone='+08:00',
            book_version=known and 7 or 0,file_id=known and string.rep('f',64) or '',version_source=known and 'epub_snapshot' or 'unavailable'}))
        assert(ledger:collect(account,window,{{page=tostring(index),start_time=at,duration=duration}},at+duration,true))
    end
    assert(ledger:_access(account,function(db)
        db:exec("UPDATE segments SET state='in_flight' WHERE id=144; UPDATE segments SET state='unknown' WHERE id=145; UPDATE segments SET state='covered' WHERE id=146;")
        db:exec("INSERT INTO totals VALUES('confirmed',120)")
        local at=start+122*61
        db:exec('UPDATE segments SET start_time='..at..' WHERE id=145')
        return true
    end))
    local coverage=Coverage:new(root,function() return start end);assert(coverage:initialize())
    plugin.offline_time.store,plugin.readtime_coverage=ledger,coverage
    local function snapshot()
        local pages={};local cursor,upper=0,nil
        repeat
            local page=assert(ledger:review_page(account,'all',cursor,upper,100));pages[#pages+1]=page.rows
            upper=page.upper_id;cursor=page.last_id
            if not page.has_more then return C.digest({rows=pages,summary=ledger:summary(account)}) end
        until false
    end
    local original=snapshot();local writes=request_count('/web/book/read')
    local function pump(predicate)
        local deadline=socket.gettime()+15
        while not predicate() do
            assert(socket.gettime()<deadline,'offline ledger native worker timed out')
            flush_tasks();socket.sleep(.02)
        end
    end
    local function choose(label)
        local menu=assert(plugin._offline_time_menu)
        for _i,item in ipairs(menu.item_table) do if item.text==tr(label) then menu:onMenuSelect(item);return end end
        error('offline ledger native menu missing: '..label)
    end
    local function show()
        plugin:showOfflineTimeStatus();pump(function() return plugin._offline_time_menu~=nil end)
    end
    local function shot(name)
        UI:forceRePaint();require('device').screen:shot(home..'/../evidence/offline-review-'..name..'.png')
    end
    local function wait_menu() pump(function() return plugin._offline_time_menu~=nil end) end
    local function wait_detail() pump(function() return plugin._offline_time_detail~=nil end) end
    show();shot('summary');choose('Pending local records');wait_menu();shot('pending')
    assert(#plugin._offline_time_menu.item_table==22,'native page did not bound pending rows')
    assert(plugin._offline_time_menu.item_table[1].text:match('^%d%d%d%d%-%d%d%-%d%d'),'capture time must precede a long title')
    local first=plugin._offline_time_menu.item_table[1].callback
    choose('Next batch');wait_menu();shot('next')
    choose('Previous batch');wait_menu()
    plugin._offline_time_menu:onMenuSelect(plugin._offline_time_menu.item_table[1]);wait_detail();shot('source')
    assert(plugin._offline_time_detail.title:find(tr('Download source needs verification'),1,true),'legacy source was shown as verified')
    plugin._offline_time_detail.buttons[1][1].callback();wait_menu()
    choose('Offline reading time');wait_menu();choose('Uncertain time records');wait_menu();shot('uncertain')
    plugin._offline_time_menu:onMenuSelect(plugin._offline_time_menu.item_table[2]);wait_detail();shot('unknown-detail')
    assert(plugin._offline_time_detail.title:find(tr('Uncertain records are kept and will not be sent again automatically.'),1,true))
    assert(plugin._offline_time_detail.title:find(tr('Overlapping local time is kept for review.'),1,true))
    plugin._offline_time_detail.buttons[1][1].callback();wait_menu();choose('Offline reading time');wait_menu()
    choose('Covered time records');wait_menu();shot('covered');choose('Offline reading time');wait_menu()
    choose('Check saved time');wait_detail();shot('selection')
    assert(plugin._offline_time_detail.title:find('600',1,true),'native scan did not reach valid rows after page one')
    plugin._offline_time_detail.buttons[1][1].callback();wait_menu()
    local old_menu=plugin._offline_time_menu;first();assert(plugin._offline_time_menu==old_menu,'stale row reopened old page')
    choose('Check saved time');wait_detail()
    local dismissed=plugin._offline_time_detail;dismissed:onClose()
    assert(not plugin._offline_time_review and not plugin._offline_time_detail,'outside/back dismissal retained the record dialog')
    dismissed.buttons[1][1].callback();assert(not plugin.busy_message,'dismissed dialog returned to an old page')
    show()
    plugin:closeOfflineTimeUI();show()
    plugin:showOfflineTimeStatus();assert(plugin.busy_message);plugin.busy_message:onTapClose()
    assert(not plugin._offline_time_review and not plugin._offline_time_menu and not plugin.busy_message,'dismiss did not cancel ledger reading')
    local deadline=socket.gettime()+.5
    while socket.gettime()<deadline do flush_tasks();socket.sleep(.02) end
    assert(not plugin._offline_time_menu and not plugin._offline_time_detail,'late ledger result reopened UI')
    show();plugin:onSuspend()
    assert(not plugin._offline_time_review and not plugin._offline_time_menu and not plugin._offline_time_detail,'suspend retained ledger views')
    plugin:onResume()
    assert(snapshot()==original,'native review changed source rows, states or totals')
    assert(request_count('/web/book/read')==writes,'native ledger review uploaded reading time')
    plugin:closeOfflineTimeUI();plugin.offline_time.store,plugin.readtime_coverage=original_store,original_coverage
    assert(C.digest(original_store:summary(account))==original_summary,'fixture affected collected native seconds')
    local report={result='PASS',synthetic_only=true,source_rows=146,screen_width=require('device').screen:getWidth(),
        native_worker=true,sqlite=true,pending_cursor_pagination=true,capture_time_first=true,legacy_source_explained=true,unknown_no_replay_explained=true,
        covered_separate=true,scan_past_first_100=true,selected_seconds=600,original_rows_and_states_exact=true,
        stale_callback_rejected=true,busy_dismiss_cancelled=true,suspend_closed_views=true,late_result_no_reopen=true,detail_dismiss_guard=true,
        production_collected_ledger_preserved=true,reading_writes=0}
    local file=assert(io.open(home..'/../evidence/offline-time-review.json','w'));file:write(plugin.client:json_encode(report));file:close()
    print('PASS: native offline ledger summary/pagination/detail/overlap/source/selection -> real workers/SQLite; cancel/suspend/stale guards, no writes, collected source unchanged')
end
