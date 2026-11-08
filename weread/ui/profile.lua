local Data = require("weread.lib.profile")
local PluginUtil = require("weread.lib.plugin_util")
local UIManager = require("ui/uimanager")
local _ = PluginUtil.tr
local M = {}

function M:cancelProfileRefresh()
    local request = self.profile_request
    self.profile_request = nil
    if request and request.worker_request and self.profile_worker then
        self.profile_worker:cancel(request.worker_request, "profile_closed")
    end
end

function M:showProfile()
    if self.shelf_view or self._read_stats_view or self._book_detail_view or self._chapter_list_view then
        self:closeWeReadUI()
    end
    local account = self.settings:get("account", {})
    local snapshot = self.library_db:getProfileState("statistics")
    local goal = self.library_db:getProfileState("goal") or {}
    local data = Data.build(snapshot, goal.minutes)
    data.account_name = not self.library_db:accountKey() and _("Not logged in")
        or type(account.name) == "string" and account.name ~= "" and account.name or _("Unknown account")
    data.navigation = self:discoveryNavigation("profile")
    data.cached = data.has_data and (not data.fetched_at or os.time() - data.fetched_at >= Data.TTL
        or os.time() < data.fetched_at)
    if self._profile_view then
        local old = self._profile_view
        self._profile_view = nil
        UIManager:close(old)
    end
    local view
    view = require("weread.ui.read_stats_view").show(data, {
        on_refresh = function() self:refreshProfile(false) end,
        on_goal = function() self:showReadingGoal() end,
        on_statistics = function() self:cancelProfileRefresh() self:showReadStats() end,
        on_close = function()
            if self._profile_view == view then
                self._profile_view = nil
                self:closeWeReadUI()
            end
        end,
    })
    self._profile_view = view
    if not data.has_data or data.cached then self:refreshProfile(true) end
    return view
end

function M:refreshProfile(automatic)
    if self.profile_request then return end
    if automatic then
        if not self.library_db:accountKey() or not self.settings:is_api_configured() or not self:isNetworkOnline() then return end
    elseif not self:requireLogin(false, true) then return
    elseif not self:isNetworkOnline() then self:showOffline(_("Reading statistics")) return end
    local account, epoch = self.library_db:accountKey(), self.discovery_epoch or 0
    if not account then return end
    if not self.profile_worker then
        self.profile_worker = require("weread.lib.background_worker"):new{
            temp_dir = self.settings.data_dir .. "/workers", timeout = 30,
        }
    end
    if not self.profile_worker:available() then
        if not automatic then self:showInfo(_("This device cannot refresh My WeRead. Open Reading statistics instead.")) end
        return
    end
    local marker = {}
    self.profile_request = marker
    local started, request = self.profile_worker:start{
        kind = "profile", queue = true, replace_active = true,
        task = function(context) return Data.fetch(self.client, context) end,
        on_done = function(result)
            if self.profile_request ~= marker then return end
            self.profile_request = nil
            if self.library_db:accountKey() ~= account or (self.discovery_epoch or 0) ~= epoch then return end
            if not result.ok then
                if not automatic then self:showInfo(_("Could not refresh reading statistics. Your cached data is kept.")) end
                return
            end
            if not self.library_db:putProfileState("statistics", result.value) then
                if not automatic then self:showInfo(_("Could not refresh reading statistics. Your cached data is kept.")) end
                return
            end
            if self._profile_view and not self._profile_goal_dialog then self:showProfile() end
        end,
    }
    if started and self.profile_request == marker then marker.worker_request = request
    elseif not started and self.profile_request == marker then self.profile_request = nil end
end

function M:showReadingGoal()
    if not self.library_db:accountKey() then self:requireLogin(false, true) return end
    local InputDialog = require("ui/widget/inputdialog")
    local account = self.library_db:accountKey()
    local previous = self.library_db:getProfileState("goal") or {}
    local dialog
    local function close()
        if self._profile_goal_dialog == dialog then self._profile_goal_dialog = nil end
        UIManager:close(dialog)
        if self.library_db:accountKey() == account and self._profile_view then self:showProfile() end
    end
    dialog = InputDialog:new{
        title = _("Daily goal (this plugin)"),
        input = tostring(previous.minutes or Data.DEFAULT_GOAL), input_type = "number",
        input_hint = _("Minutes per day: 1–1440"),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = close },
            { text = _("Save"), is_enter_default = true, callback = function()
                local minutes = Data.goal(dialog:getInputText())
                if not minutes then self:showInfo(_("Enter a whole number from 1 to 1440.")) return end
                if self.library_db:accountKey() ~= account then close() return end
                if not self.library_db:putProfileState("goal", { minutes = minutes }) then
                    self:showInfo(_("Could not save the reading goal."))
                    return
                end
                close()
            end },
        }},
    }
    if self._profile_goal_dialog then UIManager:close(self._profile_goal_dialog) end
    self._profile_goal_dialog = dialog
    local on_close = dialog.onCloseWidget
    dialog.onCloseWidget = function(widget)
        if self._profile_goal_dialog == widget then self._profile_goal_dialog = nil end
        if on_close then return on_close(widget) end
    end
    self:showInputDialog(dialog)
end

return M
