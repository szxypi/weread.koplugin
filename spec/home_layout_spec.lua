package.path = "./?.lua;./?/init.lua;" .. package.path
local Layout = require("weread.lib.home_layout")
local Data = require("weread.lib.discovery_data")
local checks = 0
local function expect(value, message) checks = checks + 1 assert(value, message) end
local default = Layout.normalize(nil)
expect(#default.sections == 4 and #default.shortcuts == 4 and default.show_status and default.recent_limit == 12,
    "home defaults missing")
local raw = { sections = { "recent", "bad", "recent", "status" }, shortcuts = { "search", "search", "bad", "shelf" },
    show_status = false, view_mode = "list", recent_limit = 24, density = "compact" }
local prefs = Layout.normalize(raw)
expect(table.concat(prefs.sections, ",") == "recent,status,summary,shortcuts", "section order not repaired")
expect(table.concat(prefs.shortcuts, ",") == "search,shelf" and not prefs.show_status and prefs.view_mode == "list",
    "saved layout/visibility not preserved")
prefs.sections[1] = "status"
expect(raw.sections[1] == "recent", "normalization mutated saved preference arrays")
expect(#Layout.normalize({ shortcuts = {} }).shortcuts == 0, "empty shortcut list replaced by defaults")
expect(#Layout.normalize({ shortcuts = Layout.SHORTCUTS }).shortcuts == 4, "shortcut list not bounded")
expect(Layout.normalize({ recent_limit = math.huge, density = "bad" }).recent_limit == 12, "invalid limit accepted")
expect(Layout.reserved(default, function(n) return n end) == 218, "home chrome reservation lost a row")
expect(Layout.reserved(Layout.normalize({ show_status = false, show_summary = false, shortcuts = {} }), function(n) return n end) == 82,
    "hidden widgets still reserve grid height")
expect(Layout.move({ "a", "b", "c" }, "c", -1)[2] == "c", "move-up order failed")
local battery, charging, wifi, connected = 0, false, false, false
local device = { hasBattery = function() return true end, getPowerDevice = function() return {
    getCapacity = function() return battery end, isCharging = function() return charging end,
} end }
local network = { isWifiOn = function() return wifi end, isConnected = function() return connected end,
    isOnline = function() error("status must not probe internet") end }
local state = Layout.status(device, network, 0)
expect(state.capacity == 0 and state.wifi_on == false and state.connected == false, "zero battery or false radio state lost")
battery, charging, wifi, connected = 63, true, true, true
state = Layout.status(device, network, 0)
expect(state.capacity == 63 and state.charging and state.connected, "device status not read")
battery = 101
expect(Layout.status(device, network, 0).capacity == nil, "invalid battery reported as real")
expect(Layout.status({}, { isConnected = function() error("unavailable") end }, 0).connected == nil,
    "unavailable connection invented a status")
local books = {}
for index = 1, 30 do books[index] = { bookId = tostring(index), readUpdateTime = index } end
expect(#Data.recent(books, {}, "a", 6) == 6 and #Data.recent(books, {}, "a", 24) == 24,
    "recent count did not follow layout preference")
expect(books[1].bookId == "1" and Data.recent(books, {}, "a", 24)[1].bookId == "30", "layout changed cloud shelf order")
print("home_layout_spec: " .. checks .. " checks")
