-- Actual HTTP 401 -> durable renewal -> same native page/metadata request.
return function(plugin,count,flush_tasks,home,pump_until)
    local UIManager=require("ui/uimanager")
    local Screen=require("device").screen
    local socket,http,ltn12=require("socket"),require("socket.http"),require("ltn12")
    local settings,client=plugin.settings,plugin.client
    local store=plugin.native_authorization.store
    local previous_key=settings:get("api_key")
    local covers=plugin.fetchVisibleShelfCovers
    plugin.fetchVisibleShelfCovers=function() end
    settings:set("api_key","");settings:flush()
    local books=settings:get("books",{})
    local id="900022"
    local previous=books[id]
    books[id]={book_id=id,title="Cached renewal metadata",progress=83,bookVersion=47}
    settings:set("books",books);settings:flush()
    local function control(value)
        local body=client:json_encode(value)
        local _,code=http.request{url=settings.mock_endpoint.."/__control",proxy=settings.mock_endpoint,method="POST",
            source=ltn12.source.string(body),sink=ltn12.sink.null(),headers={["content-type"]="application/json",["content-length"]=#body}}
        assert(code==200)
    end
    local function wait() flush_tasks();pump_until(function() return not plugin.discovery_loading and not plugin.book_metadata_context end) end
    local writes=count("/web/book/read")
    local posts=count("/login","native_renewal")
    plugin:closeWeReadUI();plugin:showBookMenu(settings:get("books",{})[id])
    control{match="/book/info",times=1,status=401,delay=0}
    plugin._book_detail_view._refresh_button.callback();wait()
    local cached=settings:get("books",{})[id]
    assert(cached.detail_source=="native" and cached.wordCount==12000 and cached.progress==83 and cached.bookVersion==47
        and count("/login","native_renewal")==posts+1,"metadata 401 did not renew once and retain local state")
    UIManager:forceRePaint();Screen:shot(home.."/../evidence/native-read-renewed-metadata.png")
    plugin:closeWeReadUI()
    control{match="/store/search",times=1,status=401,delay=0}
    plugin:loadDiscoveryBatch("search","测试作者",0);wait()
    assert(plugin.discovery_state.source_kind=="native" and #plugin.discovery_state.books==20
        and count("/login","native_renewal")==posts+2,"keyless search did not recover 401")
    local state=plugin.discovery_state
    control{match="/store/search",times=1,status=401,delay=0}
    plugin:loadDiscoveryBatch("search",state.keyword,state.next_cursor,false,false,state);wait()
    assert(plugin.discovery_state.source_kind=="native" and #plugin.discovery_state.books==6 and plugin.discovery_state.history[1]==0
        and count("/login","native_renewal")==posts+3,"search continuation lost its cursor after owned renewal")
    plugin:showSimilarBooks({bookId=id,title="Synthetic seed"});wait()
    state=plugin.discovery_state
    local session=state.session_id
    control{match="/book/detailinfo",times=1,status=401,delay=0}
    plugin:loadDiscoveryBatch("similar",nil,state.next_cursor,false,false,state);wait()
    assert(plugin.discovery_state.source_kind=="native" and plugin.discovery_state.session_id==session
        and #plugin.discovery_state.books==5 and count("/login","native_renewal")==posts+4,"similar continuation lost its session after renewal")
    UIManager:forceRePaint();Screen:shot(home.."/../evidence/native-read-renewed-similar.png")
    settings:set("api_key",previous_key);settings:flush()
    control{match="/store/search",times=2,status=401,delay=0}
    plugin:loadDiscoveryBatch("search","测试作者",0);wait()
    assert(count("/login","native_renewal")==posts+5 and plugin.discovery_state.source_kind=="gateway",
        "persistent 401 renewed more than once or lost first-page fallback")
    local stable=plugin.discovery_state
    control{match="/store/search",times=1,status=429,delay=0}
    plugin:loadDiscoveryBatch("search","测试作者",0);wait()
    assert(plugin.discovery_state==stable and count("/login","native_renewal")==posts+5,"429 renewed or replaced cached books")
    UIManager:close(UIManager:getTopmostVisibleWidget())

    -- Delay every request: only the first native read fails; renewal then
    -- remains observable while the real reader receives its suspend event.
    control{match="",times=1,status=401,delay=0.6}
    plugin:loadDiscoveryBatch("search","测试作者",0)
    pump_until(function() return plugin.discovery_request_context and plugin.discovery_request_context.renewing end)
    assert(plugin.native_renewal.job and plugin.discovery_loading,"pending renewal was not observable")
    plugin:onSuspend()
    assert(not plugin.discovery_loading and not plugin.discovery_request_context and not plugin.native_renewal.job
        and not plugin.busy_message,"reader suspend retained bookstore renewal/busy state")
    local _,_,_,pending=store:read()
    assert(pending,"cancelled renewal lost its uncertainty marker")
    control{match="",times=0,delay=0}
    plugin:onResume()
    local deadline=socket.gettime()+0.8
    while socket.gettime()<deadline do flush_tasks();socket.sleep(0.01) end
    assert(plugin.discovery_state==stable and not plugin.discovery_loading,"late renewal reopened a suspended request")
    local cancelled_posts=count("/login","native_renewal")
    control{match="/store/search",times=1,status=401,delay=0}
    plugin:loadDiscoveryBatch("search","测试作者",0);wait()
    assert(count("/login","native_renewal")==cancelled_posts and plugin.discovery_state.source_kind=="gateway",
        "pending renewal was replayed by a subsequent read")
    control{match="",times=0,delay=0}
    -- A fresh synthetic owner authorization resolves the intentionally
    -- uncertain grant before the independent manual-renewal test follows.
    local qr_posts=count("/login","native_qr")
    plugin.native_authorization:start()
    pump_until(function() return not plugin.native_authorization.auth end)
    local saved,_,err,uncertain=store:read()
    assert(saved and not err and not uncertain and count("/login","native_qr")==qr_posts+1,"fresh authorization did not resolve uncertainty")
    UIManager:close(UIManager:getTopmostVisibleWidget())
    plugin:closeWeReadUI();plugin.discovery_state=nil
    plugin.fetchVisibleShelfCovers=covers
    books=settings:get("books",{});books[id]=previous;settings:set("books",books);settings:flush()
    assert(count("/web/book/read")==writes,"native read recovery wrote reading state")
    print("PASS: metadata/search/native continuation 401 -> one durable renewal -> same source/session; persistent 401 fallback, 429 cache, actual suspend/cancel/late receipt/pending-no-replay and fresh owner authorization")
    return 1
end
