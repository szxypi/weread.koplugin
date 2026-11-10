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
    local expected_renewals = 0
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

    -- The first 401 renews once in the parent; a repeated 401 pauses.
    -- A 429 remains a single read and never starts authorization.
    for _i, status in ipairs({ 401, 429 }) do
        control { match = "/book/underlines", delay = 0, status = status, times = -1 }
        before_get = count("/book/underlines")
        select_and_fetch(); settled()
        if status == 401 then expected_renewals = expected_renewals + 1 end
        assert(count("/book/underlines") == before_get + (status == 401 and 2 or 1) and not store:get("900001", "source_status", uid))
        assert(count("/login", "native_renewal") == renewals + expected_renewals)
        local message = UI:getTopmostVisibleWidget()
        assert(message.text and not message.text:find("annotation_source/", 1, true))
        shot(status == 401 and "native-annotations-expired" or "native-annotations-limited")
    end
    control { match = "", delay = 0, times = 0 }
    continued()
    assert(store:get("900001", "source_status", uid))

    -- With 31 real HTTP ranges, the first 30 are committed before a single
    -- second-batch 401. Authorization resumes only that remaining batch.
    control { match = "/book/readreviews", delay = 0, status = 401, times = 1, skip = 1, native_annotation_many = true }
    before_get, before_post = count("/book/underlines"), count("/book/readreviews")
    select_and_fetch(); settled(); expected_renewals = expected_renewals + 1
    assert(count("/book/underlines") == before_get + 1 and count("/book/readreviews") == before_post + 3)
    assert(count("/login", "native_renewal") == renewals + expected_renewals)
    context = assert(plugin:_prepareAnnotationContext(false))
    source = assert(store:get("900001", "source", uid))
    assert(#source.underlines == 31 and #source.reviews == 31 and context.statuses[key].stats.located == 31)
    assert(not store:get("900001", "download", uid))
    dismiss(); shot("native-annotations-renewed-batches")
    local cache = settings:get("cache")
    local saved_auto, saved_prefetch = cache.auto_prefetch_next_chapter, cache.prefetch_annotations
    cache.auto_prefetch_next_chapter, cache.prefetch_annotations = true, true
    settings:set("cache", cache); settings:flush()
    store:clearChapters("900001", { { chapterUid = uid } })
    control { match = "/book/readreviews", delay = 0, status = 401, times = 1, skip = 1 }
    before_get, before_post = count("/book/underlines"), count("/book/readreviews")
    plugin:_runAnnotationJob(context, { background = true, prefetch = true, chapters = { { chapterUid = uid } } })
    pump_until(function() return plugin._external_annotation_sync ~= nil end); settled()
    expected_renewals = expected_renewals + 1
    assert(count("/book/underlines") == before_get + 1 and count("/book/readreviews") == before_post + 3)
    assert(count("/login", "native_renewal") == renewals + expected_renewals)
    assert(store:get("900001", "source_status", uid) and not store:get("900001", "download", uid))
    assert(#store:get("900001", "source", uid).underlines == 31)
    cache.auto_prefetch_next_chapter, cache.prefetch_annotations = saved_auto, saved_prefetch
    settings:set("cache", cache); settings:flush()
    control { match = "", delay = 0, times = 0, skip = 0, native_annotation_many = false }

    -- The real renewal worker remains observable while HTTP is delayed.
    -- Pausing kills it, preserves uncertainty, and cannot commit a late reply.
    control { match = "", delay = 0.6, times = 1, status = 401 }
    local before_cancel = count("/login", "native_renewal")
    select_and_fetch()
    pump_until(function()
        local current = plugin._external_annotation_sync
        return current and current.recovery.renewing and plugin.native_renewal.job
    end)
    request = plugin._external_annotation_sync
    started = socket.gettime(); request.progress.buttons[1][1].callback()
    assert(socket.gettime() - started < 0.6 and not plugin._external_annotation_sync and not plugin.native_renewal.job)
    control { match = "", delay = 0, times = 0 }
    local cancelled_deadline = socket.gettime() + 0.8
    pump_until(function() return socket.gettime() >= cancelled_deadline end)
    local cancelled_posts = count("/login", "native_renewal") - before_cancel
    assert(cancelled_posts >= 0 and cancelled_posts <= 1)
    expected_renewals = expected_renewals + cancelled_posts
    local _, _, _, uncertain = plugin.native_authorization.store:read()
    assert(uncertain and not store:get("900001", "source_status", uid))
    control { match = "/book/underlines", delay = 0, times = 1, status = 401 }
    continued()
    assert(count("/login", "native_renewal") == renewals + expected_renewals and not store:get("900001", "source_status", uid))
    dismiss(); shot("native-annotations-renewal-paused")
    control { match = "", delay = 0, times = 0 }
    local qr_before = count("/login", "native_qr")
    plugin.native_authorization:start()
    pump_until(function() return not plugin.native_authorization.auth end)
    local saved, _, grant_error, pending = plugin.native_authorization.store:read()
    assert(saved and not grant_error and not pending and count("/login", "native_qr") == qr_before + 1)
    dismiss(); continued()
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
    assert(count("/web/book/read") == writes and count("/login", "native_renewal") == renewals + expected_renewals)
    local output = assert(io.open(home .. "/../evidence/native-annotations.json", "wb"))
    output:write(client:json_encode({ result = "PASS", synthetic_only = true, keyless_native = true,
        native_picker_and_matching = true, real_overlay_tap_and_popup = true, cancel_and_resume_batch = true,
        no_late_commit = true, bounded_401_and_429_recovery = true, grant_change_rejected = true,
        recovered_remaining_thought_batch = true, offline_cached_matching = true,
        headless_parent_recovery = true, renewal_cancel_no_replay = true, cancelled_renewal_posts = cancelled_posts,
        gateway_annotation_requests = 0, reading_writes = 0, renewal_posts = expected_renewals }))
    output:close()
    print("PASS: keyless native annotations -> actual picker/child HTTP/SQLite/CRE/overlay tap; parent-only 401 renewal, remaining 31-range batch, bounded repeated 401/429, cancel/resume, grant change and offline; no gateway/reading writes")
    return 1
end
