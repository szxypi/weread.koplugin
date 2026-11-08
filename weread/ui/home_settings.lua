local Device = require("device")
local UIManager = require("ui/uimanager")
local Layout = require("weread.lib.home_layout")
local Profile = require("weread.lib.profile")
local Util = require("weread.lib.plugin_util")
local _, T = Util.tr, Util.T
local M = {}
local section_labels = { status = "Clock and device status", summary = "Reading overview",
    shortcuts = "Home shortcuts", recent = "Recently read" }
local shortcut_labels = { shelf = "Bookshelf", store = "Bookstore", search = "Search WeRead",
    profile = "My WeRead", settings = "Quick settings", refresh = "Refresh" }

function M:homePreferences()
    return Layout.normalize(self.settings:get("home"))
end

function M:homeStatusText()
    local ok, network = pcall(require, "ui/network/manager")
    local state = Layout.status(Device, ok and network or nil)
    local fields = { state.clock }
    if state.capacity then fields[#fields + 1] = T(_("Battery %1%"), state.capacity) end
    if state.charging then fields[#fields + 1] = _("Charging") end
    if state.connected == true then fields[#fields + 1] = _("Wi-Fi connected")
    elseif state.wifi_on == false then fields[#fields + 1] = _("Wi-Fi off")
    elseif state.connected == false then fields[#fields + 1] = _("Wi-Fi not connected") end
    return table.concat(fields, " · ")
end

function M:stopHomeStatusTimer()
    if self._home_status_task then UIManager:unschedule(self._home_status_task) self._home_status_task = nil end
end

function M:startHomeStatusTimer(view, refresh_now)
    self:stopHomeStatusTimer()
    if not view or not view.home_layout or not view.updateHomeStatus
        or not (view.home_layout.show_status or view.home_layout.show_summary) then return end
    local function update()
        if view.home_layout.show_status then view:updateHomeStatus(self:homeStatusText()) end
        if view.home_layout.show_summary and view.updateHomeSummary then view:updateHomeSummary(self:homeReadingSummary()) end
    end
    local tick
    tick = function()
        if self._home_status_task ~= tick then return end
        self._home_status_task = nil
        if self.shelf_view ~= view then return end
        update()
        self._home_status_task = tick
        UIManager:scheduleIn(60 - os.time() % 60, tick)
    end
    if refresh_now ~= false then update() end
    self._home_status_task = tick
    UIManager:scheduleIn(60 - os.time() % 60, tick)
end

function M:homeReadingSummary()
    local snapshot = self.library_db and self.library_db.getProfileState and self.library_db:getProfileState("statistics")
    local goal = self.library_db and self.library_db.getProfileState and self.library_db:getProfileState("goal") or {}
    local data = Profile.build(snapshot, goal.minutes)
    if not data.has_data then return _("Reading overview · Open My WeRead to load statistics") end
    local text = T(_("Today %1 / %2 min · %3 consecutive days"),
        math.floor(data.today_seconds / 60), data.goal_minutes, (data.streak_lower_bound and "≥" or "") .. tostring(data.streak))
    if not data.fetched_at or os.time() - data.fetched_at >= Profile.TTL or os.time() < data.fetched_at then
        text = text .. " · " .. _("Cached")
    end
    return text
end

function M:homeShortcuts(preferences)
    if not preferences.show_shortcuts then return {} end
    local actions = {
        shelf = function() self:closeWeReadUI() self:showBookshelf() end,
        store = function() self:closeWeReadUI() self:showBookstore() end,
        search = function() self:showDiscoverySearch() end,
        profile = function() self:closeWeReadUI() self:showProfile() end,
        settings = function() self:showHomeQuickSettings() end,
        refresh = function()
            self:refreshBookshelf(self.shelf_view, { on_loaded = function() self:showHome(true) end })
        end,
    }
    local result = {}
    for _i, key in ipairs(preferences.shortcuts) do
        result[#result + 1] = { text = _(shortcut_labels[key]), callback = actions[key] }
    end
    return result
end

function M:homeControlsOpen()
    return self._home_controls_menu ~= nil or self._home_prefetch_confirmation ~= nil
end

function M:closeHomeControls(redraw)
    local menu = self._home_controls_menu
    self._home_controls_menu = nil
    if menu then UIManager:close(menu) end
    local pending = self._home_pending_redraw
    self._home_pending_redraw = nil
    if redraw and pending and self.shelf_view and self.shelf_view.home_layout then pending() end
end

function M:_showHomeMenu(title, items)
    self:closeHomeControls(true)
    local function wrap(rows)
        for _, item in ipairs(rows) do
            if item.callback then item.callback = self:safeCallback(title, item.callback) end
            if item.sub_item_table then wrap(item.sub_item_table) end
        end
    end
    wrap(items)
    local menu = self:showList(title, items)
    self._home_controls_menu = menu
    menu.close_callback = function()
        if self._home_controls_menu == menu then
            self._home_controls_menu = nil
            self:closeHomeControls(true)
        end
    end
    return menu
end

function M:_changeHomePreference(change)
    local previous = self:homePreferences()
    local preferences = Layout.normalize(previous)
    change(preferences)
    local ok = pcall(function()
        self.settings:set("home", Layout.normalize(preferences))
        if self.settings:flush() == false then error("write_failed") end
    end)
    if not ok then
        pcall(self.settings.set, self.settings, "home", previous)
        self:closeHomeControls(true)
        self:showInfo(_("Could not save home settings."))
        return
    end
    local home_visible = self.shelf_view and self.shelf_view.home_layout
    self:closeHomeControls(false)
    if home_visible then self:showHome() end
    self:showHomeLayoutSettings()
end

function M:showHomeLayoutSettings()
    local preferences = self:homePreferences()
    local function set(key, value)
        return function() self:_changeHomePreference(function(next_preferences) next_preferences[key] = value end) end
    end
    local function checked(text, state) return (state and "✓ " or "○ ") .. text end
    local items = {
        { text = _("Home book display"), sub_item_table = {
            { text = checked(_("Cover grid"), preferences.view_mode == "cover"), callback = set("view_mode", "cover") },
            { text = checked(_("List view"), preferences.view_mode == "list"), callback = set("view_mode", "list") },
        } },
        { text = _("Cover density"), sub_item_table = {
            { text = checked(_("Comfortable"), preferences.density == "comfortable"), callback = set("density", "comfortable") },
            { text = checked(_("Compact"), preferences.density == "compact"), callback = set("density", "compact") },
        } },
        { text = _("Recent reading count"), sub_item_table = {} },
    }
    for _i, limit in ipairs({ 6, 12, 24 }) do
        items[3].sub_item_table[#items[3].sub_item_table + 1] = {
            text = checked(tostring(limit), preferences.recent_limit == limit), callback = set("recent_limit", limit),
        }
    end
    for _i, key in ipairs({ "status", "summary", "shortcuts" }) do
        items[#items + 1] = { text = checked(_(section_labels[key]), preferences["show_" .. key]),
            callback = set("show_" .. key, not preferences["show_" .. key]) }
    end
    local section_items, shortcut_items = {}, {}
    for index, key in ipairs(preferences.sections) do
        local function move(delta)
            return function() self:_changeHomePreference(function(next_preferences)
                next_preferences.sections = Layout.move(next_preferences.sections, key, delta)
            end) end
        end
        section_items[#section_items + 1] = { text = _(section_labels[key]), sub_item_table = {
            { text = _("Move up"), select_enabled = index > 1, callback = move(-1) },
            { text = _("Move down"), select_enabled = index < #preferences.sections, callback = move(1) },
        } }
    end
    local function shortcut_item(key, index)
        local entries = {
            { text = index and _("Hide shortcut") or _("Show shortcut"), callback = function()
                if not index and #preferences.shortcuts >= 4 then
                    self:closeHomeControls(true)
                    self:showInfo(_("Choose at most 4 home shortcuts."))
                    return
                end
                self:_changeHomePreference(function(next_preferences)
                    local values = next_preferences.shortcuts
                    if index then table.remove(values, index)
                    elseif #values < 4 then values[#values + 1] = key end
                end)
            end },
        }
        if index then
            for _i, delta in ipairs({ -1, 1 }) do
                entries[#entries + 1] = { text = delta < 0 and _("Move up") or _("Move down"),
                    select_enabled = index + delta >= 1 and index + delta <= #preferences.shortcuts,
                    callback = function() self:_changeHomePreference(function(next_preferences)
                        next_preferences.shortcuts = Layout.move(next_preferences.shortcuts, key, delta)
                    end) end }
            end
        end
        return { text = checked(_(shortcut_labels[key]), index ~= nil), sub_item_table = entries }
    end
    local selected = {}
    for index, key in ipairs(preferences.shortcuts) do selected[key] = true shortcut_items[#shortcut_items + 1] = shortcut_item(key, index) end
    for _i, key in ipairs(Layout.SHORTCUTS) do if not selected[key] then shortcut_items[#shortcut_items + 1] = shortcut_item(key) end end
    items[#items + 1] = { text = _("Home section order"), sub_item_table = section_items }
    items[#items + 1] = { text = _("Configure home shortcuts"), sub_item_table = shortcut_items }
    items[#items + 1] = { text = _("Restore default home layout"), callback = function()
        self:_changeHomePreference(function(next_preferences)
            for key in pairs(next_preferences) do next_preferences[key] = nil end
        end)
    end }
    return self:_showHomeMenu(_("Home layout"), items)
end

function M:showHomeQuickSettings()
    local function dismiss() self:closeHomeControls(true) end
    local cache = self.settings:get("cache")
    local items = {
        { text = _("Home layout"), callback = function() dismiss() self:showHomeLayoutSettings() end },
        { text = (cache.download_book_images and "✓ " or "○ ") .. _("Download book images"), callback = function()
            dismiss()
            cache.download_book_images = not cache.download_book_images
            self.settings:set("cache", cache)
            self.settings:flush()
            self:showHomeQuickSettings()
        end },
        { text = (cache.auto_prefetch_next_chapter and "✓ " or "○ ") .. _("Automatically prefetch next chapter"),
            callback = function()
                dismiss()
                if cache.auto_prefetch_next_chapter then self:setChapterPrefetchEnabled(false) return end
                local box
                box = require("ui/widget/confirmbox"):new{
                    text = _("Automatic prefetch runs in a background process and uses extra network and storage. Enable it?"),
                    ok_callback = function() self._home_prefetch_confirmation = nil self:setChapterPrefetchEnabled(true) self:closeHomeControls(true) end,
                    cancel_callback = function() self._home_prefetch_confirmation = nil self:closeHomeControls(true) end,
                }
                self._home_prefetch_confirmation = box
                UIManager:show(box)
            end },
        { text = _("Frontlight"), select_enabled = Device:hasFrontlight(),
            callback = function() if Device:hasFrontlight() then dismiss() Device:showLightDialog() end end },
    }
    local loaded, network = pcall(require, "ui/network/manager")
    if loaded and network.getWifiMenuTable then
        local native = network:getWifiMenuTable()
        local epoch = self.discovery_epoch or 0
        items[#items + 1] = { text = _("Wi-Fi settings"), select_enabled = not native.enabled_func or native.enabled_func(),
            callback = function()
                if native.enabled_func and not native.enabled_func() then return end
                dismiss()
                native.callback({ updateItems = function()
                    if (self.discovery_epoch or 0) == epoch and self.shelf_view and self.shelf_view.home_layout then
                        self:showHomeQuickSettings()
                    end
                end })
            end }
    end
    return self:_showHomeMenu(_("Quick settings"), items)
end

return M
