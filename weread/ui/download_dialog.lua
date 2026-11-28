local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local ProgressWidget = require("ui/widget/progresswidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local time = require("ui/time")
local Screen = Device.screen

local DownloadDialog = InputContainer:extend{
    title = "",
    description = nil,
    progress_max = 100,
    buttons = nil,
    refresh_time_seconds = 3,
}

function DownloadDialog:init()
    self.dimen = Screen:getSize()
    self.last_redraw_time_ms = 0

    local width = Screen:getWidth() - Screen:scaleBySize(80)

    local vertical_group = VerticalGroup:new{}

    self.title_widget = TextWidget:new{
        text = self.title or "",
        face = Font:getFace("ffont"),
        bold = true,
        max_width = width,
    }
    self.title_container = CenterContainer:new{
        dimen = Geom:new{
            w = width,
            h = self.title_widget:getSize().h,
        },
        self.title_widget,
    }
    table.insert(vertical_group, self.title_container)

    if self.description and self.description ~= "" then
        self.description_widget = TextBoxWidget:new{
            text = self.description,
            face = Font:getFace("xx_smallinfofont"),
            width = width,
            alignment = "center",
        }
        self.description_container = CenterContainer:new{
            dimen = Geom:new{
                w = width,
                h = self.description_widget:getSize().h,
            },
            self.description_widget,
        }
        table.insert(vertical_group, VerticalSpan:new{ width = Size.padding.small })
        table.insert(vertical_group, self.description_container)
    end

    if self.progress_max and self.progress_max > 0 then
        self.progress_bar = ProgressWidget:new{
            fillcolor = Blitbuffer.COLOR_BLACK,
            width = width,
            height = Screen:scaleBySize(18),
            padding = Size.padding.large,
            margin = Size.margin.tiny,
            percentage = 0,
        }
        table.insert(vertical_group, self.progress_bar)
    end

    if self.buttons then
        local button_table = ButtonTable:new{
            width = width,
            buttons = self.buttons,
            zero_sep = true,
            show_parent = self,
        }
        table.insert(vertical_group, VerticalSpan:new{ width = Size.padding.large })
        table.insert(vertical_group, button_table)
    end

    self._dialog_frame = FrameContainer:new{
        radius = Size.radius.window,
        bordersize = Size.border.window,
        padding = Size.padding.large,
        padding_bottom = self.buttons and 0 or nil,
        background = Blitbuffer.COLOR_WHITE,
        vertical_group,
    }
    self[1] = CenterContainer:new{
        dimen = Screen:getSize(), self._dialog_frame,
    }
end

-- Evaluated after painting, when the frame has its actual screen coordinates.
-- Fall back to the whole current screen if its geometry is unavailable,
-- extends beyond the screen, or the display rotated since this dialog opened.
function DownloadDialog:_progressRegion()
    local screen = Screen:getSize()
    local widget = self._dialog_frame
    local frame = widget and widget.dimen
    if not frame or not self.dimen or self.dimen.w ~= screen.w or self.dimen.h ~= screen.h
        or not frame.x or not frame.y or not frame.w or not frame.h
        or frame.x < 0 or frame.y < 0 or frame.w <= 0 or frame.h <= 0
        or frame.x + frame.w > screen.w or frame.y + frame.h > screen.h then return screen end
    -- FrameContainer may retain its old dimen if its contents change size.
    -- In that case a partial update could leave pixels from the old frame.
    local ok, size = pcall(widget.getSize, widget)
    if not ok or not size or size.w ~= frame.w or size.h ~= frame.h then return screen end
    return frame
end

function DownloadDialog:_cancelProgressRefresh()
    if self._progress_refresh then
        UIManager:unschedule(self._progress_refresh)
        self._progress_refresh = nil
    end
end

function DownloadDialog:_paintProgress(now)
    self:_cancelProgressRefresh()
    self.last_redraw_time_ms = now or time.now()
    UIManager:setDirty(self, function() return "fast", self:_progressRegion() end)
    UIManager:forceRePaint()
end

-- A title supplied together with progress is one update. Rapid updates are
-- coalesced, with a scheduled flush so a slow next operation cannot leave the
-- last title and bar hidden indefinitely.
function DownloadDialog:reportProgress(progress, title)
    if self._progress_closed then return end
    if not self.progress_bar then
        if title ~= nil then self:setTitle(title) end
        return
    end
    local changed = false
    if title ~= nil and self.title ~= title then
        self.title = title
        if self.title_widget and self.title_widget.setText then self.title_widget:setText(title) end
        changed = true
    end
    local previous = self.progress_bar.percentage
    self.progress_bar:setPercentage(progress / self.progress_max)
    changed = changed or previous ~= self.progress_bar.percentage
    local now = time.now()
    local elapsed = now - self.last_redraw_time_ms
    if self.progress_bar.percentage >= 1 or elapsed >= self.refresh_time_seconds * 1000 * 1000 then
        if title == nil or changed or self._progress_refresh then self:_paintProgress(now) end
    elseif title ~= nil and changed and not self._progress_refresh and not self._progress_closed then
        local task
        task = function()
            if self._progress_refresh ~= task or self._progress_closed then return end
            self._progress_refresh = nil
            self:_paintProgress()
        end
        self._progress_refresh = task
        local remaining = self.refresh_time_seconds * 1000 * 1000 - elapsed
        UIManager:scheduleIn(math.max(0, time.to_s(remaining)), task)
    end
end

function DownloadDialog:setTitle(title)
    if self._progress_closed then return end
    title = title or ""
    if self.title == title then return end
    self.title = title
    if self.title_widget and self.title_widget.setText then
        self.title_widget:setText(self.title)
        if self._progress_refresh then self:_paintProgress()
        else
            UIManager:setDirty(self, function() return "fast", self:_progressRegion() end)
            UIManager:forceRePaint()
        end
    end
end

function DownloadDialog:show()
    self._progress_closed = false
    UIManager:show(self, "ui")
end

function DownloadDialog:close()
    self._progress_closed = true
    self:_cancelProgressRefresh()
    UIManager:close(self, "ui")
end

function DownloadDialog:onCloseWidget()
    self._progress_closed = true
    self:_cancelProgressRefresh()
    if InputContainer.onCloseWidget then return InputContainer.onCloseWidget(self) end
end

return DownloadDialog
