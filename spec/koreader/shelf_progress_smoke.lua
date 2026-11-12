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
    paint("web-shelf-progress-cover")
    before=count("/web/book/getProgress")
    plugin.shelf_view.on_page_changed(2)
    wait_progress()
    assert(count("/web/book/getProgress")>before,"second keyless page did not refresh")
    plugin.shelf_view.on_page_changed(1)
    plugin.isNetworkOnline=function() return false end
    plugin.shelf_view.on_display_change("view_mode","list")
    assert(plugin.shelf_view:itemStatus(plugin.shelf_view.books[1]):find("83%%"),"offline Web list lost local override")
    paint("web-shelf-progress-list")
    plugin.isNetworkOnline=function() return true end
    plugin:closeWeReadUI()
    expires({books[1]})
    plugin:showHome()
    wait_progress()
    assert(progress(seed).source=="web" and progress(seed).percent==37,"keyless home did not refresh")
    assert(plugin.shelf_view.books[1]._shelf_progress==83,"keyless home lost pending location")
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
    plugin:closeWeReadUI()
    settings:update_auth({api_key=old_key,cookies=old_cookies},{replace_cookies=true})
    settings:set("shelf",client:json_decode(old_shelf));settings:flush()
    print("PASS: keyless visible Web progress -> worker/HTTP/SQLite -> cover/list/home; pending-local priority, offline cache, one gateway fallback, rate backoff and Cookie race; no reading writes")
end
