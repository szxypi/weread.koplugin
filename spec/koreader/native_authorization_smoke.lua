-- Actual QR widget, asynchronous fork/pipe, Client, LuaSettings and reopen.
-- All traffic and saved tokens belong to the fail-closed synthetic account.
return function(plugin, request_count, flush_tasks, home)
    local UIManager = require("ui/uimanager")
    local Screen = require("device").screen
    local socket = require("socket")
    local controller = plugin.native_authorization
    local function pump_until(predicate)
        local deadline = socket.gettime() + 35
        while not predicate() do
            assert(socket.gettime() < deadline, "native authorization runtime deadline")
            flush_tasks()
            socket.sleep(0.01)
        end
    end
    local function close_info()
        local top = UIManager:getTopmostVisibleWidget()
        if top ~= plugin.ui then UIManager:close(top) end
    end
    local writes_before = request_count("/web/book/read")
    local native_logins = request_count("/login")
    local pipe_worker = require("weread.lib.memory_worker"):new{ scheduler = UIManager, codec = plugin.client }
    local large_result, responsive = nil, false
    assert(pipe_worker:start(function()
        socket.sleep(0.35)
        return { private = string.rep("x", 25000) }
    end, function(value) large_result = value end), "large-result worker did not start")
    UIManager:scheduleIn(0.1, function() responsive = true end)
    pump_until(function() return responsive end)
    assert(not large_result, "UI task did not run while child was waiting")
    pump_until(function() return large_result ~= nil end)
    assert(#large_result.private == 25000 and not pipe_worker.job, "large pipe frame was truncated or leaked")
    assert(pipe_worker:start(function() socket.sleep(30) return {} end, function() error("cancelled child applied") end))
    pipe_worker:cancel()
    assert(not pipe_worker.job, "immediate child cancellation retained job")
    local entry
    for _, item in ipairs(plugin:getMainMenuItems()) do
        if item.text == require("weread.lib.i18n").tr("E-Ink authorization") then entry = item break end
    end
    assert(entry, "native authorization menu entry missing")
    entry.callback()
    local menu = UIManager:getTopmostVisibleWidget()
    assert(menu.buttons and #menu.buttons == 4, "native authorization menu not shown")
    menu.buttons[1][1].callback()
    pump_until(function()
        return controller.dialog and controller.dialog.text:find("https://open.weixin.qq.com/connect/confirm?", 1, true)
    end)
    Screen:shot(home .. "/../evidence/native-auth-qr.png")
    controller.dialog:onTapClose()
    assert(not controller.auth and not controller.worker.job and not controller.store:read(), "QR cancellation retained a grant")
    assert(request_count("/login") == native_logins, "dismissed QR attempted native login")

    -- A UI task can run while the real child request is outstanding.
    local heartbeat = false
    controller:start()
    UIManager:scheduleIn(0.1, function() heartbeat = true end)
    pump_until(function() return controller.auth == nil end)
    assert(heartbeat and not controller.worker.job, "authorization blocked UI scheduling")
    local Credentials = require("weread.lib.native_credentials")
    local fresh = Credentials:new(plugin.settings)
    local saved = assert(fresh:read(), "native grant did not survive primary-file reopen")
    assert(saved.vid == "900000" and saved.book_count == 26 and #saved.deviceId == 32, "saved native grant contract")
    Screen:shot(home .. "/../evidence/native-auth-saved.png")
    close_info()
    -- Inspect from a new real Settings instance, rather than the saving object.
    local reopened = require("weread.lib.settings"):new()
    assert(Credentials:new(reopened):read(), "new Settings instance lost native grant")
    controller:showMenu()
    menu = UIManager:getTopmostVisibleWidget()
    assert(menu.buttons[2][1].enabled, "saved grant did not enable clear button")
    flush_tasks()
    Screen:shot(home .. "/../evidence/native-auth-menu.png")
    UIManager:close(menu)
    local fixtures = debug.getinfo(1, "S").source:match("^@(.*/)")
    dofile(fixtures .. "native_shelf_smoke.lua")(plugin, request_count, flush_tasks, home, pump_until)
    controller:clear()
    assert(not Credentials:new(reopened):read(), "cleared grant survived disk reopen")
    flush_tasks()
    Screen:shot(home .. "/../evidence/native-auth-cleared.png")
    close_info()
    local loaded = false
    plugin:refreshBookshelf(nil, { on_loaded = function() loaded = true end })
    pump_until(function() return not plugin.shelf_refreshing end)
    assert(loaded and plugin.shelf_active_source == "gateway", "cleared native grant blocked ordinary automatic shelf refresh")
    assert(request_count("/login") == native_logins + 1, "authorization repeated native login")
    assert(request_count("/web/book/read") == writes_before, "native authorization wrote Web reading state")
    print("PASS: native authorization QR dismiss -> responsive fork/25 KiB pipe and immediate cancel -> verified grant -> primary-file/new Settings reopen -> clear; no Web writes")
end
