package.path = "./?.lua;./?/init.lua;" .. package.path
local checks = 0
local function expect(value, label) checks = checks + 1 assert(value, label) end
for _, module in ipairs({ "buttondialog", "confirmbox", "infomessage", "qrmessage" }) do
    package.preload["ui/widget/" .. module] = function() return { new = function(_self, options) return options end } end
end
package.preload["device"] = function() return { screen = { getWidth = function() return 600 end,
    getHeight = function() return 800 end } } end
package.preload["ui/uimanager"] = function() return {} end
package.preload["weread.lib.plugin_util"] = function() return { tr = function(text) return text end,
    T = function(text, count) return text:gsub("%%1", tostring(count)) end } end
package.preload["weread.lib.native_credentials"] = function() return {} end
local Controller = require("weread.ui.native_authorization")
local function fixture()
    local queue, jobs, messages, stages = {}, {}, {}, {}
    local current, online, now, fail_save, fail_shelf, mismatch, poll_result = true, true, 0, false, false, false, "confirmed"
    local scope, saved, revision, save_calls = { vid = "123", epoch = 1 }, nil, 0, 0
    local scheduler = {
        show = function() end,
        close = function(_self, widget)
            if widget.onCloseWidget then widget:onCloseWidget()
            elseif widget.dismiss_callback then widget.dismiss_callback() end
        end,
        scheduleIn = function(_self, delay, fn) expect(delay >= 0.1, "positive UI schedule") queue[#queue + 1] = fn end,
        unschedule = function(_self, fn) for i = #queue, 1, -1 do if queue[i] == fn then table.remove(queue, i) end end end,
    }
    local host = { isNetworkConnected = function() return online end,
        showInfo = function(_self, text) messages[#messages + 1] = text end,
        showOffline = function() messages[#messages + 1] = "offline" end,
        qr_login = { cancel = function() end } }
    local settings = { get_auth_scope = function() return scope end,
        auth_scope_matches = function(_self, candidate) return current and candidate == scope end }
    local store = {
        read = function() return saved, revision end,
        save = function(_self, credentials, owner, expected_revision, count)
            save_calls = save_calls + 1
            expect(owner == scope and expected_revision == revision and count == 26, "save retains verified scope/revision/count")
            if fail_save then return false, "save_failed" end
            saved, revision = credentials, revision + 1
            return true, revision
        end,
        clear = function() saved, revision = nil, revision + 1 return true end,
    }
    local worker = { cancel = function() end, start = function(_self, task, callback)
        jobs[#jobs + 1] = { task = task, callback = callback } return true
    end }
    local function make_auth()
        return {
            cancel = function(self) self.closed, self.confirmed_code, self.pending_credentials = true, nil, nil end,
            begin = function(self) stages[#stages + 1] = "begin" self.uid = "test-uuid" return "https://example.invalid/test-qr" end,
            poll = function(self) stages[#stages + 1] = "poll" self.confirmed_code = "test-code" return poll_result end,
            finish = function(self)
                stages[#stages + 1] = self.pending_credentials and "verify" or "login"
                if mismatch then error("native_auth/login/account_mismatch", 0) end
                self.pending_credentials = { vid = "123", accessToken = "test-access", refreshToken = "test-refresh",
                    deviceId = string.rep("1", 32) }
                if fail_shelf then error("native_auth/shelf/http_503", 0) end
                local books = {} for i = 1, 26 do books[i] = {} end
                return self.pending_credentials, { books = books }
            end,
        }
    end
    local controller = Controller:new(host, {}, settings, { store = store, worker = worker,
        scheduler = scheduler, make_auth = make_auth, now = function() return now end })
    return { controller = controller, messages = messages, stages = stages,
        job = function() local job = assert(table.remove(jobs, 1)) job.callback(job.task()) return job end,
        pop = function() return table.remove(jobs, 1) end,
        tick = function() local fn = assert(table.remove(queue, 1)) fn() end,
        set = function(options)
            if options.current ~= nil then current = options.current end
            if options.online ~= nil then online = options.online end
            if options.save ~= nil then fail_save = options.save end
            if options.shelf ~= nil then fail_shelf = options.shelf end
            if options.mismatch ~= nil then mismatch = options.mismatch end
            if options.poll then poll_result = options.poll end
            if options.now then now = options.now end
        end,
        saved = function() return saved, save_calls end,
    }
end
local function confirm(f)
    f.controller:start(); f.job(); f.tick(); f.job()
end
local f = fixture()
confirm(f); f.job()
expect(f.saved() and f.controller.credentials == nil and f.controller.auth == nil, "saved success drops in-memory secrets")
expect(f.messages[1]:find("26", 1, true), "only public count displayed")
f.controller:clear()
expect(f.saved() == nil, "clear removes native grant")
f = fixture(); f.controller:start()
local late = f.pop()
f.controller.dialog.dismiss_callback()
late.callback(late.task())
expect(not f.saved() and not f.controller.dialog, "dismiss rejects late begin result")
f = fixture(); f.controller:start(); late = f.pop(); f.controller:start()
local active = f.controller.auth
late.callback(late.task())
expect(f.controller.auth == active, "old worker receipt cannot cancel a newer attempt")
f = fixture(); confirm(f); f.set({ current = false }); f.job()
expect(not f.saved() and f.controller.credentials == nil, "account switch rejects pending login outcome")
f = fixture(); f.set({ save = true }); confirm(f); f.job()
expect(not f.saved() and f.controller.credentials ~= nil, "failed save retains only verified in-memory credentials for retry")
local before = #f.stages
f.set({ save = false }); f.controller.dialog.ok_callback()
local saved, attempts = f.saved()
expect(saved and attempts == 2 and #f.stages == before, "save retry performs no network request")
f = fixture(); f.set({ save = true }); confirm(f); f.job()
f.controller.dialog.cancel_callback()
expect(f.controller.credentials == nil and f.controller.scope == nil, "save retry cancel discards credentials")
f = fixture(); f.set({ shelf = true }); confirm(f); f.job()
expect(f.controller.auth.pending_credentials ~= nil and not f.saved(), "failed shelf is not saved")
f.set({ shelf = false }); f.controller.dialog.ok_callback(); f.job()
expect(f.saved() and f.stages[4] == "verify", "shelf retry does not repeat login")
f = fixture(); f.set({ mismatch = true }); confirm(f); f.job()
expect(not f.saved() and f.messages[1]:find("differs", 1, true), "wrong account shows controlled error without saving")
f = fixture(); f.set({ poll = "expired" }); confirm(f)
expect(not f.saved() and f.controller.auth == nil, "expired QR closes protocol")
f = fixture(); f.controller:start(); f.job(); f.set({ now = 301 }); f.tick()
expect(f.controller.auth == nil and f.messages[1]:find("expired", 1, true), "local QR timeout terminates")
f = fixture(); f.set({ online = false }); f.controller:start()
expect(f.messages[1] == "offline" and f.pop() == nil, "offline state never starts network")
f = fixture(); f.set({ current = false }); f.controller:start()
expect(f.messages[1]:find("login", 1, true) and f.pop() == nil, "identified current Web login required")
print("PASS: " .. checks .. " native authorization UI state/cancel/save/account checks")
