package.path = "./?.lua;" .. package.path
local helper = require("spec.helpers.annotation_test_store")
local scheduled = {}
package.preload["weread.lib.native_credentials"] = function() return { new = function(_self, settings) return settings.native_store end } end
package.preload["ui/uimanager"] = function() return {
    scheduleIn = function(_self, _delay, fn) scheduled[#scheduled + 1] = fn end,
    show = function() end, close = function() end, setDirty = function() end,
} end
package.preload["weread.lib.plugin_util"] = function() return {
    tr = function(text) return text end, reader_open_perf = function() return 0 end,
    T = function(text, ...) local values = { ... }; return (text:gsub("%%(%d+)", function(index) return tostring(values[tonumber(index)]) end)) end,
} end
local prevented, allowed = 0, 0
package.preload["weread.lib.standby_guard"] = function() return {
    acquire = function() prevented = prevented + 1; return {} end,
    release = function() allowed = allowed + 1 end,
} end
package.preload["weread.ui.download_dialog"] = function() return { new = function(_self, args)
    args.show = function() end; args.close = function() end
    args.setTitle = function(self, text) self.title = text end; args.reportProgress = function() end
    return args
end } end
package.preload["weread.lib.content"] = function() return {} end
local Access = require("weread.lib.annotation_access")
local Renewal = require("weread.lib.native_renewal")
local Controller = require("weread.ui.annotation_sync_controller")
local checks = 0
local function expect(value, label) checks = checks + 1; assert(value, label) end
local function fixture(options)
    options = options or {}
    scheduled = {}
    local queue, scope = {}, { vid = "900000", epoch = 1 }
    local state = { revision = 1, pending = false, posts = 0, underlines = 0, thoughts = {}, online = true,
        saved = 0, current = true, paused = 0, credentials = { vid = "900000", epoch = 1, accessToken = "old-synthetic",
            refreshToken = "synthetic-refresh", deviceId = string.rep("1", 32) } }
    local cache = { auto_prefetch_next_chapter = true, prefetch_annotations = true }
    local store = helper.new()
    store:clearBook("900001")
    local grant = { read = function() return state.credentials, state.revision, nil, state.pending end,
        begin_renewal = function(_self, _scope, revision)
            if state.pending then return false, "renewal_unconfirmed" end
            assert(revision == state.revision); state.revision = revision + 1; state.pending = true; return true, state.revision
        end,
        save = function(_self, credentials, _scope, revision)
            assert(revision == state.revision)
            if options.save_failed then return false, "save_failed" end
            state.credentials = credentials; state.revision = revision + 1; state.pending = false; return true, state.revision
        end }
    local settings = { data_dir = "/unused", get = function(_self, name, default)
        if name == "cache" then return cache end
        if name == "api_key" then return "" end
        return default
    end, set = function() end, flush = function() end,
        get_auth_scope = function() return scope end,
        auth_scope_matches = function(_self, candidate) return state.current and candidate == scope end }
    settings.native_store = grant
    local client = { settings = settings,
        capture_annotation_access = function() return Access.capture(settings, grant) end,
        annotation_access_matches = function(_self, selected) return Access.matches(settings, selected) end,
        get_chapter_underlines = function(_self, _book, _uid, selected)
            state.underlines = state.underlines + 1
            if options.first_get and (state.posts == 0 or options.persistent) then return false, nil, "annotation_source/native_expired" end
            if state.posts > 0 then expect(selected.channel == "native", "renewal resumed through an unpinned route") end
            return true, { _source_kind = "native", underlines = { { range = "1-2", markText = "a" }, { range = "3-4", markText = "b" } } }
        end,
        build_chapter_review_batches = function(_self, ranges)
            local batches = {}; for _i, marker in ipairs(ranges) do batches[#batches + 1] = { { range = marker } } end; return batches
        end,
        get_chapter_reviews_batch = function(_self, _book, _uid, batch, selected)
            local marker = batch[1].range; state.thoughts[#state.thoughts + 1] = marker
            if marker == "3-4" and not options.first_get and (state.posts == 0 or options.persistent) then
                return false, nil, options.failure or "annotation_source/native_expired"
            end
            if state.posts > 0 then expect(selected.channel == "native", "resumed thoughts changed channel") end
            return true, { reviews = {} }
        end }
    local doc = { file = "synthetic-book", getXPointer = function() return "0" end,
        findAllText = function(_self, text) return { { start = text == "a" and "10" or "20", ["end"] = text == "a" and "11" or "21" } } end,
        compareXPointers = function(_self, a, b) return a == b and 0 or tonumber(a) < tonumber(b) and 1 or -1 end }
    local context = { path = doc.file, book_id = "900001", document_key = "synthetic", binding = { book_id = "900001" },
        store = store, chapters = { { chapterUid = "1" } }, ranges = {}, statuses = {} }
    local host = { settings = settings, client = client, ui = { document = doc }, _reader_session_gen = 1,
        _xpointer_overlay = { setRecords = function() end }, _refreshAnnotationOverlay = function() end,
        applyAnnotationVisibility = function() end,
        isNetworkConnected = function() return state.online end,
        showInfo = function(_self, text) state.paused = state.paused + 1; state.last_message = text end }
    for key, value in pairs(Controller) do if host[key] == nil then host[key] = value end end
    local renewal_worker
    host.native_renewal = Renewal:new { settings = settings, client = client, scheduler = {}, store = grant,
        worker = { start = function(_self, task, callback)
            renewal_worker = { task = task, callback = callback }; queue[#queue + 1] = renewal_worker; return true
        end, cancel = function() state.worker_cancelled = true; if renewal_worker then renewal_worker.cancelled = true end end },
        make_auth = function(_client, auth_options)
            local auth = { cancel = function() end }
            function auth:renew()
                if not auth_options.is_current() then error("native_auth/renewal/session_changed", 0) end
                state.posts = state.posts + 1; self.renewal_attempted = true
                if options.lost then error("native_auth/renewal/transport", 0) end
                return { vid = "900000", epoch = 1, accessToken = "new-synthetic", refreshToken = "synthetic-refresh",
                    deviceId = string.rep("1", 32) }, { books = { {} } }
            end
            return auth
        end }
    host.prefetch_worker = { available = function() return true end,
        start = function(_self, args)
            queue[#queue + 1] = { background = true, task = function()
                if args.on_launch then args.on_launch(123, 96000) end
                return args.task { checkCancelled = function() end, sleep = function() end, emit = function() end }
            end, callback = args.on_done }
            return true, {}
        end, cancel = function() end }
    local function drain()
        for _i = 1, 1000 do
            if #scheduled == 0 then return end
            table.remove(scheduled, 1)()
        end
        error("scheduler did not settle")
    end
    local function tick(before_return)
        local queued = assert(table.remove(queue, 1), "missing parent worker")
        if queued.cancelled then queued.callback(nil); drain(); return end
        local ok, value = pcall(queued.task)
        if before_return then before_return(state) end
        if queued.background then queued.callback(ok and { ok = true, value = value } or { ok = false, error = value })
        else assert(ok); queued.callback(value) end
        drain()
    end
    return { host = host, state = state, store = store, queue = queue, drain = drain, tick = tick, options = options, cache = cache,
        start = function(extra) host:_runAnnotationJob(context, extra or {}); drain() end,
        start_only = function(extra) host:_runAnnotationJob(context, extra or {}) end,
        cancel = function() host:_cancelUnifiedAnnotationSync(); drain() end }
end
local f = fixture()
f.start()
expect(f.state.pending and #f.queue == 1 and f.state.posts == 0, "expired thought batch did not queue a parent-owned renewal")
expect(f.store:get("900001", "batch", "1:1") ~= nil, "completed thought batch was lost before renewal")
f.tick()
expect(f.state.posts == 1 and not f.state.pending and f.state.revision == 3, "renewal was not saved exactly once")
expect(f.state.underlines == 1 and table.concat(f.state.thoughts, ",") == "1-2,3-4,3-4", "renewal refetched saved batches")
expect(f.store:get("900001", "source_status", "1") and not f.host._external_annotation_sync, "renewed annotation job did not finish")
f = fixture(); f.start { clear_existing = true, refresh = true }; f.tick()
expect(f.state.underlines == 1 and table.concat(f.state.thoughts, ",") == "1-2,3-4,3-4", "renewal replayed the explicit refetch/reset")
f = fixture { first_get = true }; f.start(); f.tick()
expect(f.state.underlines == 2 and f.state.posts == 1 and f.store:get("900001", "source_status", "1"), "initial underline 401 did not resume on the native channel")
f = fixture { persistent = true }; f.start(); f.tick()
expect(f.state.posts == 1 and #f.queue == 0 and not f.host._external_annotation_sync, "a second 401 caused another renewal")
expect(f.store:get("900001", "download", "1").next_batch == 2, "a repeated refusal lost the saved batch")
for _i, failure in ipairs({ "annotation_source/rate_limited", "annotation_source/rejected", "annotation_source/session_changed" }) do
    f = fixture { failure = failure }; f.start()
    expect(f.state.posts == 0 and #f.queue == 0 and not f.state.pending, "a non-401 error started authorization")
end
f = fixture { lost = true, persistent = true }; f.start(); f.tick()
expect(f.state.posts == 1 and f.state.pending and not f.host._external_annotation_sync, "lost renewal did not retain the pending marker")
f.start()
expect(f.state.posts == 1 and #f.queue == 0 and f.store:get("900001", "download", "1"), "manual continuation replayed an uncertain renewal")
expect(f.state.last_message and f.state.last_message:find("Saved progress", 1, true), "pending renewal failed without a visible pause message")
f = fixture { save_failed = true, persistent = true }; f.start(); f.tick()
expect(f.state.posts == 1 and f.state.pending and f.host.native_renewal.job.state == "save_failed", "failed grant save lost the save-only recovery")
f.options.save_failed = false
expect(f.host.native_renewal:retry_save() and f.state.posts == 1, "retry saving repeated authorization")
f.options.persistent = false; f.start()
expect(f.store:get("900001", "source_status", "1") and f.state.posts == 1, "saved renewal could not continue the checkpoint")
f = fixture(); f.start(); f.cancel(); f.tick()
expect(f.state.posts == 0 and f.state.worker_cancelled and not f.host._external_annotation_sync, "cancellation dispatched a queued renewal")
f = fixture(); f.start()
f.tick(function(state)
    state.revision = state.revision + 1; state.pending = false
    state.credentials = { vid = "900000", epoch = 1, accessToken = "external-synthetic", refreshToken = "synthetic-refresh",
        deviceId = string.rep("1", 32) }
end)
expect(f.state.posts == 1 and not f.host._external_annotation_sync and not f.store:get("900001", "source_status", "1"), "an externally replaced grant was overwritten")
f = fixture(); f.start(); f.state.current = false; f.tick()
expect(f.state.posts == 0 and not f.host._external_annotation_sync, "an account change dispatched authorization")
f = fixture(); f.start(); f.host._reader_session_gen = f.host._reader_session_gen + 1; f.tick()
expect(not f.host._external_annotation_sync and not f.store:get("900001", "source_status", "1"), "a different reader session received resumed data")
f = fixture(); f.start { prefetch = true, background = true }; f.tick()
expect(f.state.pending and #f.queue == 1 and f.state.posts == 0, "headless 401 did not transfer renewal ownership to the parent")
f.tick(); expect(#f.queue == 1 and f.state.posts == 1, "headless renewal did not queue a fresh worker")
f.tick()
expect(f.store:get("900001", "source_status", "1") and f.state.underlines == 1
    and table.concat(f.state.thoughts, ",") == "1-2,3-4,3-4", "headless renewal refetched completed data")
f = fixture(); f.start { prefetch = true, background = true }; f.tick()
f.cache.prefetch_annotations = false; f.tick()
expect(#f.queue == 0 and not f.host._external_annotation_sync and f.store:get("900001", "download", "1"), "disabled prefetch queued a resumed annotation worker")
f = fixture()
local late
f.host.native_renewal = { start = function(_self, _options, callback) late = callback; return true, {} end, cancel = function() end }
f.start(); f.cancel(); f.state.posts = 1; f.start_only()
local replacement = f.host._external_annotation_sync
late(false)
expect(replacement and f.host._external_annotation_sync == replacement, "old renewal callback closed a newer annotation job")
f.drain()
expect(not f.host._external_annotation_sync and prevented == allowed, "recovery leaked ownership or the standby guard")
helper.cleanup()
print("annotation_recovery_spec: " .. checks .. " checks")
