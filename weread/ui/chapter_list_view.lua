-- Chapter catalog styled consistently with the book detail page.

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local Device = require("device")
local Font = require("ui/font")
local FocusManager = require("ui/widget/focusmanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Screen = Device.screen
local FocusNav = require("weread.ui.focus_nav")
local I18n = require("weread.lib.i18n")
local ListPaint = require("weread.lib.shelf_list_paint")
local ListEvents = require("weread.lib.shelf_list_events")

local function _(text) return I18n.tr(text) end

-- Keep offscreen row geometry for physical-key navigation while avoiding
-- rendering and gesture dispatch to every chapter on each scroll.
local ChapterGroup = VerticalGroup:extend{}
function ChapterGroup:paintTo(bb, x, y)
    ListPaint.paint(self, bb, x, y, require('ui/bidi').mirroredUILayout())
    self._rows_positioned = true
end
function ChapterGroup:propagateEvent(event)
    local routed, consumed = ListEvents.dispatch(self._rows, self._rows_positioned, event)
    if routed then return consumed end
    return VerticalGroup.propagateEvent(self, event)
end

local ChapterRow = InputContainer:extend{
    text = "",
    status = "",
    width = nil,
    callback = nil,
    show_parent = nil,
}

local function chapter_frame(self)
    local padding = Size.padding.large
    local inner_width = self.width - 2 * padding
    local face = Font:getFace("cfont", 20)
    local right = TextWidget:new{ text = self.status, face = face }
    local right_width = right:getSize().w
    local gap = Size.padding.large
    local left = TextWidget:new{
        text = self.text,
        face = face,
        max_width = math.max(1, inner_width - right_width - gap),
    }
    gap = math.max(gap, inner_width - left:getSize().w - right_width)
    return FrameContainer:new{
        bordersize = 0, radius = 0, margin = 0,
        padding_left = padding, padding_right = padding,
        padding_top = Size.padding.large,
        padding_bottom = Size.padding.large,
        background = Blitbuffer.COLOR_WHITE,
        show_parent = self.show_parent,
        HorizontalGroup:new{
            align = "center",
            left,
            HorizontalSpan:new{ width = gap },
            right,
        },
    }
end

function ChapterRow:_ensureFrame()
    if self.frame then return end
    self.frame = chapter_frame(self)
    self.frame.invert = self._chapter_focused or false
    self[1] = self.frame
end

function ChapterRow:init()
    if self.lazy_row_height then
        local status = self.status or ""
        local status_width = self.status_widths[status]
        if status_width == nil then
            local right = TextWidget:new{ text = status, face = Font:getFace("cfont", 20) }
            status_width = right:getSize().w
            if right.free then right:free() end
            self.status_widths[status] = status_width
        end
        local padding = Size.padding.large
        local inner_width = self.width - 2 * padding
        local left = TextWidget:new{ text = self.text, face = Font:getFace("cfont", 20),
            max_width = math.max(1, inner_width - status_width - padding) }
        local left_width = left:getSize().w
        if left.free then left:free() end
        local gap = math.max(padding, inner_width - left_width - status_width)
        self.dimen = Geom:new{ w = left_width + status_width + gap + 2 * padding, h = self.lazy_row_height }
    else
        self:_ensureFrame()
        self.dimen = self.frame:getSize()
    end
    self.ges_events = {
        TapChapterRow = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
end

function ChapterRow:paintTo(bb, x, y)
    self:_ensureFrame()
    return InputContainer.paintTo(self, bb, x, y)
end

function ChapterRow:setOffscreenGeometry(x, y)
    self.dimen.x, self.dimen.y = x, y
    if self.frame then
        self.frame:free()
        self.frame, self[1] = nil, nil
    end
end

function ChapterRow:onTapChapterRow()
    if not self.callback then return true end
    self:_ensureFrame()
    if not self.frame.dimen then self.frame.dimen = self.dimen:copy() end
    self.frame.invert = true
    UIManager:widgetRepaint(self.frame, self.frame.dimen.x, self.frame.dimen.y)
    UIManager:forceRePaint()
    self.frame.invert = false
    self._chapter_focused = false
    UIManager:widgetRepaint(self.frame, self.frame.dimen.x, self.frame.dimen.y)
    UIManager:setDirty(nil, "fast", self.frame.dimen)
    self.callback()
    return true
end

function ChapterRow:onFocus()
    self._chapter_focused = true
    if self.frame then self.frame.invert = true end
    return true
end

function ChapterRow:onUnfocus()
    self._chapter_focused = false
    if self.frame then self.frame.invert = false end
    return true
end

local ChapterListView = FocusManager:extend{
    title = nil,
    chapters = nil,
    on_refresh = nil,
    on_select_download = nil,
    on_select = nil,
    on_close = nil,
}

function ChapterListView:toolbar()
    local half = math.floor(self.screen_w / 2)
    local refresh_button = Button:new{
        text = _("↻ Refresh chapter list"),
        width = half,
        radius = 0, margin = 0,
        bordersize = Size.border.thin,
        text_font_size = 19,
        text_font_bold = false,
        show_parent = self,
        callback = function() if self.on_refresh then self.on_refresh() end end,
    }
    local select_button = Button:new{
        text = _("✓ Select chapters to download"),
        width = self.screen_w - half,
        radius = 0, margin = 0,
        bordersize = Size.border.thin,
        text_font_size = 19,
        text_font_bold = false,
        show_parent = self,
        callback = function()
            if self.on_select_download then self.on_select_download() end
        end,
    }
    self._toolbar_buttons = { refresh_button, select_button }
    return HorizontalGroup:new{ refresh_button, select_button }
end

function ChapterListView:content()
    local group = ChapterGroup:new{
        align = "left",
        HorizontalSpan:new{ width = self.list_width },
    }
    self._chapter_rows = {}
    group._rows = self._chapter_rows
    local probe = ChapterRow:new{ text = "", status = "", width = self.list_width }
    local height = probe:getSize().h
    probe:free()
    local status_widths = {}
    for _i, chapter in ipairs(self.chapters or {}) do
        local row = ChapterRow:new{
            text = chapter.title,
            status = chapter.status,
            width = self.list_width,
            lazy_row_height = height,
            status_widths = status_widths,
            _shelf_list_row = true,
            show_parent = self,
            callback = function()
                if self.on_select then self.on_select(chapter.source) end
            end,
        }
        self._chapter_rows[#self._chapter_rows + 1] = row
        table.insert(group, row)
        table.insert(group, HorizontalGroup:new{
            HorizontalSpan:new{ width = Size.padding.large },
            LineWidget:new{
                dimen = Geom:new{ w = self.list_width - 2 * Size.padding.large, h = 1 },
                background = Blitbuffer.COLOR_GRAY,
            },
        })
    end
    return group
end

function ChapterListView:init()
    self.screen_w = Screen:getWidth()
    self.screen_h = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }
    self.list_width = self.screen_w - 3 * Screen:scaleBySize(6)
    self.covers_fullscreen = true
    if Device:hasKeys() then self.key_events.Close = { { Device.input.group.Back } } end
    self.title_bar = TitleBar:new{
        width = self.screen_w,
        title = self.title or _("Chapter list"),
        title_face = Font:getFace("tfont", 28),
        title_multilines = true,
        align = "center",
        with_bottom_line = true,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }
    local toolbar = self:toolbar()
    local scroll = ScrollableContainer:new{
        dimen = Geom:new{
            w = self.screen_w,
            h = self.screen_h - self.title_bar:getHeight() - toolbar:getSize().h,
        },
        show_parent = self,
        self:content(),
    }
    local rows = { self._toolbar_buttons }
    for _i, chapter_row in ipairs(self._chapter_rows) do
        rows[#rows + 1] = { chapter_row }
    end
    local outside_scroll = {}
    for _i, button in ipairs(self._toolbar_buttons) do outside_scroll[button] = true end
    FocusNav.apply(self, rows, { scroll = scroll, outside_scroll = outside_scroll })
    -- Chapters follow the toolbar row.
    FocusNav.initialFocus(self, 1, #rows > 1 and 2 or 1)
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0, padding = 0, margin = 0,
        dimen = self.dimen:copy(),
        VerticalGroup:new{ align = "left", self.title_bar, toolbar, scroll },
    }
end

function ChapterListView:onShow()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    return true
end

function ChapterListView:onCloseWidget()
    UIManager:setDirty(nil, function() return "ui", self.dimen end)
end

function ChapterListView:onClose()
    UIManager:close(self)
    if self.on_close then
        UIManager:scheduleIn(0.1, self.on_close)
    end
    return true
end

local M = {}
function M.show(data, callbacks)
    callbacks = callbacks or {}
    local view = ChapterListView:new{
        title = data.title,
        chapters = data.chapters,
        on_refresh = callbacks.on_refresh,
        on_select_download = callbacks.on_select_download,
        on_select = callbacks.on_select,
        on_close = callbacks.on_close,
    }
    UIManager:show(view)
    return view
end

return M
