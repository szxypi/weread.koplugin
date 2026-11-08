package.path = "./?.lua;./?/init.lua;" .. package.path
package.preload["weread.lib.native_credentials"] = function() return {} end
local Renewal = require("weread.lib.native_renewal")
local checks = 0
local function expect(value, label) checks = checks + 1 assert(value, label) end
local function fixture()
    local scope = { vid = "123", epoch = 1 }
    local state = { revision = 1, pending = false, current = true, posts = 0, gets = 0, saves = 0, starts = 0,
        credentials = { vid = "123", accessToken = "test-old-access", refreshToken = "test-refresh", deviceId = string.rep("1", 32) } }
    local settings = { get_auth_scope = function() return scope end,
        auth_scope_matches = function(_self, value) return state.current and value == scope end }
    local store = {
        read = function() return state.credentials, state.revision, nil, state.pending end,
        begin_renewal = function(_self, _scope, revision)
            if state.intent_fail then return false, "save_failed" end
            if state.pending then return false, "renewal_unconfirmed" end
            assert(revision == state.revision)
            state.revision, state.pending = revision + 1, true
            return true, state.revision
        end,
        release_renewal = function(_self, _scope, revision)
            assert(revision == state.revision)
            state.revision, state.pending = revision + 1, false
            return true, state.revision
        end,
        save = function(_self, credentials, _scope, revision, count)
            state.saves = state.saves + 1
            assert(revision == state.revision and count == 1)
            if state.save_fail then return false, "save_failed" end
            state.credentials, state.pending, state.revision = credentials, false, revision + 1
            return true, state.revision
        end,
    }
    local queue = {}
    local worker = { start = function(_self, task, callback)
        state.starts = state.starts + 1
        if state.fork_fail or (state.verify_fork_fail and state.starts == 2) then return false end
        queue[#queue + 1] = { task = task, callback = callback } return true
    end, cancel = function() end }
    local service = Renewal:new{ settings = settings, client = {}, scheduler = {}, store = store, worker = worker,
        make_auth = function(_client, options)
            local auth = { cancel = function(self) self.pending_credentials = nil end }
            auth.verify = function(self)
                state.gets = state.gets + 1
                if (state.shelf_fail or 0) > 0 then
                    state.shelf_fail = state.shelf_fail - 1
                    error("native_auth/shelf/http_503", 0)
                end
                local credentials = self.pending_credentials
                self.pending_credentials = nil
                return credentials, { books = {{}} }
            end
            auth.renew = function(self, previous)
                if not options.is_current() then error("native_auth/renewal/session_changed", 0) end
                if state.clock_fail then error("native_auth/renewal/invalid_clock", 0) end
                expect(state.pending, "durable intent exists before dispatch")
                self.renewal_attempted = true
                state.posts = state.posts + 1
                if state.transport_fail then error("native_auth/renewal/transport", 0) end
                self.pending_credentials = { vid = previous.vid, accessToken = "test-new-access",
                    refreshToken = previous.refreshToken, deviceId = previous.deviceId }
                return self:verify()
            end
            return auth
        end }
    return { service = service, state = state, store = store,
        pop = function() return assert(table.remove(queue, 1)) end,
        tick = function() local task = assert(table.remove(queue, 1)) task.callback(task.task()) end }
end
local f, outcome, reason = fixture(), nil, nil
local function start(target)
    return target.service:start({}, function(ok, err) outcome, reason = ok, err end)
end
expect(start(f), "renewal starts")
expect(f.state.pending and f.state.posts == 0, "intent committed before worker runs")
f.tick()
expect(outcome and f.state.posts == 1 and not f.state.pending and f.state.revision == 3,
    "verified credentials atomically replace pending intent")
expect(f.state.credentials.accessToken == "test-new-access" and not f.service.job, "private job released after commit")
f = fixture(); f.state.transport_fail = true; start(f); f.tick()
expect(not outcome and reason == "renewal_unconfirmed" and f.state.pending, "lost receipt keeps intent")
expect(not start(f) and f.state.posts == 1, "second start cannot replay same refresh after unknown receipt")
f = fixture(); start(f); local late = f.pop(); f.service:cancel(); late.callback(late.task())
expect(f.state.pending and f.state.posts == 0 and not f.service.job, "cancel discards late result and retains uncertainty")
expect(not start(f), "cancelled attempt is not blindly repeated")
f = fixture(); f.state.clock_fail = true; start(f); f.tick()
expect(not outcome and reason == "not_dispatched" and not f.state.pending and f.state.posts == 0,
    "proved pre-dispatch failure releases intent")
f.state.clock_fail = false; start(f); f.tick()
expect(outcome and f.state.posts == 1, "safe retry after pre-dispatch failure")
f = fixture(); f.state.shelf_fail = 1; start(f); f.tick(); f.tick()
expect(outcome and f.state.posts == 1 and f.state.gets == 2, "shelf retry never repeats renewal POST")
f = fixture(); f.state.shelf_fail = 1; f.state.verify_fork_fail = true; start(f); f.tick()
expect(not outcome and reason == "renewal_unconfirmed" and f.state.pending, "failed shelf worker cannot release an already-dispatched intent")
f = fixture(); f.state.save_fail = true; start(f); f.tick()
expect(not outcome and reason == "save_failed" and f.service.job.state == "save_failed", "save failure retains verified credentials in memory")
local posts, gets = f.state.posts, f.state.gets
f.state.save_fail = false
expect(f.service:retry_save() and f.state.posts == posts and f.state.gets == gets and not f.state.pending,
    "local save retry performs no network request")
f = fixture(); start(f); late = f.pop(); local value = late.task()
f.state.revision, f.state.pending = 3, false
f.state.credentials.accessToken = "test-other-grant"
late.callback(value)
expect(not outcome and reason == "session_changed" and f.state.saves == 0
    and f.state.credentials.accessToken == "test-other-grant", "late receipt cannot overwrite a newer grant")
f = fixture(); start(f); f.state.current = false; f.tick()
expect(not outcome and f.state.posts == 0 and f.state.saves == 0, "changed Web session stops dispatch and commit")
f = fixture(); f.state.intent_fail = true
expect(not start(f) and f.state.starts == 0 and f.state.posts == 0, "failed intent persistence dispatches nothing")
f = fixture(); f.state.fork_fail = true; start(f)
expect(not outcome and not f.state.pending and f.state.posts == 0, "failed initial fork releases unused intent")
print("PASS: " .. checks .. " native renewal commit/cancel/receipt checks")
