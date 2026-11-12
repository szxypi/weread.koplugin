-- Explicit expiry-only acceptance addon. One native login is guarded behind
-- an observed 401 and the host's already-durable Keychain renewal intent.
return function(input, mode, counters)
    local ffi, Json = require("ffi"), require("json")
    local Crypto, Protocol = require("weread.lib.crypto"), require("weread.lib.protocol")
    local factory = dofile(debug.getinfo(1, "S").source:match("^@(.*/)") .. "owner_annotations_case.lua")
    local config = assert(input.annotations)
    assert(type(config.permit_renewal) == "boolean")
    assert(not config.permit_renewal or type(config.intent_digest) == "string"
        and #config.intent_digest == 64 and config.intent_digest:match("^[a-f0-9]+$"))
    local initial = config.credentials
    assert(type(initial.refreshToken) == "string" and type(initial.deviceId) == "string" and #initial.deviceId == 32)
    local case = factory(input, mode, counters, mode == "live" and { pending_model = true } or nil)
    local state = { credentials = initial, revision = 1, pending = false, saved = false }
    local recovery = { first_native_status = 0, authentication_posts = 0, renewal_shelf_reads = 0,
        renewal_shelf_status = 0, saved_revision = 1, saved_new_grant = false, renewal_pending = false,
        guard_denied = 0, failed_line = 0, store_write_attempts = 0 }
    local function text(value) return type(value) == "string" and #value >= 8 and #value <= 4096 and not value:find("[%z%c%s]") end
    local function hash(value)
        return Crypto.sha256_hex(table.concat({ value.vid, value.accessToken, value.refreshToken, value.deviceId }, "\0"))
    end
    local function clone(value)
        local result = {}; for key, item in pairs(value) do result[key] = item end; return result
    end
    local Store = require("weread.lib.native_credentials")
    function Store:_read()
        if not self.settings:auth_scope_matches({ vid = input.vid, epoch = 1 }) then return nil, "unavailable" end
        if not case.enabled then return { revision = 0 } end
        local grant = clone(state.credentials)
        grant.epoch, grant.verified_at, grant.book_count = 1, os.time(), state.book_count or input.shelf_books
        return { revision = state.revision, authorization = grant, renewal_pending = state.pending }
    end
    function Store:_write(value, scope, revision, pending)
        counters[28] = counters[28] + 1
        assert(mode == "live" and case.enabled and config.permit_renewal, "renewal not enabled")
        assert(scope.vid == input.vid and scope.epoch == 1 and self.settings:auth_scope_matches(scope))
        assert(revision == state.revision and value.vid == input.vid and value.deviceId == initial.deviceId)
        if pending == true then
            assert(state.revision == 1 and not state.pending and counters[23] == 401 and counters[24] == 0)
            assert(hash(value) == hash(initial))
            state.pending, state.revision = true, 2
        else
            assert(state.revision == 2 and state.pending and counters[24] == 1 and counters[26] == 200)
            assert(text(value.accessToken) and text(value.refreshToken) and value.book_count == tonumber(counters[27]))
            assert(hash(value) == ffi.string(ffi.cast("char *", counters) + 512, 64))
            state.credentials = { vid = value.vid, accessToken = value.accessToken, refreshToken = value.refreshToken, deviceId = value.deviceId }
            state.book_count, state.pending, state.saved, state.revision = value.book_count, false, true, 3
        end
        return true, state.revision
    end
    function case:before_fetch(plugin)
        self.store = assert(plugin:_prepareAnnotationContext(false)).store
    end
    local underlines_url = "https://i.weread.qq.com/book/underlines?bookId=" .. Protocol.urlencode(input.book_id)
        .. "&chapterUid=" .. Protocol.urlencode(input.chapter_uid) .. "&synckey=0"
    local function login_body(body)
        local keys = { deviceId = true, deviceName = true, deviceType = true, timestamp = true, random = true,
            trackId = true, refreshToken = true, inBackground = true, kickType = true, refCgi = true, signature = true }
        local count = 0
        for key in pairs(body) do if not keys[key] then return false end; count = count + 1 end
        return count == 11 and body.deviceId == initial.deviceId and body.deviceName == "BOOX" and body.deviceType == 3
            and body.refreshToken == initial.refreshToken and body.inBackground == 0 and body.kickType == 1
            and body.refCgi == "" and body.trackId == "" and type(body.timestamp) == "number" and body.timestamp % 1 == 0
            and math.abs(body.timestamp - os.time() * 1000) <= 90000
            and type(body.random) == "number" and body.random % 1 == 0 and body.random >= 1 and body.random <= 999
            and body.signature == Crypto.sha256_hex(string.format("%.0f", body.timestamp) .. initial.deviceId .. tostring(body.random))
    end
    function case:request(client, options, dispatch)
        local h = options.headers or {}
        local clean = mode == "live" and self.enabled and options.skip_cookie == true
            and options.persist_response_cookies == false and options.sensitive == true
            and not h.Cookie and not h.cookie and not h.Authorization and not h.authorization
        local authenticated = clean and h.vid == input.vid and h.accessToken == state.credentials.accessToken
        local kind, capture
        if authenticated and options.url == underlines_url and options.method == "GET" and not options.body
            and ((counters[20] == 0 and state.revision == 1) or (counters[20] == 1 and state.saved)) then kind = 20
        elseif clean and config.permit_renewal and state.pending and state.revision == 2 and counters[23] == 401
            and options.url == "https://i.weread.qq.com/login" and options.method == "POST" and not h.vid and not h.accessToken
            and counters[24] == 0 and type(options.body) == "string" and #options.body <= 16384 then
            local valid, body = pcall(Json.decode, options.body)
            if valid and type(body) == "table" and login_body(body) then kind, capture = 24, "login" end
        elseif clean and state.pending and state.revision == 2 and counters[24] == 1 and counters[25] == 0
            and options.url == "https://i.weread.qq.com/shelf/sync" and options.method == "GET" and not options.body
            and h.vid == input.vid and text(state.pending_access) and h.accessToken == state.pending_access then kind, capture = 25, "shelf"
        elseif authenticated and state.saved and counters[20] == 2 and options.url == "https://i.weread.qq.com/book/readreviews"
            and options.method == "POST" and type(options.body) == "string" and #options.body <= 16384 then
            local stage = self.store:get(input.book_id, "download", input.chapter_uid)
            local valid, body = pcall(Json.decode, options.body)
            if stage and stage.source_kind == "native" and valid and type(body) == "table" and body.bookId == input.book_id
                and body.chapterUid == tonumber(input.chapter_uid) and body.cht2sMode == "" and type(body.reviews) == "table" then
                local fields, exact = 0, true
                for key in pairs(body) do if not ({ bookId = true, chapterUid = true, cht2sMode = true, reviews = true })[key] then exact = false end; fields = fields + 1 end
                local start = tonumber(counters[21]) * 30 + 1
                local count = math.min(30, #stage.underlines - start + 1)
                exact = exact and fields == 4 and count > 0 and count <= 30 and #body.reviews == count
                for _i, row in ipairs(body.reviews) do
                    local keys = 0
                    for key in pairs(row) do if not ({ range = true, maxIdx = true, count = true, synckey = true })[key] then exact = false end; keys = keys + 1 end
                    if keys ~= 4 or row.range ~= stage.underlines[start + _i - 1].range or row.maxIdx ~= 0 or row.count ~= 30 or row.synckey ~= 0 then exact = false end
                end
                if exact then kind = 21 end
            end
        end
        if not kind then counters[22] = counters[22] + 1; error("expiry scope rejected", 0) end
        counters[kind] = counters[kind] + 1 -- uncertain sends consume their slot
        local chunks, size, sink = {}, 0, options.sink
        if capture then options.sink = function(chunk, err)
            if chunk then size = size + #chunk; assert(size <= 4 * 1024 * 1024); chunks[#chunks + 1] = chunk end
            return sink(chunk, err)
        end end
        local raw, code, headers, status = dispatch(client, options)
        if kind == 20 and counters[20] == 1 then counters[23] = tonumber(code) or 0 end
        if capture and code == 200 then
            local value = Json.decode(table.concat(chunks))
            if capture == "login" then
                assert(tostring(value.vid) == input.vid and text(value.accessToken))
                local candidate = { vid = input.vid, accessToken = value.accessToken,
                    refreshToken = value.refreshToken or initial.refreshToken, deviceId = initial.deviceId }
                assert(text(candidate.refreshToken))
                state.pending_access = candidate.accessToken
                ffi.copy(ffi.cast("char *", counters) + 512, hash(candidate), 64)
            else
                assert(type(value.books) == "table" and #value.books > 0 and #value.books <= 5000)
                counters[26], counters[27] = 200, #value.books
            end
        elseif capture == "shelf" then counters[26] = tonumber(code) or 0 end
        return raw, code, headers, status
    end
    local secrets, finish = case.secrets, case.finish
    function case:secrets()
        local result = secrets(self)
        for _i, key in ipairs({ "accessToken", "refreshToken", "deviceId" }) do result[#result + 1] = state.credentials[key] end
        return result
    end
    function case:finish(reason)
        finish(self, reason)
        recovery.first_native_status, recovery.authentication_posts = tonumber(counters[23]), tonumber(counters[24])
        recovery.renewal_shelf_reads, recovery.renewal_shelf_status = tonumber(counters[25]), tonumber(counters[26])
        recovery.saved_revision, recovery.saved_new_grant, recovery.renewal_pending = state.revision, state.saved, state.pending
        recovery.guard_denied = tonumber(counters[22])
        recovery.store_write_attempts = tonumber(counters[28])
        recovery.failed_line = tonumber(type(reason) == "string" and reason:match("owner_expired_annotations_case%.lua:(%d+):")) or 0
        self.report.recovery = nil
    end
    function case:private()
        return { guard_installed = true, recovery = recovery, credentials = state.saved and state.credentials or Json.util.null,
            model = self.private_model or Json.util.null }
    end
    case.recovery_report = recovery
    return case
end
