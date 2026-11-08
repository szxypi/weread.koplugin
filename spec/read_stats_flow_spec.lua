package.path = "./?.lua;./?/init.lua;" .. package.path
local checks = 0
local function expect(value, message) checks = checks + 1 assert(value, message) end
local shown, closed, queued = {}, {}, {}
package.preload["ui/uimanager"] = function() return { close = function(_self, view) closed[#closed + 1] = view end } end
package.preload["weread.lib.logger"] = function() return { err = function() end } end
package.preload["weread.lib.plugin_util"] = function()
    return { tr = function(s) return s end, T = function(s) return s end, log_error = tostring, display_error = tostring }
end
package.preload["weread.ui.read_stats_view"] = function()
    return { show = function(data, callbacks)
        local view = { data = data, callbacks = callbacks }
        shown[#shown + 1] = view
        return view
    end }
end
local Report = require("weread.ui.read_report")
local account, calls, busy, offline, fail, message = "a", 0, 0, false, false
local host = setmetatable({
    library_db = { accountKey = function() return account end },
    client = { get_read_stats = function()
        calls = calls + 1
        if fail then error("offline") end
        return { readTimes = {}, totalReadTime = 0 }
    end },
    showBusy = function() busy = 1 end,
    closeBusy = function() busy = 0 end,
    runOnlineTask = function(_self, _title, fn) if offline then return false end queued[#queued + 1] = fn return true end,
    showInfo = function(_self, text) message = text end,
}, { __index = Report })
offline = true
host:loadReadStats("monthly")
expect(busy == 0 and #queued == 0, "offline statistics left loading dialog stuck")
offline = false
host:loadReadStats("monthly")
host:loadReadStats("weekly")
queued[1]()
expect(calls == 0 and #shown == 0, "superseded statistics request ran")
queued[2]()
expect(calls == 1 and #shown == 1 and host._read_stats_view == shown[1], "latest statistics did not render")
host:loadReadStats("annually", nil, shown[1])
shown[1].callbacks.on_close()
queued[3]()
expect(#shown == 1 and calls == 1 and busy == 0, "closing statistics reopened a late result or retained its loading dialog")
host:loadReadStats("overall")
account = "b"
queued[4]()
expect(calls == 1 and #shown == 1, "statistics request crossed accounts")
account = "a"
host:loadReadStats("monthly")
queued[5]()
local original = host._read_stats_view
fail = true
host:loadReadStats("weekly", nil, original)
queued[6]()
expect(host._read_stats_view == original and message, "failed navigation discarded current statistics")
local Stats = require("weread.lib.read_stats")
expect(not pcall(Stats.fetch, { get_read_stats = function() return {} end }, "monthly"), "malformed response became zero statistics")
expect(not pcall(Stats.fetch, { get_read_stats = function() return { readTimes = {}, errcode = -1 } end }, "monthly"),
    "API rejection became a successful chart")
print("read_stats_flow_spec: " .. checks .. " checks")
