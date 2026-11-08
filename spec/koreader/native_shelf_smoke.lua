-- Read-only native/gateway shelf routing through real menus, fork/pipe, HTTP
-- and SQLite. Synthetic credentials are supplied by the authorization smoke.
return function(plugin, count, flush_tasks, home, pump_until)
    local UIManager = require("ui/uimanager")
    local Screen = require("device").screen
    local http, ltn12 = require("socket.http"), require("ltn12")
    local client, settings = plugin.client, plugin.settings
    local controller = plugin.native_authorization
    local endpoint = settings.mock_endpoint
    local capacity_result
    local capacity_worker = require("weread.lib.memory_worker"):new{
        scheduler = UIManager, codec = client, max_bytes = 8 * 1024 * 1024,
    }
    assert(capacity_worker:start(function() return { metadata = string.rep("x", 150000) } end,
        function(value) capacity_result = value end), "shelf capacity worker unavailable")
    pump_until(function() return capacity_result ~= nil end)
    assert(#capacity_result.metadata == 150000 and not capacity_worker.job, "shelf-sized pipe payload truncated")
    local source_painted = false
    local function control(options)
        local bytes = client:json_encode(options)
        local _, code = http.request{ url = endpoint .. "/__control", proxy = endpoint,
            method = "POST", source = ltn12.source.string(bytes), sink = ltn12.sink.null(),
            headers = { ["content-type"] = "application/json", ["content-length"] = #bytes } }
        assert(code == 200, "synthetic control failed")
    end
    local function choose(index, expected)
        controller:chooseSource()
        local menu = UIManager:getTopmostVisibleWidget()
        if not source_painted then
            UIManager:forceRePaint()
            Screen:shot(home .. "/../evidence/native-shelf-source.png")
            source_painted = true
        end
        menu.buttons[index][1].callback()
        assert(require("weread.lib.shelf_source").mode(settings) == expected, "source menu did not persist")
        UIManager:close(UIManager:getTopmostVisibleWidget())
    end
    local function refresh(expect_success)
        local loaded = false
        plugin:refreshBookshelf(nil, { on_loaded = function() loaded = true end })
        assert(plugin.shelf_refreshing and plugin.shelf_refresh_worker.job, "shelf did not start asynchronously")
        pump_until(function() return not plugin.shelf_refreshing end)
        assert(loaded == expect_success, "unexpected shelf refresh result")
        if not expect_success then UIManager:close(UIManager:getTopmostVisibleWidget()) end
    end
    local web_writes = count("/web/book/read")
    local gateway = count("/api/agent/gateway", "/shelf/sync")
    refresh(true)
    assert(plugin.shelf_active_source == "native" and count("/api/agent/gateway", "/shelf/sync") == gateway,
        "automatic shelf did not use saved E-Ink authorization")
    assert(#plugin.shelf_regular == 26 and #plugin.shelf_groups == 3, "native books/groups were not projected")
    local cached = plugin.library_db:getShelf()
    assert(cached[1]._native_version == 700 and cached[1].bookVersion == nil and cached[1].version == nil,
        "native version became a Web download source version")
    plugin:showShelfView("books")
    flush_tasks()
    UIManager:forceRePaint()
    Screen:shot(home .. "/../evidence/native-shelf.png")
    plugin.shelf_view.on_display_change("view_mode", "cover")
    pump_until(function()
        local progress = plugin.shelf_progress_context
        return not plugin.shelf_cover_job and not plugin.shelf_cover_pending and not (progress and progress.request)
    end)
    assert(plugin.shelf_view.cover_mode and plugin.shelf_view.scroll.dimen.y > 0
        and plugin.shelf_view.scroll.dimen.y + plugin.shelf_view.scroll.dimen.h < Screen:getHeight(),
        "native cover grid overlaps fixed navigation")
    assert(plugin:getShelfCoverCache():pathFor(plugin.shelf_regular[1]), "native cover image was not cached")
    UIManager:setDirty(plugin.shelf_view, "full")
    UIManager:forceRePaint()
    Screen:shot(home .. "/../evidence/native-shelf-cover.png")
    plugin:closeWeReadUI()
    choose(3, "native")
    local api_key = settings:get("api_key")
    settings:set("api_key", "") settings:flush()
    refresh(true)
    assert(plugin.shelf_active_source == "native" and count("/api/agent/gateway", "/shelf/sync") == gateway,
        "native-only source required a gateway key")
    control{ match = "/shelf/sync", times = 1, status = 401, delay = 0 }
    refresh(false)
    assert(count("/api/agent/gateway", "/shelf/sync") == gateway and #plugin.library_db:getShelf() == 26,
        "native-only failure silently switched source or erased cache")
    settings:set("api_key", api_key) settings:flush()
    choose(1, "auto")
    control{ match = "/shelf/sync", times = 1, status = 401, delay = 0 }
    refresh(true)
    assert(plugin.shelf_active_source == "gateway" and count("/api/agent/gateway", "/shelf/sync") == gateway + 1,
        "automatic source did not fall back once")
    assert(plugin.library_db:getShelf()[1].bookVersion == 7, "gateway metadata did not survive fallback")
    local native_before = count("/shelf/sync")
    choose(2, "gateway")
    refresh(true)
    assert(count("/shelf/sync") == native_before, "standard source also contacted native shelf")
    choose(3, "native")
    control{ match = "/shelf/sync", times = 0, delay = 0.6 }
    local applied = false
    plugin:refreshBookshelf(nil, { on_loaded = function() applied = true end })
    assert(plugin.busy_message.dismissable and plugin.shelf_refresh_worker.job, "refresh cannot be dismissed")
    require("socket").sleep(0.1)
    plugin.busy_message:onTapClose()
    assert(not plugin.shelf_refreshing and not plugin.shelf_refresh_worker.job, "dismiss retained shelf job")
    local until_time = require("socket").gettime() + 0.7
    while require("socket").gettime() < until_time do flush_tasks() require("socket").sleep(0.01) end
    assert(not applied and plugin.library_db:getShelf()[1].bookVersion == 7, "cancelled native read replaced gateway cache")
    control{ match = "", times = 0, delay = 0 }
    choose(1, "auto")
    assert(count("/web/book/read") == web_writes, "native shelf routing wrote reading state")
    print("PASS: native shelf automatic/standard/native-only -> real async HTTP -> groups/SQLite; no gateway key required; failure fallback/cache and dismiss verified")
end
