-- Reading-report settings, target selection, and statistics UI.
local UIManager = require("ui/uimanager")

local PluginUtil = require("weread.lib.plugin_util")
local _ = PluginUtil.tr
local T = PluginUtil.T

local M = {}

function M:getReadReportMenuItems()
    local rr = self.settings:get("read_report")
    return {
        {
            text = _("Enable reading time report"),
            keep_menu_open = true,
            check_callback_updates_menu = true,
            checked_func = function()
                return self.settings:get("read_report").enabled
            end,
            callback = self:safeCallback(_("Enable reading time report"), function(touchmenu_instance)
                local cur = self.settings:get("read_report")
                cur.enabled = not cur.enabled
                self.settings:set("read_report", cur)
                self.settings:flush()
                if touchmenu_instance then
                    touchmenu_instance:updateItems()
                end
                if cur.enabled then
                    if cur.mode == "auto" then
                        self:maybeStartReadReport()
                    elseif cur.book_id == "" then
                        self:showTransientInfo(_("Please select a target book"), 2)
                        self:showReadReportBookPicker()
                    else
                        self:maybeStartReadReport()
                    end
                else
                    self:stopReadReport()
                end
            end),
        },
        {
            text = _("Only report when reading"),
            keep_menu_open = true,
            check_callback_updates_menu = true,
            checked_func = function()
                return self.settings:get("read_report").report_on_open ~= false
            end,
            callback = self:safeCallback(_("Only report when reading"), function(touchmenu_instance)
                local cur = self.settings:get("read_report")
                cur.report_on_open = cur.report_on_open == false
                self.settings:set("read_report", cur)
                self.settings:flush()
                if touchmenu_instance then
                    touchmenu_instance:updateItems()
                end
                self:stopReadReport("trigger_mode_changed")
                if cur.enabled then
                    self:maybeStartReadReport()
                end
            end),
        },
        {
            text_func = function()
                local interval = tonumber(self.settings:get("read_report").interval_seconds) or 30
                return T(_("Report interval: %1 s"), interval)
            end,
            keep_menu_open = true,
            sub_item_table_func = function()
                return self:getReportIntervalMenuItems()
            end,
        },
        {
            text_func = function()
                local current = self.settings:get("read_report")
                if current.mode == "manual" and current.book_title ~= "" then
                    return _("Select target book") .. " · " .. current.book_title
                end
                return _("Select target book")
            end,
            post_text = rr.mode == "auto" and _("Auto-associate") or nil,
            sub_item_table_func = function()
                return self:getReportTargetMenuItems()
            end,
        },
        {
            text = _("Report status"),
            keep_menu_open = true,
            callback = self:safeCallback(_("Report status"), function()
                self:onShowWeReadReportStatus()
            end),
        },
        {
            text = _("Record offline reading time locally"),
            keep_menu_open = true, check_callback_updates_menu = true,
            checked_func = function() return self.settings:get("offline_time", {}).enabled == true end,
            callback = self:safeCallback(_("Record offline reading time locally"), function(menu)
                local enabled = self.settings:get("offline_time", {}).enabled == true
                if self.offline_time then self.offline_time:stop("disabled") end
                local ok = pcall(function()
                    self.settings:set("offline_time", { enabled = not enabled })
                    if self.settings:flush() == false then error("write_failed") end
                end)
                if not ok then
                    self.settings:set("offline_time", { enabled = enabled })
                    self:showInfo(_("Could not save offline time settings."))
                end
                if self.offline_time then self.offline_time:start() end
                if menu then menu:updateItems() end
            end),
        },
        {
            text = _("Offline reading time"),
            callback = self:safeCallback(_("Offline reading time"), function() self:showOfflineTimeStatus() end),
        },
    }
end

function M:showOfflineTimeStatus()
    if not self.offline_time then return end
    self.offline_time:update("status")
    local status = self.offline_time:status()
    local labels = {
        recording = "Recording offline reading", online = "Online; offline recording is idle",
        disabled = "Disabled", paused = "Paused", no_book = "Open a WeRead book to record time",
        reader_hidden = "Return to the reading page to record time",
        book_mismatch = "This file does not match the reading book; time is not recorded",
        unsupported_book = "Offline time recording is unavailable for public-account articles",
        account_unavailable = "Log in to associate offline reading time",
        statistics_unavailable = "Enable KOReader Reading statistics to record time",
        clock_unavailable = "Device clock is unavailable", clock_changed = "Device clock changed; recording is waiting",
        storage_error = "Could not save offline reading time", storage_unavailable = "Could not save offline reading time",
        ledger_full = "Offline reading time storage is full", network_unavailable = "Waiting for a known network state",
    }
    self:showInfo(T(_("Locally saved, not uploaded: %1 s"), status.pending + status.in_flight + status.unknown)
        .. "\n" .. _(labels[status.error or status.state] or "Could not save offline reading time")
        .. "\n\n" .. _("Offline time stays on this device until cloud transfer is available."))
end

-- Preset reporting intervals. A longer interval means fewer network wake-ups,
-- which matters on battery-powered e-ink devices.
function M:getReportIntervalMenuItems()
    local items = {}
    for _i, seconds in ipairs({ 30, 60 }) do
        local label = T(_("%1 seconds"), seconds)
        items[#items + 1] = {
            text = label,
            keep_menu_open = true,
            check_callback_updates_menu = true,
            checked_func = function()
                local current = tonumber(self.settings:get("read_report").interval_seconds) or 30
                return current == seconds
            end,
            callback = self:safeCallback(label, function(touchmenu_instance)
                local cur = self.settings:get("read_report")
                if (tonumber(cur.interval_seconds) or 30) == seconds then
                    return
                end
                cur.interval_seconds = seconds
                self.settings:set("read_report", cur)
                self.settings:flush()
                -- Hand the new interval to the running session instead of
                -- restarting it: a report already in flight is allowed to
                -- finish and write back its result.
                if self.read_report then
                    self.read_report:reschedule("interval_changed")
                end
                if touchmenu_instance then
                    touchmenu_instance:updateItems()
                end
            end),
        }
    end
    return items
end

function M:onShowWeReadReportStatus()
    local cur = self.settings:get("read_report")
    local report_status = self.read_report:status()
    local target
    if cur.mode == "auto" then
        local auto_title = report_status.target_book_title
        target = auto_title and T(_("Auto: %1"), auto_title) or _("Auto-associate")
    else
        target = cur.book_title ~= "" and cur.book_title or _("Not configured")
    end
    local status = report_status.running and _("Running") or _("Stopped")
    local count = report_status.count
    local last = report_status.last_time
        and os.date("%H:%M:%S", report_status.last_time) or "--"
    local err = report_status.last_error or ""
    local msg = T(_("Report book: %1\nStatus: %2"), target, status)
        .. "\n" .. T(_("Reported: %1 times, last: %2"), tostring(count), last)
    if err ~= "" then
        msg = msg .. "\n" .. T(_("Last error: %1"), err)
    end
    self:showInfo(msg)
    return true
end

function M:getReportTargetMenuItems()
    local rr = self.settings:get("read_report")
    return {
        {
            text = _("Auto-associate with WeRead book"),
            keep_menu_open = true,
            check_callback_updates_menu = true,
            checked_func = function()
                return self.settings:get("read_report").mode == "auto"
            end,
            callback = self:safeCallback(_("Auto-associate with WeRead book"), function(touchmenu_instance)
                local cur = self.settings:get("read_report")
                cur.mode = "auto"
                cur.book_id = ""
                cur.book_title = ""
                self.settings:set("read_report", cur)
                self.settings:flush()
                if touchmenu_instance then
                    touchmenu_instance:updateItems()
                end
                self:stopReadReport("target_changed")
                if cur.enabled then
                    self:maybeStartReadReport()
                end
            end),
        },
        {
            text = _("Manually set report book"),
            keep_menu_open = true,
            check_callback_updates_menu = true,
            checked_func = function()
                return self.settings:get("read_report").mode == "manual"
            end,
            post_text = rr.mode == "manual" and rr.book_title ~= "" and rr.book_title or "",
            callback = self:safeCallback(_("Manually set report book"), function(touchmenu_instance)
                local cur = self.settings:get("read_report")
                cur.mode = "manual"
                self.settings:set("read_report", cur)
                self.settings:flush()
                if touchmenu_instance then
                    touchmenu_instance:updateItems()
                end
                self:stopReadReport("target_changed")
                self:showReadReportBookPicker()
            end),
        },
    }
end

function M:showReadReportBookPicker()
    if not self:requireLogin(true, true) then
        return
    end
    self:refreshBookshelf(nil, {
        mode = "books",
        wp_enable = false,
        title = _("Select a book to report reading time"),
        on_select = function(book, selected_mode, view)
            if selected_mode ~= "books" then return end
            local book_id = book.book_id or book.bookId
            if not book_id then return end
            local rr = self.settings:get("read_report")
            rr.mode = "manual"
            rr.book_id = book_id
            rr.book_title = book.title or book_id
            self.settings:set("read_report", rr)
            self.settings:flush()
            self:stopReadReport("target_changed")
            UIManager:close(view)
            if self.shelf_view == view then self.shelf_view = nil end
            self:showTransientInfo(T(_("Target book set: %1"), rr.book_title))
            self:maybeStartReadReport()
        end,
    })
end

function M:showReadStats()
    self:loadReadStats("monthly", nil, nil)
end

function M:cancelReadStatsRequest()
    return require("weread.ui.statistics_request").cancel(self)
end

function M:loadReadStats(mode, base_time, old_view)
    return require("weread.ui.statistics_request").load(self, mode, base_time, old_view)
end

return M
