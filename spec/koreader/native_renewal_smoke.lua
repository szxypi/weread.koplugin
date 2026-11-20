-- Actual parent-only token commits and fork/pipe authentication. All traffic
-- and tokens belong to the isolated synthetic account; no real account writes.
return function(plugin, count, flush_tasks, home, pump_until)
    local UIManager = require("ui/uimanager")
    local Screen = require("device").screen
    local service, controller = plugin.native_renewal, plugin.native_authorization
    local client, settings = plugin.client, plugin.settings
    local http, ltn12 = require("socket.http"), require("ltn12")
    local function control(options)
        local bytes = client:json_encode(options)
        local _, code = http.request{ url = settings.mock_endpoint .. "/__control", proxy = settings.mock_endpoint,
            method = "POST", source = ltn12.source.string(bytes), sink = ltn12.sink.null(),
            headers = { ["content-type"] = "application/json", ["content-length"] = #bytes } }
        assert(code == 200, "native renewal mock control failed")
    end
    local function close_info() UIManager:close(UIManager:getTopmostVisibleWidget()) end
    local store = require("weread.lib.native_credentials"):new(settings)
    local before, revision = store:read()
    local device = before.deviceId
    local posts = count("/login", "native_renewal")
    local data_writes = count("/web/book/read")
    controller:showMenu()
    UIManager:getTopmostVisibleWidget().buttons[2][1].callback()
    assert(service.job and store:read(), "manual renewal did not start")
    local initial_credentials, pending_revision, err, pending = store:read()
    assert(initial_credentials and not err and pending and pending_revision == revision + 1, "intent was not durable before HTTP completion")
    pump_until(function() return service.job == nil end)
    local saved, saved_revision
    saved, saved_revision, err, pending = store:read()
    assert(saved and not err and not pending and saved_revision == revision + 2 and saved.deviceId == device
        and saved.refreshToken == before.refreshToken, "real local save did not preserve verified omitted refresh token")
    assert(count("/login", "native_renewal") == posts + 1, "manual renewal repeated POST")
    flush_tasks()
    UIManager:forceRePaint()
    Screen:shot(home .. "/../evidence/native-renewal-saved.png")
    close_info()
    control{ match = "/shelf/sync", times = 1, status = 401, delay = 0 }
    local loaded = false
    plugin:refreshBookshelf(nil, { on_loaded = function() loaded = true end })
    pump_until(function() return not plugin.shelf_refreshing end)
    assert(loaded and plugin.shelf_active_source == "native" and count("/login", "native_renewal") == posts + 2,
        "HTTP 401 did not recover with exactly one renewal and native re-fetch")
    saved, revision, err, pending = store:read()
    assert(saved and not err and not pending and revision == saved_revision + 2, "automatic renewal did not commit credentials")
    control{ match = "/login", times = 0, delay = 0.6 }
    controller:renew()
    assert(service.job and controller.dialog, "cancellable renewal did not start")
    require("socket").sleep(0.1)
    controller.dialog:onTapClose()
    assert(not service.job, "dismissed renewal retained worker")
    local cancelled_revision
    saved, cancelled_revision, err, pending = require("weread.lib.native_credentials"):new(settings):read()
    assert(saved and not err and pending and cancelled_revision == revision + 1, "cancelled renewal lost durable uncertainty marker")
    local reopened = require("weread.lib.native_renewal"):new{ settings = settings, client = client, scheduler = UIManager }
    local started, reason = reopened:start({}, function() error("unconfirmed token replayed") end)
    assert(not started and reason == "renewal_unconfirmed", "new service instance replayed pending renewal")
    local deadline = require("socket").gettime() + 0.7
    while require("socket").gettime() < deadline do flush_tasks() require("socket").sleep(0.01) end
    local after_cancel = count("/login", "native_renewal")
    assert(after_cancel <= posts + 3, "cancelled renewal issued another POST")
    assert(not reopened:start({}, function() error("pending renewal retried") end))
    assert(count("/login", "native_renewal") == after_cancel, "durable pending marker did not stop new dispatch")
    control{ match = "", times = 0, delay = 0 }
    assert(count("/web/book/read") == data_writes, "native renewal uploaded reading state")
    print("PASS: native renewal menu -> durable intent -> signed POST -> shelf verification/local readback; HTTP 401 recovery once; cancel/reopen cannot replay")
end
