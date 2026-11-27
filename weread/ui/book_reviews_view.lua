-- Full-screen, e-ink-friendly book review list with Recommended / Latest tabs.
-- This is a presentation-only widget; network loading is handled by main.lua.

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local Device = require("device")
local FocusManager = require("ui/widget/focusmanager")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen
local FocusNav = require("weread.ui.focus_nav")
local T = require("ffi/util").template

local BookReviews = require("weread.lib.book_reviews")
local I18n = require("weread.lib.i18n")
local ListPaint = require("weread.lib.shelf_list_paint")
local ListEvents = require("weread.lib.shelf_list_events")

-- Keep every button's position available to focus navigation while avoiding
-- text rendering for review rows that cannot appear on the screen.
local ReviewListGroup = VerticalGroup:extend{}
function ReviewListGroup:paintTo(bb, x, y)
    ListPaint.paint(self, bb, x, y, require('ui/bidi').mirroredUILayout())
    self._review_rows_positioned = true
end

-- Fixed-size rows retain their input geometry but build the native Button's
-- text and frame only when painted. Keep the same Geom object for the focus
-- layout and gesture ranges when the underlying Button is rebuilt.
local ReviewRow = Button:extend{}
local function review_row_gestures(self)
    self.ges_events = {
        TapSelectButton = { GestureRange:new{ ges = "tap", range = self.dimen } },
        HoldSelectButton = { GestureRange:new{ ges = "hold", range = self.dimen } },
        HoldReleaseSelectButton = { GestureRange:new{ ges = "hold_release", range = self.dimen } },
    }
end
function ReviewRow:init()
    self.dimen = Geom:new{ w = self.width,
        h = self.height + 2 * (self.padding_v or self.padding) + 2 * self.margin + 2 * self.bordersize }
    review_row_gestures(self)
end
function ReviewRow:_ensureButton()
    if self.frame then return end
    local geometry = self.dimen
    Button.init(self)
    local measured = self.dimen
    -- Geometry is fixed by the configured width and reference height. Keep
    -- the original object referenced by focus navigation and gesture ranges.
    assert(measured.w == geometry.w and measured.h == geometry.h, "review row geometry changed")
    self.dimen = geometry
    review_row_gestures(self)
    if not self.frame.dimen then self.frame.dimen = geometry:copy()
    else self.frame.dimen.x, self.frame.dimen.y = geometry.x, geometry.y end
    self.frame.invert = self._review_focused or false
end
function ReviewRow:paintTo(bb, x, y)
    self:_ensureButton()
    return Button.paintTo(self, bb, x, y)
end
function ReviewRow:setOffscreenGeometry(x, y)
    self.dimen.x, self.dimen.y = x, y
    if self.frame then
        self.frame:free()
        self.frame, self[1], self.label_widget, self.label_container = nil, nil, nil, nil
    end
end
function ReviewRow:onFocus()
    self._review_focused = true
    if self.frame then self.frame.invert = true end
    return true
end
function ReviewRow:onUnfocus()
    self._review_focused = false
    if self.frame then self.frame.invert = false end
    return true
end
function ReviewRow:onTapSelectButton(...)
    self:_ensureButton()
    return Button.onTapSelectButton(self, ...)
end
function ReviewListGroup:propagateEvent(event)
    local routed, consumed = ListEvents.dispatch(self._review_rows, self._review_rows_positioned, event)
    if routed then return consumed end
    return VerticalGroup.propagateEvent(self, event)
end

local function _(text)
    return I18n.tr(text)
end

local TABS = {
    { mode = "recommended", text = "Recommended reviews" },
    { mode = "latest", text = "Latest reviews" },
}
local NATIVE_TABS = {
    TABS[2],
    { mode = "five_stars", text = "Five-star reviews" },
}

local BookReviewsView = FocusManager:extend{
    book_title = nil,
    mode = "recommended",
    result = nil,
    on_switch = nil,
    on_select = nil,
    on_load_more = nil,
    on_close = nil,
    latest_only = false,
    native_filters = false,
    scroll_offset = nil,
    focus_row = nil,
    title_text = nil,
    tab_text = nil,
    empty_text = nil,
    incomplete_text = nil,
    limited_text = nil,
}

function BookReviewsView:buildTabBar()
    local tabs = self.native_filters and NATIVE_TABS or self.latest_only and { TABS[2] } or TABS
    local first_width = math.floor(self.screen_w / #tabs)
    local row = HorizontalGroup:new{}
    self._tab_buttons = {}
    for index, tab in ipairs(tabs) do
        local active = tab.mode == self.mode
        local button = Button:new{
            text = _(tab.mode == 'latest' and self.latest_only and self.tab_text or tab.text),
            width = index == #tabs
                and self.screen_w - first_width * (#tabs - 1)
                or first_width,
            radius = 0,
            margin = 0,
            bordersize = Size.border.thin,
            background = Blitbuffer.COLOR_WHITE,
            preselect = active,
            text_font_bold = active,
            show_parent = self,
            callback = function()
                if not active and self.on_switch then
                    self.on_switch(tab.mode)
                end
            end,
        }
        self._tab_buttons[#self._tab_buttons + 1] = button
        if active then
            -- Preselect is painted as an inverted frame; without this the
            -- focus cursor leaving the tab would erase its highlight.
            button.onUnfocus = function(_self)
                _self.frame.invert = true
                return true
            end
        end
        table.insert(row, button)
    end
    return FrameContainer:new{
        bordersize = 0,
        padding = 0,
        margin = 0,
        row,
    }
end

function BookReviewsView:reviewText(review)
    local metadata = {
        review.author ~= "" and review.author or _("Anonymous"),
    }
    if review.rating > 0 then
        metadata[#metadata + 1] = T(_("Score %1 / 5"), BookReviews.format_rating(review.rating))
    end
    local review_date = BookReviews.format_date(review.create_time)
    if review_date ~= "" then
        metadata[#metadata + 1] = review_date
    end
    local preview = BookReviews.preview(
        review.content ~= "" and review.content or _("No review content."), 80
    )
    return table.concat(metadata, " · ") .. "  |  " .. preview
end

function BookReviewsView:buildContent()
    local content = ReviewListGroup:new{
        align = "left",
        HorizontalSpan:new{ width = self.content_width },
    }
    self._review_buttons = {}
    content._review_rows = self._review_buttons
    if self.incomplete_text and not self.latest_only then
        table.insert(content, TextWidget:new{
            text = self.incomplete_text, face = Font:getFace("cfont", 16), max_width = self.content_width,
        })
        table.insert(content, VerticalSpan:new{ width = Size.padding.large })
    end
    local items = self.result and self.result.items or {}
    if #items == 0 then
        table.insert(content, VerticalSpan:new{ width = Size.padding.large })
        table.insert(content, TextWidget:new{
            text = _(self.empty_text or "No reviews."),
            face = Font:getFace("cfont", 18),
            max_width = self.content_width,
        })
    end

    for _i, review in ipairs(items) do
        local button = ReviewRow:new{
            text = self:reviewText(review),
            width = self.content_width,
            height = Screen:scaleBySize(66),
            align = "left",
            radius = 0,
            margin = 0,
            padding_h = Size.padding.large,
            padding_v = Size.padding.default,
            bordersize = Size.border.thin,
            background = Blitbuffer.COLOR_WHITE,
            text_font_bold = false,
            text_font_size = 18,
            show_parent = self,
            callback = function()
                if self.on_select then
                    self.on_select(review, self.mode)
                end
            end,
        }
        button._shelf_list_row = true
        self._review_buttons[#self._review_buttons + 1] = button
        table.insert(content, button)
        table.insert(content, VerticalSpan:new{ width = Size.padding.small })
    end
    if self.result and self.result.has_more and self.on_load_more then
        local button = Button:new{
            text = _("Load more results"),
            width = self.content_width,
            show_parent = self,
            callback = self.on_load_more,
        }
        button._shelf_list_row = true
        self._review_buttons[#self._review_buttons + 1] = button
        table.insert(content, button)
    end
    if self.latest_only then
        table.insert(content, VerticalSpan:new{ width = Size.padding.large })
        table.insert(content, TextWidget:new{
            text = self.result and self.result.limited
                and _(self.limited_text or "Review limit reached; more reviews may be available.")
                or _(self.incomplete_text or "Some reviews may be unavailable."),
            face = Font:getFace("cfont", 16),
            max_width = self.content_width,
        })
    elseif self.result and self.result.limited then
        table.insert(content, VerticalSpan:new{ width = Size.padding.large })
        table.insert(content, TextWidget:new{
            text = _("Review limit reached; more reviews may be available."),
            face = Font:getFace("cfont", 16), max_width = self.content_width,
        })
    end
    self._review_content = content
    return content
end

function BookReviewsView:init()
    self.screen_w = Screen:getWidth()
    self.screen_h = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }
    self.covers_fullscreen = true
    self.outer_margin = Size.padding.large
    local scrollbar_reserve = 3 * Screen:scaleBySize(6)
    self.content_width = self.screen_w - 2 * self.outer_margin - scrollbar_reserve

    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end

    self.title_bar = TitleBar:new{
        width = self.screen_w,
        title = T("%1 · %2", _(self.title_text or "Book reviews"), self.book_title or _("Untitled")),
        title_multilines = true,
        align = "center",
        with_bottom_line = true,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }
    local tab_bar = self:buildTabBar()
    local scroll_height = self.screen_h
        - self.title_bar:getHeight() - tab_bar:getSize().h
    local scroll = ScrollableContainer:new{
        dimen = Geom:new{ w = self.screen_w, h = scroll_height },
        show_parent = self,
        HorizontalGroup:new{
            HorizontalSpan:new{ width = self.outer_margin },
            VerticalGroup:new{
                align = "left",
                VerticalSpan:new{ width = self.outer_margin },
                self:buildContent(),
                VerticalSpan:new{ width = self.outer_margin },
            },
        },
    }
    self._review_scroll = scroll
    if self.scroll_offset then scroll:setScrolledOffset(self.scroll_offset) end
    local rows = { self._tab_buttons }
    for _i, review_button in ipairs(self._review_buttons) do
        rows[#rows + 1] = { review_button }
    end
    local outside_scroll = {}
    for _i, button in ipairs(self._tab_buttons) do outside_scroll[button] = true end
    FocusNav.apply(self, rows, { scroll = scroll, outside_scroll = outside_scroll })
    -- Reviews follow the tab row.
    FocusNav.initialFocus(self, 1, math.min(#rows, self.focus_row or (#rows > 1 and 2 or 1)))

    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        margin = 0,
        dimen = self.dimen:copy(),
        VerticalGroup:new{ align = "left", self.title_bar, tab_bar, scroll },
    }
end

function BookReviewsView:onShow()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    return true
end

function BookReviewsView:onCloseWidget()
    self._review_closed = true
    if self.on_close then self.on_close() end
    UIManager:setDirty(nil, function() return "ui", self.dimen end)
end

function BookReviewsView:onClose()
    UIManager:close(self)
    return true
end

local M = {}

function M.show(data, callbacks)
    callbacks = callbacks or {}
    local view = BookReviewsView:new{
        book_title = data.book_title,
        mode = data.mode,
        result = data.result,
        on_switch = callbacks.on_switch,
        on_select = callbacks.on_select,
        on_load_more = callbacks.on_load_more,
        on_close = callbacks.on_close,
        latest_only = data.latest_only == true,
        native_filters = data.native_filters == true,
        scroll_offset = data.scroll_offset,
        focus_row = data.focus_row,
        title_text = data.title_text,
        tab_text = data.tab_text,
        empty_text = data.empty_text,
        incomplete_text = data.incomplete_text,
        limited_text = data.limited_text,
    }
    UIManager:show(view)
    return view
end

return M
