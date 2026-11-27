-- Actual async worker, HTTP, SQLite and native home/shelf rendering.
-- Invoked only by the isolated synthetic discovery fixture.
return function(plugin, flush_tasks, evidence, paint, wait_progress)
    local UIManager=require("ui/uimanager")
    local Screen=require("device").screen
    local http,ltn12=require("socket.http"),require("ltn12")
    local settings,client=plugin.settings,plugin.client
    local endpoint=settings.mock_endpoint
    local old_key,old_cookies=settings:get("api_key"),settings:get("cookies")
    local old_shelf=client:json_encode(settings:get("shelf"))
    local account=plugin.library_db:accountKey()
    local function count(path,api)
        local chunks={}
        local _,code=http.request{url=endpoint.."/__state",proxy=endpoint,sink=ltn12.sink.table(chunks)}
        assert(code==200)
        local total=0
        for _,request in ipairs(client:json_decode(table.concat(chunks)).requests) do
            if request.path==path and (not api or request.api==api) then total=total+1 end
        end
        return total
    end
    local function control(value)
        local body=client:json_encode(value)
        local _,code=http.request{url=endpoint.."/__control",proxy=endpoint,method="POST",
            headers={["content-type"]="application/json",["content-length"]=#body},
            source=ltn12.source.string(body),sink=ltn12.sink.null()}
        assert(code==200)
    end
    local function expires(books)
        local values={}
        for _,book in ipairs(books) do values[#values+1]={book_id=book.bookId,percent=9,fetched_at=0} end
        assert(plugin.library_db:putShelfProgress(values))
    end
    local function refresh(books)
        local snapshots=plugin:prepareShelfProgress(books)
        plugin:refreshVisibleShelfProgress(plugin.shelf_view,books,snapshots,{force=true})
        wait_progress()
    end
    local function progress(id) return plugin.library_db:getShelfProgress({id})[id] end
    plugin:closeWeReadUI()
    settings:update_auth({api_key="",cookies={wr_vid="900000",wr_skey="synthetic-web-progress"}},{replace_cookies=true})
    local shelf=settings:get("shelf")
    shelf.view_mode="cover";shelf.paginated=true;shelf.sort_order="default"
    settings:set("shelf",shelf);settings:flush()
    local books=plugin.library_db:getShelf()
    local seed=books[1].bookId
    expires(books)
    local gateway=count("/api/agent/gateway","/book/getprogress")
    local writes=count("/web/book/read")
    local before=count("/web/book/getProgress")
    plugin:showBookshelf()
    wait_progress()
    local visible=plugin.shelf_view:getVisibleBooks()
    assert(count("/api/agent/gateway","/book/getprogress")==gateway,"keyless display contacted gateway")
    assert(count("/web/book/getProgress")-before==#visible,"display fetched invisible shelf books")
    for _,book in ipairs(visible) do
        local snapshot=assert(progress(book.bookId))
        assert(snapshot.source=="web" and snapshot.fetched_at>0,"visible Web progress missing from SQLite")
    end
    assert(progress(seed).percent==37 and plugin.shelf_view.books[1]._shelf_progress==83
        and plugin.shelf_view.books[1]._shelf_progress_local,"cloud display replaced pending local progress")
    local local_label=require('weread.lib.shelf_progress').label(83,true)
    local function assert_local_badge(cell)
        assert(cell._progress_badge_text==local_label,'local progress was shown as a cloud percentage')
        local labels=assert(cell._progress_badge_labels)
        if #labels==1 then assert(labels[1].text==local_label and not labels[1].max_width,'local progress was truncated')
        else
            assert(#labels==2 and labels[1].text==require('weread.lib.i18n').tr('Local') and labels[2].text=='83%',
                'compact local badge lost its source or percentage')
            assert(not labels[1].max_width and not labels[2].max_width,'compact local badge was truncated')
        end
        assert(cell._progress_badge:getSize().w<=cell.width,'local progress badge exceeds the cover')
    end
    assert_local_badge(plugin.shelf_view._item_rows[1])
    paint("web-shelf-progress-cover")
    before=count("/web/book/getProgress")
    plugin.shelf_view.on_page_changed(2)
    wait_progress()
    assert(count("/web/book/getProgress")>before,"second keyless page did not refresh")
    plugin.shelf_view.on_page_changed(1)
    plugin.isNetworkOnline=function() return false end
    plugin.shelf_view.on_display_change("view_mode","list")
    assert(plugin.shelf_view:itemStatus(plugin.shelf_view.books[1]):find(local_label,1,true),"offline list did not identify local progress")
    paint("web-shelf-progress-list")
    plugin.isNetworkOnline=function() return true end
    plugin:closeWeReadUI()
    shelf = settings:get("shelf")
    shelf.sort_order = "progress_desc"
    settings:set("shelf", shelf)
    before = count("/web/book/getProgress")
    plugin:showShelfView("books", seed)
    wait_progress()
    assert(#plugin.shelf_view.books == 1 and plugin.shelf_view.books[1].bookId == seed
        and count("/web/book/getProgress") == before, "progress search refetched a fresh visible snapshot")
    expires({books[1]})
    plugin:showShelfView("books", seed)
    wait_progress()
    assert(count("/web/book/getProgress") == before + 1 and progress(seed).percent == 37
        and plugin.shelf_view.books[1]._shelf_progress == 83, "progress search fetched other books or lost local progress")
    local unchanged=assert(progress(seed));unchanged.fetched_at=0
    assert(plugin.library_db:putShelfProgress({unchanged}))
    before=count("/web/book/getProgress")
    plugin:showShelfView("books",seed)
    local opened_shelf=plugin.shelf_view
    wait_progress()
    assert(count("/web/book/getProgress")==before+1 and progress(seed).fetched_at>0,
        'unchanged progress did not refresh its cached timestamp')
    assert(plugin.shelf_view==opened_shelf,'unchanged progress rebuilt the bookshelf')
    shelf.sort_order = "default"
    settings:set("shelf", shelf)
    plugin:closeWeReadUI()
    shelf.paginated = false
    settings:set("shelf", shelf)
    expires(books)
    before = count("/web/book/getProgress")
    plugin:showBookshelf()
    wait_progress()
    local list = assert(plugin.shelf_view)
    local first_screen = {}
    local visible_books = list:getVisibleBooks()
    for _, book in ipairs(visible_books) do first_screen[book.bookId] = true end
    assert(not list.paged and count("/web/book/getProgress") == before + #visible_books,
        "continuous shelf fetched more than the first viewport")
    local snapshots=list:prepareVisibleStatus(visible_books)
    local visible_id=visible_books[2].bookId
    snapshots[visible_id].fetched_at=0
    before=count("/web/book/getProgress")
    plugin:refreshVisibleShelfProgress(list,visible_books,snapshots,{
        on_redraw=function() error('unchanged progress rebuilt the continuous shelf') end,
    })
    wait_progress()
    assert(count("/web/book/getProgress")==before+1 and list:prepareVisibleStatus()[visible_id].fetched_at>0,
        'unchanged progress did not renew the visible list expiry')
    list.scroll:_scrollBy(0, list._item_rows[1]:getSize().h + 1)
    UIManager:forceRePaint()
    local entered = 0
    for _, book in ipairs(list:getVisibleBooks()) do
        if not first_screen[book.bookId] then entered = entered + 1 end
    end
    require("socket").sleep(0.35)
    wait_progress()
    assert(entered > 0 and count("/web/book/getProgress") == before + 1 + entered,
        "scrolling repeated a fresh visible progress request or missed a new row")
    shelf.paginated = true
    settings:set("shelf", shelf)
    plugin:closeWeReadUI()
    expires({books[1]})
    plugin:showHome()
    wait_progress()
    assert(progress(seed).source=="web" and progress(seed).percent==37,"keyless home did not refresh")
    assert(plugin.shelf_view.books[1]._shelf_progress==83,"keyless home lost pending location")
    assert_local_badge(plugin.shelf_view._item_rows[1])
    unchanged=assert(progress(seed));unchanged.fetched_at=0
    assert(plugin.library_db:putShelfProgress({unchanged}))
    before=count("/web/book/getProgress")
    plugin:showHome()
    local opened_home=plugin.shelf_view
    wait_progress()
    assert(count("/web/book/getProgress")==before+1 and progress(seed).fetched_at>0,
        'unchanged home progress did not refresh its cached timestamp')
    assert(plugin.shelf_view==opened_home,'unchanged progress rebuilt the home page')
    UIManager:forceRePaint();Screen:shot(evidence.."/web-home-progress.png")
    local selected={{bookId=seed},{bookId=books[2].bookId}}
    settings:set("api_key","synthetic-invalid-key");settings:flush()
    control{match="/book/getprogress",times=1,status=503,delay=0}
    before=count("/web/book/getProgress")
    refresh(selected)
    assert(count("/api/agent/gateway","/book/getprogress")==gateway+1
        and count("/web/book/getProgress")==before+#selected and progress(seed).source=="web",
        "gateway failure repeated or did not fall back to Web")
    settings:set("api_key","");settings:flush()
    control{match="/web/book/getProgress",times=1,status=429,delay=0}
    local cached=client:json_encode(progress(seed))
    before=count("/web/book/getProgress")
    refresh(selected)
    assert(count("/web/book/getProgress")==before+1 and client:json_encode(progress(seed))==cached,
        "rate failure flooded remaining books or replaced cache")
    refresh(selected)
    assert(count("/web/book/getProgress")==before+1,"backoff repeated a failed session immediately")
    settings:update_auth({cookies={wr_vid="900000",wr_skey="synthetic-fresh-progress"}},{replace_cookies=true})
    refresh(selected)
    assert(count("/web/book/getProgress")==before+1+#selected,"new access inherited an old failure backoff")
    control{match="/web/book/getProgress",times=0,delay=0.5}
    cached=client:json_encode(progress(seed))
    plugin:refreshVisibleShelfProgress(plugin.shelf_view,{books[1]},plugin:prepareShelfProgress({books[1]}),{force=true})
    require("socket").sleep(0.1)
    settings:update_auth({cookies={wr_vid="900000",wr_skey="synthetic-raced-progress"}},{replace_cookies=true})
    wait_progress()
    assert(client:json_encode(progress(seed))==cached,"old child wrote progress after Cookie replacement")
    local saved=settings:get("books",{})[seed]
    assert(saved.pending_upload_position.percent==83 and saved.chapter_uid==99
        and plugin.library_db:accountKey()==account and count("/web/book/read")==writes,
        "display refresh changed reading state, owner or server progress")
    control{match="",times=0,delay=0}
    plugin:closeWeReadUI()
    -- Exercise the display-only CB_ route with the actual worker and SQLite.
    local cb={bookId='CB_SyntheticDisplay',title='CB 编号合成书籍',author='合成作者'}
    shelf=settings:get('shelf');shelf.view_mode='cover';settings:set('shelf',shelf)
    settings:set('api_key','synthetic-valid-key');settings:flush()
    local cb_before,gateway_before=count('/web/book/getProgress'),count('/api/agent/gateway','/book/getprogress')
    plugin:showShelfView('books',nil,nil,{page=1,refresh_progress=true,
        prepared_shelf={books={cb,books[1]},accounts={}}})
    wait_progress()
    assert(count('/web/book/getProgress')==cb_before+1
        and count('/api/agent/gateway','/book/getprogress')==gateway_before+1,'mixed CB/numeric batch used the wrong channels')
    assert(progress(cb.bookId).percent==0 and progress(cb.bookId).source=='web'
        and cb._shelf_progress==0,'CB display was not persisted or rendered')
    assert(progress(seed).source=='gateway','CB read changed the ordinary-book route')
    paint('cb-shelf-progress-web')
    cb_before,gateway_before=count('/web/book/getProgress'),count('/api/agent/gateway','/book/getprogress')
    plugin.isNetworkOnline=function() return false end
    plugin.shelf_view.on_display_change('view_mode','list')
    assert(plugin.shelf_view:itemStatus(cb):find('0%%') and count('/web/book/getProgress')==cb_before
        and count('/api/agent/gateway','/book/getprogress')==gateway_before,'offline CB list lost its cache or contacted HTTP')
    paint('cb-shelf-progress-offline')
    plugin.isNetworkOnline=function() return true end
    plugin:closeWeReadUI()
    settings:update_auth({cookies={},api_key='synthetic-valid-key'},{replace_cookies=true})
    local unknown={bookId='CB_SyntheticUnknown',title='未授权的 CB 合成书籍',author='合成作者'}
    plugin:showShelfView('books',nil,nil,{page=1,refresh_progress=true,
        prepared_shelf={books={unknown,books[1]},accounts={}}})
    wait_progress()
    assert(count('/web/book/getProgress')==cb_before
        and count('/api/agent/gateway','/book/getprogress')==gateway_before+1,
        'gateway-only visible batch sent CB or blocked its ordinary book')
    assert(unknown._shelf_progress==nil and not progress(unknown.bookId),'missing CB Web access invented a cloud percentage')
    assert(count('/web/book/read')==writes,'CB display changed reading state')
    paint('cb-shelf-progress-gateway-only')
    local report=assert(io.open(evidence..'/cb-shelf-progress.json','wb'))
    assert(report:write(client:json_encode({mixed_channels_verified=true,cb_snapshot_source_web=true,
        sqlite_display_verified=true,offline_cached_list_zero_requests=true,gateway_only_cb_skipped=true,
        ordinary_gateway_continued=true,unavailable_progress_not_invented=true,reading_writes_unchanged=true})))
    assert(report:close())
    local bulk_smoke=dofile(assert(debug.getinfo(1,'S').source:match('^@(.*/)'))..'shelf_progress_all_smoke.lua')
    bulk_smoke(plugin,books,count,control,wait_progress,evidence,cb)
    settings:update_auth({api_key="",cookies={wr_vid="900000",wr_skey="synthetic-web-progress"}},{replace_cookies=true})

    local a={bookId='990701',title='合成进度回填',finishReading=0,secret=1}
    local b={bookId='990702',title='合成稳定进度',finishReading=0}
    local grid_books={a,b}
    local function reset_grid_progress()
        assert(plugin.library_db:putShelfProgress({
            {book_id=a.bookId,percent=91,exact_percent=91,fetched_at=0},
            {book_id=b.bookId,percent=55,exact_percent=55,fetched_at=os.time()},
        }))
    end
    local function check_badge_repaint(view, gets)
        UIManager:forceRePaint()
        local first,second=view._item_rows[1],view._item_rows[2]
        assert(first._progress_badge_text=='91%' and first._has_private_badge
            and second._progress_badge_text=='55%')
        local old_badge,other_badge=first._progress_badge,second._progress_badge
        local repaint,set_dirty=UIManager.widgetRepaint,UIManager.setDirty
        local cells,regions=0,{}
        UIManager.widgetRepaint=function(ui,widget,...)
            if widget==first.frame or widget==second.frame then cells=cells+1 end
            return repaint(ui,widget,...)
        end
        UIManager.setDirty=function(ui,widget,mode,region,...)
            if not widget and mode=='ui' and region then regions[#regions+1]=region end
            return set_dirty(ui,widget,mode,region,...)
        end
        local ok,failure=pcall(wait_progress)
        UIManager.widgetRepaint,UIManager.setDirty=repaint,set_dirty
        assert(ok,failure)
        assert(plugin.shelf_view==view and cells==1 and #regions==1
            and count('/web/book/getProgress')==gets+1,'progress completion rebuilt the grid or repeated a request')
        local dimen=first.frame.dimen
        assert(regions[1].x==dimen.x and regions[1].y==dimen.y and regions[1].w==dimen.w and regions[1].h==dimen.h
            and first._progress_badge~=old_badge and first._progress_badge_text=='0%' and first._has_private_badge
            and second._progress_badge==other_badge,'progress completion redrew the wrong cell')
        local BB=require('ffi/blitbuffer')
        UIManager:forceRePaint()
        local partial=BB.tostring(Screen.bb)
        UIManager:setDirty(view,'ui',view.dimen);UIManager:forceRePaint()
        assert(partial==BB.tostring(Screen.bb),'progress repaint pixels differed from a full repaint')
        return {w=dimen.w,h=dimen.h}
    end
    shelf=settings:get('shelf');shelf.view_mode='cover';shelf.paginated=true;shelf.sort_order='default'
    settings:set('shelf',shelf)
    plugin:applyShelfSnapshot(grid_books,{})
    local old_filters=plugin.shelf_filters;plugin.shelf_filters={}
    reset_grid_progress()
    local gets=count('/web/book/getProgress')
    plugin:showShelfView('books')
    local shelf_region=check_badge_repaint(plugin.shelf_view,gets)
    plugin:closeWeReadUI()
    reset_grid_progress()
    local home=plugin:homePreferences();home.view_mode='cover'
    gets=count('/web/book/getProgress')
    plugin:showDiscoveryPage('home',grid_books,{title='合成进度验证',home=home})
    plugin:stopHomeStatusTimer()
    local home_region=check_badge_repaint(plugin.shelf_view,gets)
    plugin:closeWeReadUI()

    reset_grid_progress()
    shelf.sort_order='progress_desc';settings:set('shelf',shelf)
    gets=count('/web/book/getProgress')
    plugin:showShelfView('books')
    local sorted=plugin.shelf_view
    assert(sorted.books[1]==a)
    check_badge_repaint(sorted,gets)
    assert(sorted.books[1]==a and sorted.books[2]==b,'background progress reordered the open shelf')
    plugin:showShelfView('books',nil,sorted)
    assert(plugin.shelf_view.books[1]==b and plugin.shelf_view.books[2]==a,
        'reopened shelf did not sort by the saved percentage')
    local previous=plugin.shelf_view
    reset_grid_progress()
    shelf.sort_order='default';settings:set('shelf',shelf)
    plugin.shelf_filters={reading='progress_active'}
    plugin:showShelfView('books',nil,previous)
    local filtered=plugin.shelf_view
    assert(#filtered.books==2)
    wait_progress()
    assert(plugin.shelf_view~=filtered and #plugin.shelf_view.books==1 and plugin.shelf_view.books[1]==b,
        'shelf progress filter retained a book at zero')
    assert(count('/web/book/read')==writes,'visible progress sent a reading write')
    local grid_report=assert(io.open(evidence..'/shelf-progress-repaint.json','wb'))
    assert(grid_report:write(client:json_encode({shelf=shelf_region,home=home_region,pixels_equal=true,
        stable_order=true,sorted_on_reopen=true,filtered_again=true,reading_writes=0})))
    assert(grid_report:close())
    plugin:closeWeReadUI()
    plugin.shelf_filters=old_filters
    settings:update_auth({api_key=old_key,cookies=old_cookies},{replace_cookies=true})
    settings:set("shelf",client:json_decode(old_shelf));settings:flush()
    plugin:applyShelfSnapshot(plugin.library_db:getShelf(),plugin.library_db:getShelfArchives())
    print("PASS: keyless visible Web progress -> worker/HTTP/SQLite -> cover/list/home; pending-local priority, offline cache, one gateway fallback, rate backoff and Cookie race; no reading writes")
end
