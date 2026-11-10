-- Real native metadata GET, widget text, bounded worker and account SQLite.
return function(plugin,count,flush_tasks,home,pump_until)
    local UIManager=require("ui/uimanager")
    local Screen=require("device").screen
    local http,ltn12=require("socket.http"),require("ltn12")
    local settings,client=plugin.settings,plugin.client
    local store=plugin.native_authorization.store
    local saved_key=settings:get("api_key")
    local id="900024"
    local books=settings:get("books",{})
    local previous=books[id]
    books[id]={book_id=id,title="Cached native metadata",progress=83,chapter_uid=99,chapter_offset=123,bookVersion=47,
        pending_upload_position={book_id=id,percent=83},pending_upload_account=plugin.library_db:accountKey()}
    settings:set("books",books);settings:set("api_key","");settings:flush()
    local reader_path=require("weread.lib.protocol").reader_url(id):match("^https://[^/]+([^?]+)")
    local writes=count("/web/book/read")
    local progress=count("/web/book/getProgress")+count("/api/agent/gateway","/book/getprogress")
    local gateway,web=count("/api/agent/gateway","/book/info"),count(reader_path)
    local function control(value)
        local body=client:json_encode(value)
        local _,code=http.request{url=settings.mock_endpoint.."/__control",proxy=settings.mock_endpoint,method="POST",
            source=ltn12.source.string(body),sink=ltn12.sink.null(),
            headers={["content-type"]="application/json",["content-length"]=#body}}
        assert(code==200)
    end
    local function cached() return settings:get("books",{})[id] end
    local function refresh()
        plugin._book_detail_view._refresh_button.callback()
        assert(plugin.book_metadata_context and plugin.book_metadata_worker.job,"native metadata did not start in child")
    end
    local function wait() pump_until(function() return not plugin.book_metadata_context end);flush_tasks() end
    plugin:closeWeReadUI();plugin:showBookMenu(cached())
    control{match="/book/info",times=0,delay=0.5}
    refresh()
    local heartbeat=false
    UIManager:scheduleIn(0.1,function() heartbeat=true end)
    pump_until(function() return heartbeat end)
    assert(plugin.book_metadata_context,"native metadata blocked UI heartbeat")
    books=settings:get("books",{});books[id].progress=84;books[id].chapter_uid=100
    settings:set("books",books);settings:flush()
    wait()
    local value=cached()
    assert(value.detail_source=="native" and value.publisher=="合成出版社" and value.wordCount==12000 and value.newRating==860,
        "native metadata or totalWords display projection missing")
    assert(value.progress==84 and value.chapter_uid==100 and value.chapter_offset==123 and value.bookVersion==47
        and value.pending_upload_position.percent==83 and value.version==nil and value.totalWords==nil,
        "native metadata replaced current local reader state or source version")
    assert(count("/api/agent/gateway","/book/info")==gateway and count(reader_path)==web,"healthy native metadata fetched fallback pages")
    local persisted=assert(plugin.library_db:getBook(id))
    assert(persisted.detail_source=="native" and persisted.wordCount==12000,"native metadata not persisted in account SQLite")
    local view=assert(plugin._book_detail_view)
    assert(view[1][1]:getSize().h==Screen:getHeight() and view.data.metadata and #view.data.metadata>=3,"native metadata viewport missing")
    UIManager:forceRePaint();Screen:shot(home.."/../evidence/native-eink-book-metadata.png")

    -- A new grant revision invalidates both child and parent callbacks.
    books=settings:get("books",{});books[id].detail_updated_at=1000;settings:set("books",books);settings:flush()
    refresh()
    local credentials,revision=store:read()
    assert(store:save(credentials,settings:get_auth_scope(),revision,credentials.book_count))
    wait()
    assert(cached().detail_updated_at==1000,"replaced native authorization committed old metadata")
    refresh();plugin.busy_message:onTapClose()
    assert(not plugin.book_metadata_context and not plugin.book_metadata_worker.job,"cancelled native metadata retained child")
    refresh();plugin._book_detail_view:onClose()
    assert(not plugin.book_metadata_context and not plugin.book_metadata_worker.job and not plugin._book_detail_view
        and not plugin.busy_message,"closed details retained native metadata child, view or busy dialog")
    UIManager:forceRePaint()
    assert(UIManager:getTopmostVisibleWidget()~=view,"closed metadata details stayed on the widget stack")
    plugin:showBookMenu(cached())

    control{match="/book/info",times=1,status=503,delay=0}
    refresh();wait()
    assert(cached().detail_source=="web" and count(reader_path)==web+1,"keyless native failure did not fall back to Web")
    settings:set("api_key",saved_key);settings:flush()
    control{match="/book/info",times=1,status=503,delay=0}
    refresh();wait()
    assert(cached().detail_source=="gateway" and count("/api/agent/gateway","/book/info")==gateway+1,"native failure did not prefer configured Skill fallback")
    local updated=cached().detail_updated_at
    web=count(reader_path);gateway=count("/api/agent/gateway","/book/info")
    control{match="/book/info",times=1,status=429,delay=0}
    refresh();wait()
    assert(cached().detail_updated_at==updated and plugin._book_detail_view and count(reader_path)==web
        and count("/api/agent/gateway","/book/info")==gateway,"native rate limit discarded cache or fanned out")
    assert(count("/web/book/read")==writes
        and count("/web/book/getProgress")+count("/api/agent/gateway","/book/getprogress")==progress,"native metadata queried or wrote reading progress")
    control{match="",times=0,delay=0}
    plugin:closeWeReadUI()
    local numeric_id=id
    id='CB_SyntheticMetadata'
    books=settings:get('books',{});local previous_cb=books[id]
    books[id]={book_id=id,title='Cached CB details',progress=83,chapter_uid=99,chapter_offset=123,bookVersion=47,
        pending_upload_position={book_id=id,percent=83},pending_upload_account=plugin.library_db:accountKey()}
    settings:set('books',books);settings:set('api_key',saved_key);settings:flush()
    reader_path=require('weread.lib.protocol').reader_url(id):match('^https://[^/]+([^?]+)')
    local cb_gateway,cb_web=count('/api/agent/gateway','/book/info'),count(reader_path)
    plugin:showBookMenu(cached())
    control{match='/book/info',times=0,delay=0.5}
    refresh()
    local cb_heartbeat=false
    UIManager:scheduleIn(0.1,function() cb_heartbeat=true end)
    pump_until(function() return cb_heartbeat end)
    assert(plugin.book_metadata_context,'CB metadata blocked the native event loop')
    books=settings:get('books',{});books[id].progress=84;books[id].chapter_uid=100
    settings:set('books',books);settings:flush();wait()
    assert(cached().detail_source=='native' and cached().title=='CB 编号合成详情' and cached().wordCount==12000,
        'CB native metadata was not shown')
    assert(cached().progress==84 and cached().chapter_uid==100 and cached().chapter_offset==123
        and cached().bookVersion==47 and cached().pending_upload_position.percent==83,'CB metadata replaced local reading state')
    assert(plugin.library_db:getBook(id).detail_source=='native','CB metadata did not reach SQLite')
    assert(plugin._book_detail_view[1][1]:getSize().h==Screen:getHeight(),'CB metadata viewport exceeded the screen')
    UIManager:forceRePaint();Screen:shot(home..'/../evidence/cb-native-book-metadata.png')
    control{match='/book/info',times=1,status=503,delay=0}
    refresh();wait()
    assert(cached().detail_source=='web' and count(reader_path)==cb_web+1
        and count('/api/agent/gateway','/book/info')==cb_gateway,'CB fallback used an unverified gateway route')
    UIManager:forceRePaint();Screen:shot(home..'/../evidence/cb-web-book-metadata.png')
    control{match='/book/info',times=0,delay=0.5}
    local cb_updated=cached().detail_updated_at
    refresh();plugin.busy_message:onTapClose()
    assert(not plugin.book_metadata_context and not plugin.book_metadata_worker.job and cached().detail_updated_at==cb_updated,
        'CB cancellation retained a worker or committed stale metadata')
    assert(count('/web/book/read')==writes
        and count('/web/book/getProgress')+count('/api/agent/gateway','/book/getprogress')==progress,'CB metadata touched reading endpoints')
    control{match='',times=0,delay=0};plugin:closeWeReadUI()
    local report=assert(io.open(home..'/../evidence/cb-metadata-ui.json','wb'))
    assert(report:write(client:json_encode({native_metadata_verified=true,web_fallback_verified=true,gateway_skipped=true,
        ui_heartbeat_verified=true,sqlite_verified=true,local_reader_state_preserved=true,cancelled_worker_reaped=true,
        reading_requests_unchanged=true})));assert(report:close())
    books=settings:get('books',{});books[id]=previous_cb;settings:set('books',books)
    id=numeric_id
    books=settings:get("books",{});books[id]=previous;settings:set("books",books);settings:flush()
    print("PASS: keyless native metadata GET -> responsive worker -> totalWords/publisher/rating/native details/SQLite; grant revision/cancel/close; Skill/Web fallback and 429 cache; local reading state preserved")
end
