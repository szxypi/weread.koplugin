-- Actual native widgets, child HTTP and session-bound bookstore pagination.
return function(plugin,count,flush_tasks,home,pump_until)
    local UIManager=require("ui/uimanager")
    local Screen=require("device").screen
    local http,ltn12=require("socket.http"),require("ltn12")
    local client,settings=plugin.client,plugin.settings
    local saved_key=settings:get("api_key")
    local covers=plugin.fetchVisibleShelfCovers
    plugin.fetchVisibleShelfCovers=function() end
    settings:set("api_key","");settings:flush()
    local function control(options)
        local bytes=client:json_encode(options)
        local _,code=http.request{url=settings.mock_endpoint.."/__control",proxy=settings.mock_endpoint,
            method="POST",source=ltn12.source.string(bytes),sink=ltn12.sink.null(),
            headers={["content-type"]="application/json",["content-length"]=#bytes}}
        assert(code==200)
    end
    local function press(view,label)
        for _,button in ipairs(view._action_buttons) do
            if button.text==require("weread.lib.i18n").tr(label) then button.callback();return end
        end
        error("missing native bookstore button: "..label)
    end
    local function wait() flush_tasks();pump_until(function() return not plugin.discovery_loading end) end
    local function paint(name)
        UIManager:forceRePaint();Screen:shot(home.."/../evidence/"..name..".png")
    end
    local writes=count("/web/book/read")
    local gateway=count("/api/agent/gateway","/store/search")
    plugin:showBookstore()
    press(plugin.shelf_view,"Search WeRead");flush_tasks()
    local input=UIManager:getTopmostVisibleWidget()
    assert(input.setInputText,"native search input missing")
    input:setInputText("测试作者")
    input.buttons[1][2].callback()
    wait()
    local state=assert(plugin.discovery_state)
    assert(state.kind=="search" and state.source_kind=="native" and #state.books==20 and state.has_more)
    assert(count("/api/agent/gateway","/store/search")==gateway,"keyless native search used gateway")
    paint("native-store-search")
    press(plugin.shelf_view,"Next batch");wait()
    assert(#plugin.discovery_state.books==6 and plugin.discovery_state.cursor==20 and not plugin.discovery_state.has_more)
    paint("native-store-search-last")
    press(plugin.shelf_view,"Previous batch");wait()
    assert(plugin.discovery_state.cursor==0 and #plugin.discovery_state.history==0)
    local seed=plugin.discovery_state.books[1]
    plugin:showBookMenu(seed);press(plugin._book_detail_view,"Similar books");wait()
    state=plugin.discovery_state
    assert(state.source_kind=="native" and state.kind=="similar" and #state.books==20 and state.session_id~="")
    local session=state.session_id
    paint("native-store-similar")
    press(plugin.shelf_view,"Next batch");wait()
    assert(#plugin.discovery_state.books==5 and plugin.discovery_state.session_id==session)
    press(plugin.shelf_view,"Previous batch");wait()
    assert(plugin.discovery_state.session_id==session and #plugin.discovery_state.history==0)
    press(plugin.shelf_view,"For you");wait()
    assert(plugin.discovery_state.kind=="recommend" and plugin.discovery_state.source_kind=="native" and #plugin.discovery_state.books==20)
    paint("native-store-recommend")
    press(plugin.shelf_view,"Next batch");wait()
    assert(#plugin.discovery_state.books==6 and not plugin.discovery_state.has_more)

    -- The parent event loop remains responsive while the real HTTP child waits.
    control{match="/book/recommend",delay=0.6,times=0}
    local heartbeat=false
    plugin:loadDiscoveryBatch("recommend",nil,0)
    UIManager:scheduleIn(0.1,function() heartbeat=true end)
    pump_until(function() return heartbeat end)
    assert(plugin.discovery_loading and plugin.discovery_worker.job,"bookstore HTTP blocked UI heartbeat")
    local saved=plugin.discovery_state
    plugin:closeWeReadUI()
    assert(not plugin.discovery_loading and not plugin.discovery_worker.job,"closing UI did not cancel bookstore child")
    flush_tasks()
    assert(plugin.discovery_state==saved and not plugin.shelf_view,"cancelled child reopened bookstore")
    control{match="",delay=0,times=0}
    plugin:showBookstore()

    -- Closing a seed's details also kills an already running similar request.
    control{match="/book/detailinfo",delay=0.6,times=0}
    plugin:showBookMenu(seed)
    local detail=plugin._book_detail_view
    press(detail,"Similar books")
    pump_until(function() return plugin.discovery_worker.job~=nil end)
    detail:onClose()
    assert(not plugin.discovery_loading and not plugin.discovery_worker.job,"closing seed details retained similar child")
    UIManager:close(detail)
    flush_tasks()
    assert(plugin.discovery_state==saved,"closed seed applied similar result")
    control{match="",delay=0,times=0}

    -- First-page safe fallback binds later pages to Skill; 429 retains cache.
    settings:set("api_key",saved_key);settings:flush()
    control{match="/store/search",delay=0,times=1,status=503}
    plugin:loadDiscoveryBatch("search","测试作者",0);wait()
    assert(plugin.discovery_state.source_kind=="gateway" and #plugin.discovery_state.books==20)
    press(plugin.shelf_view,"Next batch");wait()
    assert(plugin.discovery_state.source_kind=="gateway" and #plugin.discovery_state.books==6)
    saved=plugin.discovery_state
    local gateway_before=count("/api/agent/gateway","/book/recommend")
    control{match="/book/recommend",delay=0,times=1,status=429}
    plugin:loadDiscoveryBatch("recommend",nil,0);wait()
    assert(plugin.discovery_state==saved and count("/api/agent/gateway","/book/recommend")==gateway_before,"rate failure fell back or discarded cache")
    UIManager:close(UIManager:getTopmostVisibleWidget())
    control{match="",delay=0,times=0}
    plugin:closeWeReadUI()
    plugin.discovery_state=nil
    plugin.fetchVisibleShelfCovers=covers
    assert(count("/web/book/read")==writes,"bookstore wrote reading state")
    print("PASS: keyless native bookstore search/input 20+6 -> similar 20+5/session/back -> recommendations 20+6 -> heartbeat/cancel -> safe first-page fallback/bound continuation/429 cache; native widgets only")
end
