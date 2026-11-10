package.path = "./?.lua;./?/init.lua;" .. package.path
local Layout = require("weread.lib.home_layout")
local checks = 0
local function expect(value, message) checks = checks + 1 assert(value, message) end
local scheduled, unscheduled, shown, battery, light, lights, wifi_calls = {}, {}, nil, 63, false, 0, 0
local ticks={}
package.preload["ui/uimanager"] = function() return {
    close = function(_self, view) if view.onCloseWidget then view:onCloseWidget() end end,
    show = function(_self, view) shown = view end,
    nextTick = function(_self, callback) ticks[#ticks+1]=callback end,
    scheduleIn = function(_self, delay, fn) scheduled[#scheduled + 1] = { delay = delay, fn = fn } end,
    unschedule = function(_self, fn) unscheduled[fn] = true end,
} end
package.preload["device"] = function() return {
    hasBattery = function() return true end,
    getPowerDevice = function() return { getCapacity = function() return battery end } end,
    hasFrontlight = function() return light end, showLightDialog = function() lights = lights + 1 end,
} end
local wifi_adapter
package.preload["ui/network/manager"] = function() return {
    isWifiOn = function() return false end, isConnected = function() return false end,
    getWifiMenuTable = function() return { enabled_func = function() return true end,
        callback = function(adapter) wifi_calls = wifi_calls + 1 wifi_adapter = adapter end } end,
} end
package.preload["ui/widget/confirmbox"] = function() return { new = function(_self, options) return options end } end
package.preload["weread.lib.plugin_util"] = function() return {
    tr = function(s) return s end,
    T = function(s, ...)
        for index = 1, select("#", ...) do local value = tostring(select(index, ...)) s = s:gsub("%%" .. index, value) end
        return s
    end,
} end
local Home = require("weread.ui.home_settings")
local preferences, cache, fail, saves, redraws, info, prefetch = Layout.normalize(nil), {}, false, 0, 0
local summary, status_text, summary_text = "day-one"
local host = setmetatable({
    settings = {
        get = function(_self, key) if key == "home" then return preferences elseif key == "cache" then return cache end end,
        set = function(_self, key, value) if key == "home" then preferences = value elseif key == "cache" then cache = value end end,
        flush = function() if fail then return false end saves = saves + 1 return true end,
    },
    safeCallback = function(_self, _label, fn) return fn end,
    showList = function(_self, title, items) return { title = title, items = items } end,
    showInfo = function(_self, text) info = text end,
    showHome = function(self) redraws = redraws + 1 self.shelf_view = { home_layout = preferences } end,
    setChapterPrefetchEnabled = function(_self, value) prefetch = value end,
}, { __index = Home })
local function find(items, text)
    for _, item in ipairs(items) do if item.text:find(text, 1, true) then return item end end
    error("missing item: " .. text)
end
host.shelf_view = { home_layout = preferences }
host:showHomeLayoutSettings()
find(host._home_controls_menu.items, "Home book display").sub_item_table[2].callback()
expect(preferences.view_mode == "list" and redraws == 1 and saves == 1, "home view preference did not persist and redraw")
find(host._home_controls_menu.items, "Clock and device status").callback()
expect(not preferences.show_status, "status visibility not saved")
find(host._home_controls_menu.items, "Home section order").sub_item_table[1].sub_item_table[2].callback()
expect(preferences.sections[2] == "status", "home module reorder failed")
local before = preferences.view_mode
fail = true
find(host._home_controls_menu.items, "Home book display").sub_item_table[1].callback()
expect(preferences.view_mode == before and info and host._home_controls_menu == nil, "failed save applied unsaved layout")
fail = false
host:showHomeLayoutSettings()
local shortcuts = find(host._home_controls_menu.items, "Configure home shortcuts").sub_item_table
find(shortcuts, "My WeRead").sub_item_table[1].callback()
expect(#preferences.shortcuts == 4 and info:find("at most 4", 1, true), "fifth shortcut silently added/dropped")
host:showHomeLayoutSettings()
shortcuts = find(host._home_controls_menu.items, "Configure home shortcuts").sub_item_table
find(shortcuts, "Bookshelf").sub_item_table[1].callback()
expect(#preferences.shortcuts == 3 and preferences.shortcuts[1] == "store", "shortcut hide removed wrong item")
shortcuts = find(host._home_controls_menu.items, "Configure home shortcuts").sub_item_table
find(shortcuts, "My WeRead").sub_item_table[1].callback()
expect(preferences.shortcuts[4] == "profile", "new shortcut not appended")
host:showHomeQuickSettings()
find(host._home_controls_menu.items, "Frontlight").callback()
expect(lights == 0, "unsupported light control changed device")
light = true
host:showHomeQuickSettings()
find(host._home_controls_menu.items, "Frontlight").callback()
expect(lights == 1 and host._home_controls_menu == nil, "light control did not delegate to native dialog")
host:showHomeQuickSettings()
find(host._home_controls_menu.items, "Wi-Fi settings").callback()
expect(wifi_calls == 1 and host._home_controls_menu == nil, "Wi-Fi control did not delegate to native menu")
host.discovery_epoch = 1
wifi_adapter:updateItems()
expect(host._home_controls_menu == nil, "late Wi-Fi callback reopened closed controls")
host:showHomeQuickSettings()
find(host._home_controls_menu.items, "Automatically prefetch").callback()
expect(prefetch == nil and shown, "prefetch enabled without resource confirmation")
shown.ok_callback()
expect(prefetch == true and host._home_prefetch_confirmation == nil, "prefetch control did not reuse existing service")
local pending = 0
host:showHomeQuickSettings()
host.shelf_view._shelf_redraw = function() pending = pending + 1 end
require('ui/uimanager'):close(host._home_controls_menu)
for _tick_index,callback in ipairs(ticks) do callback() end;ticks={}
expect(pending == 1 and host._home_controls_menu == nil, "modal close lost deferred redraw")
host:showHomeQuickSettings()
host.shelf_view._shelf_redraw = function() pending = pending + 1 end
host:closeHomeControls(false)
for _tick_index,callback in ipairs(ticks) do callback() end;ticks={}
expect(pending == 1 and host.shelf_view._shelf_redraw == nil, "global close replayed stale redraw")
for _event_index,event in ipairs({'closed','replaced','page','session'}) do
    host.shelf_view={home_layout=preferences}
    host:showHomeQuickSettings()
    local menu=host._home_controls_menu
    local callback=find(menu.items,'Download book images').callback
    local saved_count=saves
    if event=='closed' then host:closeHomeControls(false)
    elseif event=='replaced' then host:showHomeQuickSettings()
    elseif event=='page' then host.shelf_view={home_layout=preferences}
    else host._reader_session_gen=(host._reader_session_gen or 0)+1 end
    local active=host._home_controls_menu;callback()
    expect(saves==saved_count and host._home_controls_menu==active,'old home setting callback: '..event)
    host:closeHomeControls(false)
    host.shelf_view={home_layout=preferences}
    host:showHomeQuickSettings()
    find(host._home_controls_menu.items,'Automatically prefetch').callback()
    local box=assert(host._home_prefetch_confirmation);prefetch=nil
    if event=='closed' then host:closeHomeControls(false)
    elseif event=='replaced' then host:showHomeQuickSettings()
    elseif event=='page' then host.shelf_view={home_layout=preferences}
    else host._reader_session_gen=(host._reader_session_gen or 0)+1 end
    active=host._home_controls_menu;box.ok_callback();box.cancel_callback()
    expect(prefetch==nil and host._home_controls_menu==active,'old prefetch confirmation: '..event)
    host:closeHomeControls(false)
end
host.homeReadingSummary = function() return summary end
local view = { home_layout = Layout.normalize(nil),
    updateHomeStatus = function(_self, text) status_text = text end,
    updateHomeSummary = function(_self, text) summary_text = text end }
host.shelf_view = view
host:startHomeStatusTimer(view)
local tick = host._home_status_task
expect(status_text:find("63%%") and summary_text == "day-one", "status/summary initial refresh missing")
battery, summary = 0, "day-two"
local original_redraws = redraws
tick()
expect(status_text:find("0%%") and summary_text == "day-two" and redraws == original_redraws,
    "minute update lost zero battery, date summary or rebuilt entire home")
host:stopHomeStatusTimer()
expect(unscheduled[tick] and host._home_status_task == nil, "closing home did not cancel timer")
local count = #scheduled
tick()
expect(#scheduled == count, "cancelled status tick rescheduled itself")
print("home_settings_spec: " .. checks .. " checks")
