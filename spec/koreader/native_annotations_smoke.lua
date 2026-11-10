-- Installed plugin, native chapter picker, real child HTTP/SQLite/CRE/overlay.
-- Every account, text and credential here belongs to the isolated mock.
return function(plugin, count, flush, home, pump_until)
    local UI = require("ui/uimanager")
    local Screen = require("device").screen
    local socket, http, ltn12 = require("socket"), require("socket.http"), require("ltn12")
    local settings, client, reader = plugin.settings, plugin.client, plugin.ui
    local saved_key, saved_page = settings:get("api_key"), reader:getCurrentPage()
    settings:set("api_key", ""); settings:flush()
    local writes, renewals = count("/web/book/read"), count("/login", "native_renewal")
    local gateway = count("/api/agent/gateway", "/book/underlines") + count("/api/agent/gateway", "/book/readreviews")
    local function control(value)
        local body = client:json_encode(value)
        local _, code = http.request { url = settings.mock_endpoint .. "/__control", proxy = settings.mock_endpoint, method = "POST",
            source = ltn12.source.string(body), sink = ltn12.sink.null(),
            headers = { ["Content-Type"] = "application/json", ["Content-Length"] = #body } }
        assert(code == 200)
    end
    local function dismiss()
        local top = UI:getTopmostVisibleWidget()
        if top and getmetatable(top) == require("ui/widget/infomessage") then UI:close(top) end
    end
    local function shot(name)
        UI:forceRePaint(); Screen:shot(home .. "/../evidence/" .. name .. ".png")
    end
    local function select_and_fetch()
        dismiss()
        local picker = assert(plugin:chooseAnnotationChapters())
        assert(picker.model.by_uid["1"] and picker.model.count == 0)
        local target = picker.model.by_uid["1"]
        assert(target.selectable)
        local position
        for index, node in ipairs(picker.model:visible()) do if node == target then position = index break end end
        assert(position)
        picker.page = math.floor((position - 1) / picker.per_page) + 1
        picker:rebuild()
        picker.layout[(position - 1) % picker.per_page + 1][1].callback()
        pump_until(function() return picker.model.count == 1 end)
        picker.action_button.callback()
        pump_until(function() return plugin._external_annotation_sync ~= nil end)
    end
    local function settled()
        pump_until(function() return not plugin._external_annotation_sync end)
    end
    local function continued()
        dismiss(); plugin:getUnifiedAnnotationMenuItems()[2].callback()
        pump_until(function() return plugin._external_annotation_sync ~= nil end)
        settled()
    end
    local before_get, before_post = count("/book/underlines"), count("/book/readreviews")
    select_and_fetch(); settled()
    local context = assert(plugin:_prepareAnnotationContext(false))
    local store, uid = context.store, "1"
    local key = store:projectionKey(context.document_key, uid)
    local source = assert(store:get("900001", "source", uid))
    assert(count("/book/underlines") == before_get + 1 and count("/book/readreviews") == before_post + 1)
    assert(context.statuses[key].stats.located == 1 and source.underlines[1].metadata == client:json_decode("null"))
    assert(not store:get("900001", "download", uid) and plugin._xpointer_overlay.enabled)
    dismiss()
    local record = assert(plugin._xpointer_overlay.records[1])
    reader.rolling:onGotoXPointer(record.pos0); flush(); shot("native-annotations-keyless-overlay")
    local visible = assert(plugin._xpointer_overlay.visible[1])
    local pos = { x = visible.rect.x + visible.rect.w / 2, y = visible.rect.y + visible.rect.h / 2 }
    assert(plugin:_onXPointerOverlayTap({ pos = pos }), "actual overlay tap did not open thought popup")
    local popup = UI:getTopmostVisibleWidget()
    assert(popup.items and popup.items[1].content:find("合成想法", 1, true))
    shot("native-annotations-keyless-thought")
    require("weread.ui.thought_popup").closeVisible()

    -- A real slow thought POST can be paused without waiting for the socket.
    control { match = "/book/readreviews", delay = 1.2, times = 0 }
    select_and_fetch()
    pump_until(function()
        local request = plugin._external_annotation_sync
        return request and request.progress and request.progress.dismiss_callback
            and store:get("900001", "download", uid) ~= nil
    end)
    local request = plugin._external_annotation_sync
    local started = socket.gettime()
    request.progress.buttons[1][1].callback()
    assert(socket.gettime() - started < 0.6 and not plugin._external_annotation_sync)
    assert(store:get("900001", "download", uid).source_kind == "native" and not store:get("900001", "source_status", uid))
    local until_late = socket.gettime() + 1.3
    pump_until(function() return socket.gettime() >= until_late end)
    assert(not store:get("900001", "source_status", uid), "cancelled native response committed late")
    control { match = "", delay = 0, times = 0 }
    before_get, before_post = count("/book/underlines"), count("/book/readreviews")
    continued()
    assert(count("/book/underlines") == before_get and count("/book/readreviews") == before_post + 1)
    assert(store:get("900001", "source_status", uid) and not store:get("900001", "download", uid))

    -- Explicit refusals pause after one GET, without gateway or renewal fanout.
    for _i, status in ipairs({ 401, 429 }) do
        control { match = "/book/underlines", delay = 0, status = status, times = -1 }
        before_get = count("/book/underlines")
        select_and_fetch(); settled()
        assert(count("/book/underlines") == before_get + 1 and not store:get("900001", "source_status", uid))
        local message = UI:getTopmostVisibleWidget()
        assert(message.text and not message.text:find("annotation_source/", 1, true))
        shot(status == 401 and "native-annotations-expired" or "native-annotations-limited")
    end
    control { match = "", delay = 0, times = 0 }
    continued()
    assert(store:get("900001", "source_status", uid))

    -- Replacing the primary grant while HTTP is in flight invalidates both
    -- the child result and the parent's pending checkpoint transition.
    control { match = "/book/underlines", delay = 0.6, times = 0 }
    select_and_fetch()
    pump_until(function()
        local current = plugin._external_annotation_sync
        return current and current.progress and current.progress.dismiss_callback
    end)
    local grants = plugin.native_authorization.store
    local credentials, revision = grants:read()
    assert(grants:save(credentials, settings:get_auth_scope(), revision, 26))
    settled()
    assert(not store:get("900001", "download", uid) and not store:get("900001", "source_status", uid))
    control { match = "", delay = 0, times = 0 }
    continued()
    assert(store:get("900001", "source_status", uid))

    -- Cached source/projection and popup data remain usable without a request.
    dismiss()
    local connected = plugin.isNetworkConnected
    plugin.isNetworkConnected = function() return false end
    before_get, before_post = count("/book/underlines"), count("/book/readreviews")
    continued()
    assert(count("/book/underlines") == before_get and count("/book/readreviews") == before_post)
    plugin.isNetworkConnected = connected
    dismiss()
    settings:set("api_key", saved_key); settings:flush()
    reader.rolling:onGotoPage(saved_page); flush()
    assert(count("/api/agent/gateway", "/book/underlines") + count("/api/agent/gateway", "/book/readreviews") == gateway)
    assert(count("/web/book/read") == writes and count("/login", "native_renewal") == renewals)
    local output = assert(io.open(home .. "/../evidence/native-annotations.json", "wb"))
    output:write(client:json_encode({ result = "PASS", synthetic_only = true, keyless_native = true,
        native_picker_and_matching = true, real_overlay_tap_and_popup = true, cancel_and_resume_batch = true,
        no_late_commit = true, explicit_401_and_429_single_read = true, grant_change_rejected = true,
        offline_cached_matching = true, gateway_annotation_requests = 0, reading_writes = 0, renewal_posts = 0 }))
    output:close()
    print("PASS: keyless native annotations -> actual picker/child HTTP/SQLite/CRE/overlay tap/thought popup; pause/resume, no late commit, one 401/429, grant change, offline cache; no gateway/reading/renewal writes")
end
