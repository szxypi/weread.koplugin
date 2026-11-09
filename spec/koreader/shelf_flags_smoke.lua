-- Packaged ReaderUI, account SQLite and native shelf GETs; synthetic only.
return function(plugin,count,flush,home,pump)
    local UIManager=require('ui/uimanager')
    local Screen=require('device').screen
    local Flags=require('weread.lib.shelf_flags')
    local tr=require('weread.lib.i18n').tr
    local settings,client=plugin.settings,plugin.client
    local http,ltn12=require('socket.http'),require('ltn12')
    local function control(data)
        local body=client:json_encode(data)
        local _,code=http.request{url=settings.mock_endpoint..'/__control',proxy=settings.mock_endpoint,method='POST',
            source=ltn12.source.string(body),sink=ltn12.sink.null(),headers={['content-type']='application/json',['content-length']=#body}}
        assert(code==200)
    end
    local function close_notice()
        local top=UIManager:getTopmostVisibleWidget()
        if top and top~=plugin._shelf_state_menu and top~=plugin._book_detail_view and top~=plugin.shelf_view and top~=plugin.ui then UIManager:close(top) end
    end
    local function row(menu,label)
        for _,item in ipairs(menu.item_table) do if item.text==tr(label) then return item end end
        error('shelf status native row missing: '..label)
    end
    local function state_menu(id)
        assert(plugin:showShelfState(id));return assert(plugin._shelf_state_menu)
    end
    local function state(menu,label,expected) assert(row(menu,label).mandatory==tr(expected),'wrong native shelf flag: '..label) end
    local old_shelf=client:json_decode(client:json_encode(settings:get('shelf')))
    local old_filters=plugin.shelf_filters
    local old_sync=client:json_decode(client:json_encode(settings:get('sync')))
    local quiet=client:json_decode(client:json_encode(old_sync))
    quiet.pull_on_open=false;quiet.upload_on_close=false;quiet.check_resume=false
    settings:set('sync',quiet);settings:flush()
    local id='900001'
    local function reader_state()
        local saved=settings:get_book(id) or {};local value={}
        for _,key in ipairs({'progress','chapter_uid','chapter_offset','bookVersion','cached_file','cached_full_book','cached_chapters','cache_dir','pending_upload_position'}) do value[key]=saved[key] end
        return client:json_encode(value)
    end
    local local_before=reader_state()
    local writes=count('/web/book/read')
    plugin:closeWeReadUI()
    assert(plugin.library_db:getShelfEntry(id),'shelf fixture not cached')
    -- Poison the detail payload, then open details. The status view must read
    -- the independent latest shelf payload instead of these stale flags.
    assert(plugin.library_db:putBook({book_id=id,title='Synthetic stale details',finishReading=1,secret=0,isTop=false}))
    plugin:showBookMenu({book_id=id,title='合成书籍：书架状态',finishReading=1,secret=0,isTop=false,chapters={}})
    local detail=assert(plugin._book_detail_view)
    local action
    for _,button in ipairs(detail._action_buttons) do if button.text==tr('Shelf status') then action=button end end
    assert(action,'native detail omitted shelf status action');action.callback()
    local menu=assert(plugin._shelf_state_menu)
    state(menu,'Pinned','Yes');state(menu,'Private reading','Yes');state(menu,'Finished reading','No')
    UIManager:forceRePaint();Screen:shot(home..'/../evidence/shelf-state-known.png')
    menu:onCloseAllMenus();assert(not plugin._shelf_state_menu,'native close retained state menu')
    local before=count('/shelf/sync')
    row(menu,'Refresh shelf status').callback()
    assert(not plugin.shelf_refreshing and count('/shelf/sync')==before,'closed menu started HTTP')
    menu=state_menu('900003');state(menu,'Pinned','Not provided');state(menu,'Private reading','Not provided');state(menu,'Finished reading','No')
    menu=state_menu('999999');state(menu,'Finished reading','Not provided')
    assert(row(menu,'No saved shelf snapshot for this book.'),'missing book declared cloud membership')
    plugin:closeWeReadUI()
    local account_key=plugin.library_db.accountKey
    plugin.library_db.accountKey=function() return 'synthetic-other-shelf-state' end
    menu=state_menu(id);state(menu,'Private reading','Not provided')
    plugin.library_db.accountKey=account_key;plugin:onWeReadAccountChanged()
    assert(not plugin._shelf_state_menu,'account lifecycle retained state menu')

    -- Refresh is the ordinary cancellable shelf read, then a one-time return
    -- to the requested book's snapshot. Metadata refresh never marks it read.
    menu=state_menu(id);control{match='/shelf/sync',times=0,delay=0.4}
    menu:onMenuSelect(row(menu,'Refresh shelf status'))
    assert(plugin.shelf_refreshing and plugin.shelf_refresh_worker.job,'status refresh bypassed worker')
    local heartbeat=false;UIManager:scheduleIn(0.1,function() heartbeat=true end);pump(function() return heartbeat end)
    assert(plugin.shelf_refreshing,'status refresh blocked UI heartbeat')
    pump(function() return not plugin.shelf_refreshing end);flush()
    menu=assert(plugin._shelf_state_menu);state(menu,'Private reading','Yes');state(menu,'Finished reading','No')
    assert(plugin.library_db:getShelfEntry(id).book._native_version==700,'status refresh did not update native shelf snapshot')
    for _,change in ipairs({'dismiss','suspend'}) do
        menu=state_menu(id);menu:onMenuSelect(row(menu,'Refresh shelf status'))
        assert(plugin.shelf_refresh_worker.job)
        if change=='dismiss' then plugin.busy_message:onTapClose() else plugin:onSuspend();plugin:onResume() end
        assert(not plugin._shelf_state_menu and not plugin.shelf_refresh_context and not plugin.shelf_refresh_worker.job,'cancelled status refresh retained job/menu')
    end
    control{match='',times=0,delay=0};flush()
    -- A failed SQLite commit must not present old persisted values as the new
    -- refresh. The normal shelf workflow reports its persistence result.
    local db=assert(plugin.library_db:open())
    local trigger=db:prepare([[CREATE TRIGGER reject_status_cache BEFORE UPDATE ON books WHEN OLD.book_id='900001'
        BEGIN SELECT RAISE(ABORT,'synthetic cache failure'); END]])
    trigger:step();trigger:close()
    db:close()
    menu=state_menu(id);menu:onMenuSelect(row(menu,'Refresh shelf status'))
    pump(function() return not plugin.shelf_refreshing end);flush()
    assert(not plugin._shelf_state_menu,'failed save reopened old state as fresh');close_notice()
    db=assert(plugin.library_db:open());db:exec('DROP TRIGGER reject_status_cache');db:close()

    -- Display-only pin partition is stable, including within a selected group.
    -- Unknown flags remain in server order and never become explicit false.
    local shelf=settings:get('shelf');shelf.sort_order='default';shelf.view_mode='cover';shelf.filter_reading=nil;shelf.filter_download=nil
    settings:set('shelf',shelf);settings:flush();plugin.shelf_group_key=nil
    local books=plugin.library_db:getShelf();local first=books[1]
    table.remove(books,1);table.insert(books,4,first)
    local original_first=books[1].bookId
    plugin:applyShelfSnapshot(books,{{archiveId=1,name='合成分组',bookIds={'900002','900001','900003'}}})
    plugin:showShelfView('books',nil,nil,{skip_cover_fetch_once=true});flush()
    assert(books[1].bookId==original_first and plugin.shelf_view.books[1].bookId==id,'pin order mutated source or did not pin explicit true')
    local cell=assert(plugin.shelf_view._item_rows[1])
    assert(cell._pinned_badge and cell._has_private_badge and not cell._has_finished_badge,'cover badges confused independent finished field')
    local pin=cell._pinned_badge;assert(pin.overlap_offset[1]>=0 and pin:getSize().w<=cell.width and pin:getSize().h<=cell.height,'pin badge outside cover')
    UIManager:forceRePaint();Screen:shot(home..'/../evidence/shelf-state-cover.png')
    local snapshot=plugin.library_db:getShelfEntry(id)
    snapshot.book.finishReading=1;snapshot.book._shelf_progress=99
    local combined=require('weread.ui.library_view').show({mode='books',books={snapshot.book},cover_mode=true,paged=true,
        page_size=plugin.shelf_view.page_size,cover_columns=plugin.shelf_view.cover_columns,cover_rows=plugin.shelf_view.cover_rows,
        navigation=plugin:discoveryNavigation('shelf')}, {})
    local all=combined._item_rows[1]
    assert(all._pinned_badge and all._finished_badge and all._private_badge and all._progress_badge,'simultaneous cover badges missing')
    local left,right=all._pinned_badge,all._finished_badge
    assert(left.overlap_offset[1]+left:getSize().w<=right.overlap_offset[1],'pinned and finished cover stamps overlap')
    UIManager:close(combined)
    plugin.shelf_view.on_display_change('view_mode','list');flush()
    local text=plugin.shelf_view:itemStatus(plugin.shelf_view.books[1])
    assert(text:find(tr('Pinned'),1,true) and text:find(tr('Private'),1,true) and not text:find(tr('Done'),1,true),'list status omitted flags or used finished metadata')
    UIManager:forceRePaint();Screen:shot(home..'/../evidence/shelf-state-list.png')
    plugin.shelf_filters={reading='finished'}
    assert(plugin:bookMatchesFilters({finishReading=true}) and not plugin:bookMatchesFilters({finishReading=0,finished=1,progress=100}),'native finished filter used metadata')
    plugin.shelf_filters={reading='unfinished'}
    assert(plugin:bookMatchesFilters({finishReading=false}) and not plugin:bookMatchesFilters({finished=1}),'unknown treated as explicitly unfinished')
    assert(Flags.display({finished=1,progress=100},'finished')==nil)
    plugin:closeWeReadUI();plugin.shelf_filters=old_filters
    settings:set('shelf',old_shelf);settings:set('sync',old_sync);settings:flush()
    plugin:applyShelfSnapshot(plugin.library_db:getShelf(),plugin.library_db:getShelfArchives())
    assert(reader_state()==local_before,'read-only shelf states changed local progress/download record')
    assert(count('/web/book/read')==writes,'shelf state workflow wrote reading data')
    local report={result='PASS',synthetic_only=true,account_snapshot_read=true,detail_flags_did_not_override=true,
        binary_false_preserved=true,missing_and_invalid_stay_unknown=true,finished_metadata_independent=true,
        native_refresh_worker_and_heartbeat=true,refresh_dismiss_suspend_cancelled=true,cache_failure_did_not_show_stale_refresh=true,
        closed_menu_callback_ignored=true,account_cache_isolated=true,cover_pin_private_finished_progress_coexist=true,
        list_flags_visible=true,pinned_partition_stable=true,original_shelf_order_unchanged=true,explicit_reading_filters=true,
        local_reader_state_unchanged=true,reading_data_writes=0,pin_private_finish_writes=0}
    local fd=assert(io.open(home..'/../evidence/shelf-flags.json','w'));fd:write(client:json_encode(report));fd:close()
    print('PASS: shelf flags -> separate account snapshot/native status menu -> cancellable refresh; private/pinned/done badges, stable pin display and explicit reading filters; no writes')
end
