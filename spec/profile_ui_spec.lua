package.path = "./?.lua;./?/init.lua;" .. package.path
local checks = 0
local function expect(value, message) checks = checks + 1 assert(value, message) end
local closed, tasks, shown, dialog, input = {}, {}, nil, nil, "45"
package.preload["ui/uimanager"] = function() return { close = function(_self, view) closed[#closed + 1] = view end } end
package.preload["weread.lib.plugin_util"] = function() return { tr = function(s) return s end } end
package.preload["weread.ui.read_stats_view"] = function()
    return { show = function(data, callbacks) shown = { data = data, callbacks = callbacks } return shown end }
end
package.preload["ui/widget/inputdialog"] = function()
    return { new = function(_self, options)
        dialog = options
        options.getInputText = function() return input end
        return options
    end }
end
local Profile = require("weread.ui.profile")
local account, online, configured, persist_ok, info, offline = "a", false, true, true
local states, writes, rendered, cancelled = {}, 0, 0, nil
local worker = {
    available = function() return true end,
    start = function(_self, options) local request = { options = options } tasks[#tasks + 1] = request return true, request end,
    cancel = function(_self, request) cancelled = request end,
}
local host = setmetatable({
    settings = { get = function() return { name = "Reader" } end, is_api_configured = function() return configured end },
    library_db = {
        accountKey = function() return account end,
        getProfileState = function(_self, name) return (states[account] or {})[name] end,
        putProfileState = function(_self, name, value)
            if not persist_ok then return false end
            states[account] = states[account] or {}
            states[account][name] = value
            writes = writes + 1
            return true
        end,
    },
    profile_worker = worker,
    client = { get_read_stats = function(_self, _mode, base) return { baseTime = base, readTimes = {} } end },
    discoveryNavigation = function() return { {}, {}, {}, {} } end,
    isNetworkOnline = function() return online end,
    requireLogin = function() return configured end,
    showInfo = function(_self, text) info = text end,
    showOffline = function() offline = true end,
    showInputDialog = function() end,
    showReadStats = function() rendered = rendered + 1 end,
    closeWeReadUI = function(self) self:cancelProfileRefresh() self.discovery_epoch = (self.discovery_epoch or 0) + 1 end,
}, { __index = Profile })
host:showProfile()
expect(not shown.data.has_data and #tasks == 0, "offline first visit invented statistics or started network")
host:refreshProfile(false)
expect(offline and #tasks == 0, "manual offline refresh lacked feedback")
online, configured = true, false
host:refreshProfile(true)
expect(#tasks == 0, "automatic refresh prompted unauthorized network")
configured = true
host:refreshProfile(false)
expect(#tasks == 1 and host.profile_request, "manual refresh did not queue worker")
host:refreshProfile(false)
expect(#tasks == 1, "duplicate profile refresh launched")
local result = tasks[1].options.task{ checkCancelled = function() end, emit = function() end }
tasks[1].options.on_done { ok = true, value = result }
expect(writes == 1 and shown.data.has_data and not host.profile_request, "completed stats did not persist/render")
host:refreshProfile(false)
local request = tasks[#tasks]
host:cancelProfileRefresh()
expect(cancelled == request and not host.profile_request, "profile close did not cancel native worker handle")
request.options.on_done { ok = true, value = result }
expect(writes == 1, "cancelled request overwrote cache")
host:refreshProfile(false)
request = tasks[#tasks]
account = "b"
request.options.on_done { ok = true, value = result }
expect(writes == 1 and not host.profile_request, "old account result persisted or locked loading")
account = "a"
host:refreshProfile(false)
request = tasks[#tasks]
host.discovery_epoch = 1
request.options.on_done { ok = true, value = result }
expect(writes == 1, "closed-page epoch accepted result")
host:refreshProfile(false)
tasks[#tasks].options.on_done { ok = false, error = "synthetic failure" }
expect(info and states.a.statistics == result and not host.profile_request, "failure lost cached data")
host:refreshProfile(false)
persist_ok = false
tasks[#tasks].options.on_done { ok = true, value = result }
expect(writes == 1 and info, "failed cache persistence reported success")
persist_ok = true
host:showReadingGoal()
input = "0"
dialog.buttons[1][2].callback()
expect(writes == 1, "invalid goal was saved")
input = "45"
dialog.buttons[1][2].callback()
expect(states.a.goal.minutes == 45 and shown.data.goal_minutes == 45, "goal change did not persist or redraw")
host:showReadingGoal()
local previous_writes = writes
account = "b"
dialog.buttons[1][2].callback()
expect(writes == previous_writes and not states.b, "goal input crossed account boundary")
host:showProfile()
expect(not shown.data.has_data and shown.data.goal_minutes == 30, "profile cache or goal leaked across accounts")
host:cancelProfileRefresh()
account = "a"
host:showProfile()
host:refreshProfile(false)
shown.callbacks.on_statistics()
expect(not host.profile_request and rendered == 1, "details action left dashboard worker able to cover stats")
host:refreshProfile(false)
request = tasks[#tasks]
host:showReadingGoal()
local behind_dialog = shown
request.options.on_done { ok = true, value = result }
expect(shown == behind_dialog and host._profile_goal_dialog, "background completion covered the goal dialog")
dialog.buttons[1][1].callback()
expect(shown ~= behind_dialog and host._profile_goal_dialog == nil, "closing goal dialog did not display latest snapshot")
print("profile_ui_spec: " .. checks .. " checks")
