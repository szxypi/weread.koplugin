-- Compact, e-ink-friendly bookshelf. Navigation and actions share one row.

local Blitbuffer = require("ffi/blitbuffer")
local BD = require("ui/bidi")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FocusManager = require("ui/widget/focusmanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local Screen = Device.screen
local FocusNav = require("weread.ui.focus_nav")
local I18n = require("weread.lib.i18n")
local ShelfFlags = require("weread.lib.shelf_flags")
local ShelfGroups = require("weread.lib.shelf_groups")
local ShelfProgress = require("weread.lib.shelf_progress")
local ShelfSnapshot = require("weread.lib.shelf_snapshot")
local ShelfTime = require("weread.lib.shelf_time")
local CoverLayout = require("weread.lib.cover_layout")
local CoverMask = require("weread.lib.cover_mask")
local ShelfListPaint = require("weread.lib.shelf_list_paint")
local ShelfListEvents = require("weread.lib.shelf_list_events")
local ShelfVisible = require("weread.lib.shelf_visible")
local CoverBitmapCache = require("weread.lib.shelf_cover_bitmap_cache")
local HomeLayout = require("weread.lib.home_layout")
local T = require("ffi/util").template
local HEADER_SIZE = 72
local icons_dir = debug.getinfo(1, "S").source:match("^@(.*/)") .. "../../icons/"

local function _(text) return I18n.tr(text) end

local CoverShadow = Widget:extend{
    width = 1,
    height = 1,
    radius = 1,
}

function CoverShadow:init()
    self.width = math.max(1, math.floor(tonumber(self.width) or 1))
    self.height = math.max(1, math.floor(tonumber(self.height) or 1))
    self.radius = math.max(1, math.floor(tonumber(self.radius) or 1))
    self.dimen = Geom:new{ w = self.width, h = self.height }
end

function CoverShadow:paintTo(bb, x, y)
    bb:paintRoundedRect(x, y, self.width, self.height, Blitbuffer.gray(0.5), self.radius)
end

-- ScrollableContainer paints its full child on each scroll, even though it
-- composites only the viewport. Skip offscreen list rows and dividers, but
-- keep every row's geometry current for gestures and physical-key focus.
local ShelfListGroup = VerticalGroup:extend{}
function ShelfListGroup:paintTo(bb, x, y)
    if self._status_view then self._status_view:prepareVisibleStatus() end
    ShelfListPaint.paint(self, bb, x, y, require('ui/bidi').mirroredUILayout())
    self._shelf_rows_positioned = true
end
function ShelfListGroup:propagateEvent(event)
    local routed, consumed = ShelfListEvents.dispatch(self._shelf_rows, self._shelf_rows_positioned, event)
    if routed then return consumed end
    return VerticalGroup.propagateEvent(self, event)
end

-- FrameContainer does not clip its child to its radius. This card masks the
-- four image corners before painting one anti-aliased border, so the cover,
-- border, and drop shadow all share the same smooth geometry.
local RoundedCoverCard = Widget:extend{
    inner = nil,
    width = 1,
    height = 1,
    radius = 0,
    border_size = 0,
    shadow_offset = 0,
    shadow_color = nil,
    white_background = false,
}

function RoundedCoverCard:init()
    self.width = math.max(1, math.floor(tonumber(self.width) or 1))
    self.height = math.max(1, math.floor(tonumber(self.height) or 1))
    self.radius = math.max(0, math.floor(tonumber(self.radius) or 0))
    self.border_size = math.max(0, math.floor(tonumber(self.border_size) or 0))
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.corner_spans = CoverMask.spans(self.width, self.height, self.radius,
        self.shadow_offset, not not self.shadow_color)
end

function RoundedCoverCard:free(...)
    if self.inner and self.inner.free then self.inner:free(...) end
end

-- Plain Widget wrappers do not forward CloseWidget to their owned content.
RoundedCoverCard.onCloseWidget = RoundedCoverCard.free

function RoundedCoverCard:paintTo(bb, x, y)
    if self.white_background then
        bb:paintRect(x, y, self.width, self.height, Blitbuffer.COLOR_WHITE)
    end
    if self.inner then self.inner:paintTo(bb, x + self.border_size, y + self.border_size) end
    local radius = self.radius
    for _, span in ipairs(self.corner_spans) do
        bb:paintRect(x + span.x, y + span.y, span.width, 1,
            span.color == "shadow" and self.shadow_color or Blitbuffer.COLOR_WHITE)
    end
    if self.border_size > 0 then
        bb:paintBorder(x, y, self.width, self.height, self.border_size,
            Blitbuffer.COLOR_BLACK, radius, true)
    end
end

local FinishedBadge = Widget:extend{}

function FinishedBadge:init()
    self.label = TextWidget:new{
        text = self.label_text or _("Read complete"),
        face = Font:getFace("cfont", 9),
    }
    -- Chinese glyphs occupy their line box unevenly. Use separate horizontal
    -- and vertical padding so the visible whitespace around “读完” is balanced.
    self.padding_x = math.max(1, Screen:scaleBySize(2))
    self.padding_y = 1
    local label_size = self.label:getSize()
    self.width = math.max(Screen:scaleBySize(20), label_size.w + 2 * self.padding_x)
    self.height = label_size.h + 2 * self.padding_y
    self.dimen = Geom:new{ w = self.width, h = self.height }
end

function FinishedBadge:paintTo(bb, x, y)
    bb:paintRect(x, y, self.width, self.height, Blitbuffer.COLOR_WHITE)
    bb:paintBorder(x, y, self.width, self.height, Size.border.thin,
        Blitbuffer.COLOR_BLACK, 0, true)
    local label_size = self.label:getSize()
    self.label:paintTo(bb,
        x + math.floor((self.width - label_size.w) / 2),
        y + math.floor((self.height - label_size.h) / 2))
end

function FinishedBadge:free(...)
    if self.label and self.label.free then self.label:free(...) end
end

FinishedBadge.onCloseWidget = FinishedBadge.free

-- WeRead marks private reading with a black corner pennant and a white mask.
-- The badge honours the cover's rounded silhouette, so it does not square off
-- the lower-left corner while reproducing the official visual language.
local PrivateReadingBadge = Widget:extend{
    size = 1,
    card_width = 1,
    card_height = 1,
    card_radius = 0,
    card_offset_x = 0,
    card_offset_y = 0,
}

function PrivateReadingBadge:init()
    self.size = math.max(1, math.floor(tonumber(self.size) or 1))
    self.dimen = Geom:new{ w = self.size, h = self.size }
    self.triangle_spans = CoverMask.triangle_spans(self.size, self.card_width, self.card_height,
        self.card_radius, self.card_offset_x, self.card_offset_y)
end

-- Paint one horizontal glyph run, clipped to the lower-left pennant triangle:
-- at badge row `local_y` the pennant only covers columns `0..local_y`, so
-- smaller badges cannot leave stray glyph pixels on the cover artwork.
function PrivateReadingBadge:_paint_triangle_run(bb, origin_x, origin_y, local_x, local_y, width, color)
    local stop_x = math.min(local_x + width - 1, local_y)
    if stop_x < local_x then return end
    bb:paintRect(origin_x + local_x, origin_y + local_y, stop_x - local_x + 1, 1, color)
end

function PrivateReadingBadge:_paint_mask(bb, origin_x, origin_y, mask_x, mask_y, width, height)
    -- Official private-reading glyph: a flat crown and straight cheeks that
    -- finish with a shallow rounded chin.  A tapering wedge reads as a clipped
    -- shape at thumbnail size, so retain the vertical sides through most of it.
    local straight_rows = math.max(1, math.floor(height * 0.58))
    local curve_rows = math.max(1, height - straight_rows)
    for row = 0, height - 1 do
        local inset = 0
        if row >= straight_rows then
            local curve = (row - straight_rows + 1) / curve_rows
            local arc = 1 - math.sqrt(math.max(0, 1 - curve * curve))
            inset = math.min(math.floor((width - 3) / 2),
                math.floor((width / 2) * arc))
        end
        self:_paint_triangle_run(bb, origin_x, origin_y, mask_x + inset, mask_y + row,
            math.max(3, width - 2 * inset), Blitbuffer.COLOR_WHITE)
    end
end

function PrivateReadingBadge:paintTo(bb, x, y)
    -- The lower-left right triangle, clipped against the cover's corner arc.
    for _, span in ipairs(self.triangle_spans) do
        bb:paintRect(x + span.x, y + span.y, span.width, 1, Blitbuffer.COLOR_BLACK)
    end
    -- The corner pennant and its glyph intentionally use separate scales:
    -- shrinking the full pennant previously left too little room for a
    -- recognisable mask.
    local mask_width = math.max(5, math.floor(self.size * 0.28))
    local mask_height = math.max(6, math.floor(self.size * 0.34))
    -- Place the whole hood below the diagonal rather than across it, while
    -- keeping it clear of the rounded lower-left cover corner.
    -- The visual centre of a lower-left right triangle is offset left and up
    -- from its bounding-box centre.
    local mask_x = math.max(0, math.floor(self.size * 0.083) + 3)
    -- Leave five pixels below the glyph, so the cover's rounded clipping never
    -- removes the mask's lower edge.
    local mask_y = math.max(0, self.size - mask_height - 8)
    self:_paint_mask(bb, x, y, mask_x, mask_y, mask_width, mask_height)
    -- Two short slanted eye openings stay legible at e-ink thumbnail scale.
    local eye_y = mask_y + math.max(1, math.floor(mask_height * 0.35))
    local eye_width = math.max(2, math.floor(mask_width * 0.20))
    local left_eye_x = mask_x + math.max(1, math.floor(mask_width * 0.20))
    local right_eye_x = mask_x + mask_width - eye_width
        - math.max(1, math.floor(mask_width * 0.20))
    self:_paint_triangle_run(bb, x, y, left_eye_x, eye_y, eye_width, Blitbuffer.COLOR_BLACK)
    self:_paint_triangle_run(bb, x, y, left_eye_x + 1, eye_y + 1,
        math.max(1, eye_width - 1), Blitbuffer.COLOR_BLACK)
    self:_paint_triangle_run(bb, x, y, right_eye_x, eye_y + 1,
        math.max(1, eye_width - 1), Blitbuffer.COLOR_BLACK)
    self:_paint_triangle_run(bb, x, y, right_eye_x + 1, eye_y, eye_width, Blitbuffer.COLOR_BLACK)
end

local function is_private_book(book)
    return ShelfFlags.display(book,'private')==true
end

local function is_finished(book)
    return ShelfFlags.display(book,'finished')==true
end

local DownloadStatus = Widget:extend{
    size = 1,
}

-- Keep the first title line aligned across short and wrapped book names.
-- The owner also releases its native text row when the card is closed.
local LeftAlignedTitle = Widget:extend{
    width = 1,
    height = 1,
    content = nil,
}

function LeftAlignedTitle:init()
    self.width = math.max(1, math.floor(tonumber(self.width) or 1))
    self.height = math.max(1, math.floor(tonumber(self.height) or 1))
    self.dimen = Geom:new{ w = self.width, h = self.height }
end

function LeftAlignedTitle:paintTo(bb, x, y)
    self.dimen.x,self.dimen.y=x,y
    self.content:paintTo(bb, x, y)
end

function LeftAlignedTitle:free(...)
    if self.content and self.content.free then self.content:free(...) end
end

LeftAlignedTitle.onCloseWidget = LeftAlignedTitle.free

local function build_center_cropped_cover(path, width, height)
    -- Keep image preparation independent from ImageWidget's "fit" and
    -- "stretch" modes: neither offers a cover-fill mode for raster files.
    -- Rendering once, scaling proportionally, and cropping the excess gives
    -- every thumbnail a uniform frame without distorting its artwork.
    local ok, cropped = pcall(function()
        local RenderImage = require("ui/renderimage")
        local source = RenderImage:renderImageFile(path, false)
        if not source then return nil end
        local source_width, source_height = source:getWidth(), source:getHeight()
        if source_width < 1 or source_height < 1 then
            source:free()
            return nil
        end
        local crop = CoverLayout.centerCrop(source_width, source_height, width, height)
        -- Scale through KOReader's MuPDF path: a shelf turn can rebuild a
        -- dozen covers, and the per-pixel Lua fallback is far too slow for it.
        local filled = RenderImage:scaleBlitBuffer(source, crop.width, crop.height, true)
        local output = Blitbuffer.new(width, height, filled:getType())
        output:blitFrom(filled, 0, 0, crop.offset_x, crop.offset_y, width, height)
        filled:free()
        return output
    end)
    if ok then return cropped end
    return nil
end

-- Public-account covers are typically square profile images. Keep their
-- proportions and center them on white instead of cropping a portrait card
-- tightly around an avatar.
local function build_center_contained_cover(path, width, height, inset)
    local ok, contained = pcall(function()
        local RenderImage = require("ui/renderimage")
        local source = RenderImage:renderImageFile(path, false)
        if not source then return nil end
        local source_width, source_height = source:getWidth(), source:getHeight()
        if source_width < 1 or source_height < 1 then
            source:free()
            return nil
        end
        inset = math.max(0, math.floor(tonumber(inset) or 0))
        local available_width = math.max(1, width - 2 * inset)
        local available_height = math.max(1, height - 2 * inset)
        local factor = math.min(available_width / source_width, available_height / source_height)
        local target_width = math.max(1, math.floor(source_width * factor + 0.5))
        local target_height = math.max(1, math.floor(source_height * factor + 0.5))
        local scaled = RenderImage:scaleBlitBuffer(source, target_width, target_height, true)
        local output = Blitbuffer.new(width, height, scaled:getType())
        output:paintRect(0, 0, width, height, Blitbuffer.COLOR_WHITE)
        output:blitFrom(scaled,
            math.floor((width - target_width) / 2),
            math.floor((height - target_height) / 2),
            0, 0, target_width, target_height)
        scaled:free()
        return output
    end)
    if ok then return contained end
    return nil
end

function DownloadStatus:init()
    self.size = math.max(1, math.floor(tonumber(self.size) or 1))
    self.dimen = Geom:new{ w = self.size, h = self.size }
end

local function paint_status_line(bb, x1, y1, x2, y2, stroke, color)
    local steps = math.max(math.abs(x2 - x1), math.abs(y2 - y1), 1)
    for step = 0, steps do
        local ratio = step / steps
        bb:paintRect(
            math.floor(x1 + (x2 - x1) * ratio),
            math.floor(y1 + (y2 - y1) * ratio),
            stroke, stroke, color
        )
    end
end

function DownloadStatus:paintTo(bb, x, y)
    local stroke = math.max(1, math.floor(self.size / 8))
    local radius = math.max(1, math.floor((self.size - 1) / 2))
    local center_x = x + math.floor((self.size - 1) / 2)
    local center_y = y + math.floor((self.size - 1) / 2)
    -- paintCircle fills when its stroke width matches its radius.
    bb:paintCircle(center_x, center_y, radius, Blitbuffer.COLOR_BLACK)
    paint_status_line(bb,
        center_x - math.floor(radius * 0.52), center_y,
        center_x - math.floor(radius * 0.12), center_y + math.floor(radius * 0.42),
        stroke, Blitbuffer.COLOR_WHITE)
    paint_status_line(bb,
        center_x - math.floor(radius * 0.12), center_y + math.floor(radius * 0.42),
        center_x + math.floor(radius * 0.58), center_y - math.floor(radius * 0.42),
        stroke, Blitbuffer.COLOR_WHITE)
end

local ShelfRow = InputContainer:extend{
    text = "",
    status = "",
    width = nil,
    font_size = 22,
    callback = nil,
    hold_callback = nil,
    show_parent = nil,
    lazy_frame = false,
}

local function shelf_row_frame(self)
    local padding = Size.padding.large
    local inner_width = self.width - 2 * padding
    local face = Font:getFace("cfont", self.font_size)
    local gap = Size.padding.large
    -- Deferred rows keep their width while status text changes. Leave room
    -- for the title even when several status labels appear together.
    local status_limit = self.defer_status and math.max(1, inner_width - gap - 2 * self.font_size) or nil
    local status_widget = TextWidget:new{ text = self.status or "", face = face, max_width = status_limit }
    local status_width = status_widget:getSize().w
    local title_widget = TextWidget:new{
        text = self.text,
        face = face,
        max_width = math.max(1, inner_width - status_width - gap),
    }
    gap = math.max(gap, inner_width - title_widget:getSize().w - status_width)
    return FrameContainer:new{
        bordersize = 0,
        radius = 0,
        margin = 0,
        padding_left = padding,
        padding_right = padding,
        padding_top = Size.padding.large,
        padding_bottom = Size.padding.large,
        background = Blitbuffer.COLOR_WHITE,
        show_parent = self.show_parent,
        HorizontalGroup:new{
            align = "center",
            title_widget,
            HorizontalSpan:new{ width = gap },
            status_widget,
        },
    }
end

function ShelfRow:_ensureFrame()
    if self.frame then return end
    self.frame = shelf_row_frame(self)
    self.frame.invert = self._shelf_focused or false
    self[1] = self.frame
end

function ShelfRow:init()
    if self.defer_status then
        self.dimen = Geom:new{ w = self.width, h = self.lazy_row_height }
    elseif self.lazy_frame then
        local status = self.status or ""
        local widths = self.lazy_status_widths
        local status_width = widths and widths[status]
        if status_width == nil then
            local widget = TextWidget:new{ text = status, face = Font:getFace("cfont", self.font_size) }
            status_width = widget:getSize().w
            if widget.free then widget:free() end
            if widths then widths[status] = status_width end
        end
        if self.lazy_row_height then
            -- Text shaping or an ellipsis can exceed a very narrow title
            -- limit. Measure the title exactly, but discard the temporary
            -- widget rather than retaining a complete row for every book.
            local padding = Size.padding.large
            local inner_width = self.width - 2 * padding
            local title = TextWidget:new{ text = self.text, face = Font:getFace("cfont", self.font_size),
                max_width = math.max(1, inner_width - status_width - padding) }
            local title_width = title:getSize().w
            if title.free then title:free() end
            local gap = math.max(padding, inner_width - title_width - status_width)
            self.dimen = Geom:new{ w = title_width + status_width + gap + 2 * padding,
                h = self.lazy_row_height }
        else
            self:_ensureFrame()
            self.dimen = self.frame:getSize()
            self.frame:free()
            self.frame, self[1] = nil, nil
        end
    else
        self:_ensureFrame()
        self.dimen = self.frame:getSize()
    end
    self.ges_events = {
        TapShelfRow = {
            GestureRange:new{ ges = "tap", range = self.dimen },
        },
    }
    if self.hold_callback then
        self.ges_events.HoldShelfRow = { GestureRange:new{ ges = "hold", range = self.dimen } }
        self.ges_events.HoldReleaseShelfRow = { GestureRange:new{ ges = "hold_release", range = self.dimen } }
    end
end

function ShelfRow:setStatus(status)
    if status == self.status then return end
    self.status = status
    if self.frame then
        self.frame:free()
        self.frame, self[1] = nil, nil
    end
end

function ShelfRow:paintTo(bb, x, y)
    self:_ensureFrame()
    return InputContainer.paintTo(self, bb, x, y)
end

function ShelfRow:setOffscreenGeometry(x, y)
    self.dimen.x, self.dimen.y = x, y
    if self.frame then
        if self.lazy_frame then
            self.frame:free()
            self.frame, self[1] = nil, nil
        elseif self.frame.dimen then
            self.frame.dimen.x,self.frame.dimen.y=x,y
        end
    end
end

function ShelfRow:onTapShelfRow()
    if self._hold_handled then self._hold_handled = false; return true end
    if not self.callback then return true end
    self:_ensureFrame()
    if not self.frame.dimen then self.frame.dimen=self.dimen:copy() end
    self.frame.invert = true
    UIManager:widgetRepaint(self.frame, self.frame.dimen.x, self.frame.dimen.y)
    UIManager:forceRePaint()
    self.frame.invert = false
    self._shelf_focused = false
    UIManager:widgetRepaint(self.frame, self.frame.dimen.x, self.frame.dimen.y)
    UIManager:setDirty(nil, "fast", self.frame.dimen)
    self.callback()
    return true
end

function ShelfRow:onHoldShelfRow()
    if not self.hold_callback then return false end
    self._hold_handled = true
    self.hold_callback()
    UIManager:nextTick(function() self._hold_handled = false end)
    return true
end

function ShelfRow:onHoldReleaseShelfRow()
    self._hold_handled = false
    return self.hold_callback ~= nil
end

function ShelfRow:onFocus()
    self._shelf_focused = true
    if self.frame then self.frame.invert = true end
    return true
end

function ShelfRow:onUnfocus()
    self._shelf_focused = false
    if self.frame then self.frame.invert = false end
    return true
end

local CoverCell = InputContainer:extend{
    book = nil,
    width = nil,
    height = nil,
    cover_path = nil,
    cover_loading = false,
    contain_cover = false,
    cached = false,
    callback = nil,
    hold_callback = nil,
    store_details = false,
    store_reason = false,
    show_parent = nil,
}

function CoverCell:init()
    local metrics = CoverLayout.card{
        width = self.width,
        height = self.height,
        size_scale = Screen:scaleBySize(1000) / 1000,
        detail_lines = self.store_details and (self.store_reason and 2 or 1) or 0,
    }
    local border = Size.border.thin
    local image_width = math.max(1, metrics.card_width - 2 * border)
    local image_height = math.max(1, metrics.card_height - 2 * border)
    self._cover_fit = self.contain_cover and "contain" or "crop"
    local cover_content
    if self.cover_path then
        local image
        local ok = pcall(function()
            local rendered = CoverBitmapCache.shared():render(
                self.cover_path, image_width, image_height, self._cover_fit, function()
                    if self.contain_cover then
                        return build_center_contained_cover(self.cover_path, image_width, image_height, 0)
                    end
                    return build_center_cropped_cover(self.cover_path, image_width, image_height)
                end)
            if rendered then
                image = ImageWidget:new{
                    image = rendered,
                    image_disposable = true,
                    scale_factor = 1,
                }
            else
                -- Preserve the pre-existing safe fallback when a malformed
                -- legacy cover cannot be decoded for cropping.
                image = ImageWidget:new{
                    file = self.cover_path,
                    width = image_width,
                    height = image_height,
                    scale_factor = nil,
                    file_do_cache = false,
                }
            end
            image:getSize()
        end)
        if ok and image then
            cover_content = image
            self._has_cover = true
        elseif image and type(image.free) == "function" then
            pcall(image.free, image)
        end
    end
    if not cover_content then
        -- Center the placeholder text inside the card, like the pre-grid
        -- layout did before the rounded card painted its content top-left.
        cover_content = CenterContainer:new{
            dimen = Geom:new{ w = image_width, h = image_height },
            TextWidget:new{
                text = self.cover_loading and _("Cover loading") or _("No cover"),
                face = Font:getFace("cfont", 18),
                max_width = image_width,
            },
        }
        self._has_cover = false
        self._placeholder_centered = true
    end
    local cover_card = RoundedCoverCard:new{
        inner = cover_content,
        width = metrics.card_width,
        height = metrics.card_height,
        border_size = border,
        radius = metrics.radius,
        shadow_offset = metrics.shadow,
        white_background = not self._has_cover,
        shadow_color = metrics.shadow > 0
            and (Blitbuffer.gray and Blitbuffer.gray(0.5) or Blitbuffer.COLOR_GRAY) or nil,
    }
    local cover_layers = {
        dimen = Geom:new{ w = metrics.cover_width, h = metrics.cover_height },
    }
    if metrics.shadow > 0 then
        local shadow = CoverShadow:new{
            width = metrics.card_width,
            height = metrics.card_height,
            radius = metrics.radius,
        }
        shadow.overlap_offset = { metrics.shadow, metrics.shadow }
        cover_layers[#cover_layers + 1] = shadow
    end
    cover_layers[#cover_layers + 1] = cover_card
    self._finished = self.finish_pending and self.finish_pending.desired or false
    if not self.finish_pending then self._finished = is_finished(self.book) end
    self._has_finished_badge = self._finished
    if self._finished or self.finish_pending then
        local badge = FinishedBadge:new{label_text=self.finish_pending and _(self.finish_pending.phase=='queued' and 'Pending sync' or 'Needs review') or nil}
        -- Keep the completion stamp inside the rounded cover silhouette. If it
        -- touches the outer top-right corner, its square white background
        -- hides the cover radius and makes the card read as a right angle.
        local badge_inset = math.max(border, math.floor(metrics.radius * 0.55))
        badge.overlap_offset = {
            math.max(0, metrics.card_width - badge.width - badge_inset),
            badge_inset,
        }
        cover_layers[#cover_layers + 1] = badge
        self._finished_badge=badge
    end
    if self.local_pinned or ShelfFlags.display(self.book,'pinned')==true then
        local padding=math.max(1,Screen:scaleBySize(2))
        local badge=FrameContainer:new{padding=padding,margin=0,bordersize=Size.border.thin,radius=0,
            background=Blitbuffer.COLOR_WHITE,TextWidget:new{text=_(self.local_pinned and 'Local pin' or 'Pinned'),face=Font:getFace('cfont',12),
                max_width=math.max(1,math.floor(metrics.card_width*(self.local_pinned and .65 or .4))-padding*2)}}
        local inset=math.max(border,Screen:scaleBySize(4))
        badge.overlap_offset={inset,inset};cover_layers[#cover_layers+1]=badge;self._pinned_badge=badge
    end
    self._private_reading = is_private_book(self.book)
    self._has_private_badge = self._private_reading
    if self._private_reading then
        local badge_size = math.max(1, math.min(metrics.card_width, metrics.card_height,
            -- Retain the current pennant size; only the inner glyph is tuned.
            Screen:scaleBySize(24)))
        local badge = PrivateReadingBadge:new{
            size = badge_size,
            card_width = metrics.card_width,
            card_height = metrics.card_height,
            card_radius = metrics.radius,
            card_offset_x = 0,
            card_offset_y = metrics.card_height - badge_size,
        }
        badge.overlap_offset = { 0, metrics.card_height - badge_size }
        cover_layers[#cover_layers + 1] = badge
        self._private_badge = badge
        self._private_badge_size = badge_size
    end
    local progress_text = ShelfProgress.label(self.book._shelf_progress, self.book._shelf_progress_local, self.book._shelf_progress_exact)
    if progress_text then
        local inset = math.max(border, Screen:scaleBySize(4))
        local padding = math.max(1, Screen:scaleBySize(2))
        local max_width=math.max(1,metrics.card_width-2*inset-2*padding-2*Size.border.thin)
        local line=TextWidget:new{text=progress_text,face=Font:getFace('cfont',14)}
        local content,labels=line,{line}
        if line:getSize().w>max_width and self.book._shelf_progress_local then
            if line.free then line:free() end
            local size=12
            while true do
                local local_label=TextWidget:new{text=_('Local'),face=Font:getFace('cfont',size)}
                local number_label=TextWidget:new{text=ShelfProgress.label(self.book._shelf_progress,false,self.book._shelf_progress_exact),face=Font:getFace('cfont',size)}
                if size<=8 or local_label:getSize().w<=max_width and number_label:getSize().w<=max_width then
                    labels={local_label,number_label};content=VerticalGroup:new{align='right',local_label,number_label};break
                end
                if local_label.free then local_label:free() end
                if number_label.free then number_label:free() end
                size=size-1
            end
        elseif line:getSize().w>max_width then
            if line.free then line:free() end
            line=TextWidget:new{text=progress_text,face=Font:getFace('cfont',14),max_width=max_width}
            content,labels=line,{line}
        end
        local badge = FrameContainer:new{
            padding = padding, margin = 0,
            bordersize = Size.border.thin, radius = 0,
            background = Blitbuffer.COLOR_WHITE,
            content,
        }
        local size = badge:getSize()
        local y=math.max(0,metrics.card_height-size.h-inset)
        if self._private_badge_size and size.w+self._private_badge_size+2*inset>metrics.card_width then
            y=math.max(0,metrics.card_height-self._private_badge_size-size.h-inset)
        end
        badge.overlap_offset = {
            math.max(0, metrics.card_width - size.w - inset),
            y,
        }
        cover_layers[#cover_layers + 1] = badge
        self._progress_badge,self._progress_badge_text,self._progress_badge_labels = badge,progress_text,labels
    end
    local cover = OverlapGroup:new(cover_layers)
    local title = self.book.title or self.book.bookId or self.book.book_id or _("Untitled")
    local status_size = math.max(1, math.min(metrics.title_height, Screen:scaleBySize(10)))
    local title_gap = math.max(1, Screen:scaleBySize(2))
    self._has_download_status = self.cached == true
    self._download_status_checked = self._has_download_status
    local title_widget = TextBoxWidget:new{
        text = tostring(title):gsub("[\r\n\t]", " "),
        face = Font:getFace("cfont", 15),
        width = math.max(1, metrics.cover_width
            - (self._has_download_status and status_size + title_gap or 0)),
        height = metrics.title_height,
        height_adjust = true,
        height_overflow_show_ellipsis = true,
        alignment = "left",
    }
    self._title_widget = title_widget
    local title_line = HorizontalGroup:new{ align = "top" }
    if self._has_download_status then
        title_line[#title_line + 1] = CenterContainer:new{
            dimen = Geom:new{ w = status_size, h = math.floor(metrics.title_height / 2) },
            DownloadStatus:new{ size = status_size },
        }
        title_line[#title_line + 1] = HorizontalSpan:new{ width = title_gap }
    end
    title_line[#title_line + 1] = title_widget
    -- The fixed-width custom container participates in measurement and paints
    -- all titles from the cover's left edge, even when the title is short.
    local title_container = LeftAlignedTitle:new{
        width = metrics.cover_width,
        height = metrics.title_height,
        content = title_line,
    }
    local card_contents=VerticalGroup:new{
        align = "center",
        CenterContainer:new{ dimen = Geom:new{ w = metrics.cover_width, h = metrics.cover_height }, cover },
        VerticalSpan:new{ width = metrics.title_gap },
        CenterContainer:new{ dimen = Geom:new{ w = metrics.cover_width, h = metrics.title_height }, title_container },
    }
    if self.store_details then
        card_contents[#card_contents+1]=VerticalSpan:new{width=metrics.detail_gap}
        local author=type(self.book.author)=='string' and self.book.author:gsub('[%c]+',' ') or ''
        local info=self.book._public_info
        local rating=type(info)=='table' and info.newRating
        local count=type(info)=='table' and info.newRatingCount
        if type(rating)=='number' and rating==rating and rating>0 and rating<=1000
            and type(count)=='number' and count>0 and count<=1e10 and count%1==0 then
            local score=_('Rating')..' '..string.format('%.1f',rating/100)
            author=author~='' and score..' · '..author or score
        end
        local fields={author}
        if self.store_reason then fields[#fields+1]=type(self.book.reason)=='string' and self.book.reason:gsub('[%c]+',' ') or '' end
        self._store_details={}
        self._store_detail_frames={}
        for _,value in ipairs(fields) do
            local line=TextWidget:new{text=value,face=Font:getFace('cfont',13),max_width=metrics.cover_width}
            self._store_details[#self._store_details+1]=line
            local frame=LeftAlignedTitle:new{width=metrics.cover_width,height=metrics.detail_line_height,content=line}
            self._store_detail_frames[#self._store_detail_frames+1]=frame
            card_contents[#card_contents+1]=frame
        end
    end
    self.frame = FrameContainer:new{
        bordersize = 0,
        radius = 0,
        margin = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        show_parent = self.show_parent,
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = self.height },
            card_contents,
        },
    }
    self[1] = self.frame
    self.dimen = self.frame:getSize()
    self.ges_events = {
        TapCoverCell = {
            GestureRange:new{ ges = "tap", range = self.dimen },
        },
    }
    if self.hold_callback then
        self.ges_events.HoldCoverCell = { GestureRange:new{ ges = "hold", range = self.dimen } }
        self.ges_events.HoldReleaseCoverCell = { GestureRange:new{ ges = "hold_release", range = self.dimen } }
    end
end

function CoverCell:onTapCoverCell()
    if self._hold_handled then self._hold_handled = false; return true end
    if self.callback then self.callback() end
    return true
end

function CoverCell:onHoldCoverCell()
    if not self.hold_callback then return false end
    self._hold_handled = true
    self.hold_callback()
    UIManager:nextTick(function() self._hold_handled = false end)
    return true
end

function CoverCell:onHoldReleaseCoverCell()
    self._hold_handled = false
    return self.hold_callback ~= nil
end

function CoverCell:onFocus()
    self.frame.invert = true
    return true
end

function CoverCell:onUnfocus()
    self.frame.invert = false
    return true
end

local LibraryView = FocusManager:extend{
    mode = "books",
    title = nil,
    wp_enable = true,
    books = nil,
    accounts = nil,
    keyword = nil,
    sort_label = nil,
    filter_label = nil,
    groups = nil,
    group_membership_incomplete = false,
    group_key = nil,
    group_keys = nil,
    group_label = nil,
    on_select_group = nil,
    on_select_groups = nil,
    on_manage_local_groups = nil,
    on_display_change = nil,
    scroll_offset = nil,
    on_switch = nil,
    on_search = nil,
    on_refresh = nil,
    on_sort = nil,
    on_filter = nil,
    on_import_mp_link = nil,
    on_imported_mp_links = nil,
    on_manage_mp_accounts = nil,
    on_offline_changes = nil,
    on_select = nil,
    on_hold = nil,
    store_details = false,
    store_reason = false,
    paged = false,
    page = 1,
    page_size = 10,
    cover_mode = false,
    cover_columns = 3,
    cover_rows = 2,
    cover_cell_height = nil,
    cover_paths = nil,
    cover_loading = nil,
    on_page_changed = nil,
}

-- Defer destructive callbacks until Button has finished repainting its feedback.
local function after_tap(callback)
    return function() UIManager:nextTick(callback) end
end

function LibraryView:actionBar(entries, navigation)
    if not entries or #entries == 0 then return nil end
    local buttons = {}
    local width = math.floor(self.screen_w / #entries)
    for index, entry in ipairs(entries) do
        buttons[#buttons + 1] = Button:new{
            text = entry.text, width = index == #entries and self.screen_w - width * (index - 1) or width,
            height = Screen:scaleBySize(54), text_font_size = 18, avoid_text_truncation = false,
            text_font_bold = entry.active == true,
            enabled = entry.enabled ~= false,
            radius = 0, margin = 0, padding = 0, bordersize = 0,
            show_parent = self, callback = after_tap(entry.active and function() end or entry.callback or function() end),
            hold_callback = entry.hold_callback and after_tap(entry.hold_callback) or nil,
        }
    end
    if navigation then self._navigation_buttons = buttons else self._action_buttons = buttons end
    return HorizontalGroup:new(buttons)
end

function LibraryView:portalHeader()
    local HeaderLayout = require("weread.lib.home_header_layout")
    local size = Screen:scaleBySize(72)
    local entries = {
        { key = "back", width = size, callback = function() self:onClose() end },
        { key = "title", width = math.max(1, self.screen_w - (self.on_settings and 4 or 3) * size) },
        { key = "search", width = size, callback = self.on_search },
        { key = "refresh", width = size, callback = self.on_refresh },
    }
    if self.on_settings then table.insert(entries, #entries, { key = "settings", width = size, callback = self.on_settings }) end
    local items = HeaderLayout.arrange(self.screen_w, entries, 0)
    local widgets, buttons, x = {}, {}, 0
    for _, item in ipairs(items) do
        if item.x > x then widgets[#widgets + 1] = HorizontalSpan:new{ width = item.x - x } end
        local icons = { back = "chevron.left", search = "appbar.search", refresh = "appbar.search", settings = "appbar.settings" }
        local button = Button:new{
            text = item.key == "title" and self.title or nil, icon = icons[item.key],
            width = item.width, height = size, text_font_size = 24, text_font_bold = true,
            avoid_text_truncation = false,
            enabled = item.key == "title" or item.callback ~= nil, radius = 0, margin = 0, padding = 0, bordersize = 0,
            show_parent = self, callback = after_tap(item.callback or function() end),
        }
        if item.key == "refresh" then
            button.label_widget:free()
            button.label_widget = IconWidget:new{
                file = icons_dir .. "shelf-refresh.svg",
                width = Screen:scaleBySize(36), height = Screen:scaleBySize(36),
            }
            button.label_container[1] = button.label_widget
            self.refresh_button = button
        elseif item.key == "settings" then self.settings_button = button
        end
        widgets[#widgets + 1], buttons[#buttons + 1] = button, button
        x = item.x + item.width
    end
    self._header_buttons = buttons
    return VerticalGroup:new{
        align = "left", HorizontalGroup:new(widgets),
        LineWidget:new{ dimen = Geom:new{ w = self.screen_w, h = Size.border.thin } },
    }
end

function LibraryView:homeTextRow(text, height, font_size, bold)
    local label = TextWidget:new{
        text = text, face = Font:getFace("cfont", font_size), bold = bold,
        max_width = math.max(1, self.screen_w - 2 * Size.padding.default),
    }
    local frame = FrameContainer:new{
        padding = 0, margin = 0, bordersize = 0, background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = self.screen_w, h = Screen:scaleBySize(height) }, label,
        },
    }
    return frame, label
end

local function home_row_region(widget)
    local d = widget and widget.dimen
    if not d or type(d.x) ~= 'number' or type(d.y) ~= 'number'
        or type(d.w) ~= 'number' or type(d.h) ~= 'number' then return nil end
    return Geom:new{ x = d.x, y = d.y, w = d.w, h = d.h }
end

local function redraw_home_row(self, widget, before)
    local after = home_row_region(widget)
    local same = before and after and before.x == after.x and before.y == after.y
        and before.w == after.w and before.h == after.h
    local stable = same and before.w > 0 and before.h > 0 and before.x >= 0 and before.y >= 0
        and before.x + before.w <= Screen:getWidth() and before.y + before.h <= Screen:getHeight()
        and self.screen_w == Screen:getWidth() and self.screen_h == Screen:getHeight()
        and self.screen_rotation == (Screen.getRotationMode and Screen:getRotationMode())
        and not self._rotation_task and not self._shelf_closed
    if stable then
        local ok, size = pcall(widget.getSize, widget)
        stable = ok and size and size.w == before.w and size.h == before.h
    end
    if stable and not BD.mirroredUILayout() and UIManager.widgetRepaint and UIManager.getTopmostVisibleWidget
        and UIManager:getTopmostVisibleWidget() == self then
        UIManager:widgetRepaint(widget, before.x, before.y)
        UIManager:setDirty(nil, 'ui', before)
    else
        -- Covering windows must be repainted in stack order. If the geometry
        -- changed, use the full view so stale pixels cannot remain onscreen.
        UIManager:setDirty(self, 'ui', stable and before or self.dimen)
    end
end

function LibraryView:updateHomeStatus(text)
    if not self._home_status_label or self._home_status_label.text == text then return end
    local before = home_row_region(self._home_status_frame)
    self._home_status_label:setText(text)
    redraw_home_row(self, self._home_status_frame, before)
end

function LibraryView:updateHomeSummary(text)
    if not self._summary_button or self._summary_button.text == text then return end
    local before = home_row_region(self._summary_button)
    self._summary_button:setText(text, self._summary_button.width)
    redraw_home_row(self, self._summary_button, before)
end

function LibraryView:headerBar()
    if self.portal then return self:portalHeader() end
    local size = Screen:scaleBySize(HEADER_SIZE)
    local title = self.mode == "public_account" and _("Public Accounts")
        or T(_("Books · %1"), self.group_label or _("All"))
    local function button(text, icon, width, callback, align, icon_file, max_width)
        local widget = Button:new{
            text = text, icon = icon, width = width, max_width = max_width, height = size,
            icon_width = Screen:scaleBySize(36), icon_height = Screen:scaleBySize(36),
            padding = 0, radius = 0, margin = 0, bordersize = 0,
            padding_h = max_width and Screen:scaleBySize(6) or 0,
            text_font_size = 24, align = align or "center",
            avoid_text_truncation = false, show_parent = self,
            callback = after_tap(callback),
        }
        if icon_file then
            widget.label_widget:free()
            widget.label_widget = IconWidget:new{
                file = icons_dir .. icon_file, width = Screen:scaleBySize(36), height = Screen:scaleBySize(36),
            }
            widget.label_container[1] = widget.label_widget
        end
        return widget
    end
    local back = button(nil, "chevron.left", size, function() self:onClose() end)
    local location_width = self.screen_w - 4 * size
    local location = button(title .. " ▾", nil, nil,
        function() self:showSourceMenu() end, "left", nil, location_width)
    local search = button(nil, "appbar.search", size,
        function() if self.on_search then self.on_search() end end, nil, "shelf-search.svg")
    self.refresh_button = button(nil, "appbar.search", size,
        function() if self.on_refresh then self.on_refresh() end end, nil, "shelf-refresh.svg")
    local menu = button(nil, "appbar.menu", size, function() self:showOptions() end, nil, "shelf-menu.svg")
    self._header_buttons = { back, location, search, self.refresh_button, menu }
    return VerticalGroup:new{
        align = "left",
        HorizontalGroup:new{ back, location,
            HorizontalSpan:new{ width = math.max(0, location_width - location:getSize().w) },
            search, self.refresh_button, menu },
        LineWidget:new{ dimen = Geom:new{ w = self.screen_w, h = Size.border.thin } },
    }
end

function LibraryView:setRefreshing(refreshing)
    if not self.refresh_button then return end
    self.refresh_button:enableDisable(not refreshing)
    UIManager:setDirty(self, "ui", self.refresh_button.dimen)
end

function LibraryView:getScrollOffset()
    return self.scroll and self.scroll:getScrolledOffset()
end

function LibraryView:getFocusedBookId()
    local item = self:getFocusItem()
    return item and ShelfSnapshot.persisted_id(item.book)
end

function LibraryView:getVisibleBooks()
    local source = self.mode == "public_account" and (self.accounts or {}) or (self.books or {})
    local result = {}
    if self.paged then
        for index = (self.page - 1) * self.page_size + 1, math.min(#source, self.page * self.page_size) do
            result[#result + 1] = source[index]
        end
        return result
    end
    local offset = self:getScrollOffset()
    local top, height, y = offset and offset.y or 0, self.scroll.dimen.h, 0
    if self._list_bottoms and #self._list_bottoms == #self._item_rows then
        return ShelfVisible.books(source, self._list_bottoms, top, height)
    end
    for index, row in ipairs(self._item_rows) do
        local bottom = y + row:getSize().h
        if bottom > top and y < top + height then result[#result + 1] = source[index] end
        if y >= top + height then break end
        y = bottom + 1 -- list divider
    end
    return result
end

function LibraryView:prepareVisibleStatus(books)
    if not self.on_prepare_visible_status then return {} end
    books = books or self:getVisibleBooks()
    local first, last = books[1], books[#books]
    if self._visible_status_snapshots and first == self._visible_status_first and last == self._visible_status_last then
        return self._visible_status_snapshots
    end
    local added, current_books = {}, {}
    local known = self._visible_status_books or {}
    for _, book in ipairs(books) do
        current_books[book] = true
        if not known[book] then added[#added + 1] = book end
    end
    local fresh, dates = self.on_prepare_visible_status(added)
    if not fresh then return {} end
    local snapshots, read_times = {}, {}
    for _, book in ipairs(books) do
        local id = ShelfSnapshot.persisted_id(book)
        if known[book] then
            if id then snapshots[id] = self._visible_status_snapshots[id] end
            read_times[book] = self.last_read_times[book]
        else
            if id then snapshots[id] = fresh[id] end
            read_times[book] = dates[book]
        end
    end
    self._visible_status_first, self._visible_status_last = first, last
    self._visible_status_books = current_books
    self._visible_status_snapshots = snapshots
    self.last_read_times = read_times
    if first then
        local index = ShelfVisible.first(self._list_bottoms, self:getScrollOffset().y)
        for offset, book in ipairs(books) do
            if not known[book] then self._item_rows[index + offset - 1]:setStatus(self:itemStatus(book)) end
        end
    end
    return snapshots
end

function LibraryView:getBrowsePosition()
    local visible = self:getVisibleBooks()
    local position = { page = self.page, book_id = ShelfSnapshot.persisted_id(visible[1]) }
    local focused = self:getFocusItem()
    if focused and focused.book then
        for _, book in ipairs(visible) do
            if book == focused.book then
                position.focus_book_id = ShelfSnapshot.persisted_id(book)
                break
            end
        end
    end
    if not self.paged then
        local offset = self:getScrollOffset()
        position.scroll_offset = offset
        if position.book_id and self._list_bottoms then
            local index = ShelfVisible.first(self._list_bottoms, offset.y)
            position.inset = offset.y - ShelfVisible.top(self._list_bottoms, index)
        end
    end
    return position
end

function LibraryView:showSourceMenu(menu_mode)
    if self._shelf_closed then return end
    local Popup=require('weread.ui.shelf_popup')
    local Menu = require("ui/widget/menu")
    menu_mode = menu_mode or self.mode
    local width = math.floor(self.screen_w * 0.9)
    local dialog
    local function select(callback)
        return after_tap(function()
            if not Popup.current(self,dialog) then return end
            Popup.close(self)
            callback()
        end)
    end
    local tab_width = math.floor((width - 2 * Size.border.window) / 2)
    local tabs = {}
    for _, tab in ipairs({
        { mode = "books", text = _("Books") },
        { mode = "public_account", text = _("Public Accounts") },
    }) do
        tabs[#tabs + 1] = Button:new{
            text = tab.text, width = tab_width, height = Screen:scaleBySize(HEADER_SIZE),
            text_font_size = 24,
            padding = 0, radius = 0, margin = 0, bordersize = 0,
            checked_func = function() return menu_mode == tab.mode end,
            enabled = tab.mode == "books" or self.wp_enable,
            callback = select(function()
                if tab.mode == "books" then
                    self:showSourceMenu("books")
                elseif self.on_switch then
                    self.on_switch(tab.mode)
                end
            end),
        }
    end
    -- Menu owns pagination, truncation, dismiss gestures and keyboard focus.
    local header = HorizontalGroup:new{ tabs[1], tabs[2] }
    header.getHeight = function(widget) return widget:getSize().h end
    header.generateVerticalLayout = function() return { { tabs[1] }, { tabs[2] } } end
    local items = {}
    local function add_group(key, label, count)
        items[#items + 1] = {
            text = label,
            mandatory = (self.mode == "books" and self.group_key == key and #(self.group_keys or {})==0 and "✓  " or "")
                .. tostring(count),
            callback = select(function()
                if self.on_select_group then self.on_select_group(key) end
            end),
        }
    end
    if menu_mode == "books" then
        add_group(nil, _("All books"), self.total_books or #(self.books or {}))
        if self.on_select_groups and (#(self.groups or {})>0 or #(self.group_keys or {})>0) then
            items[#items+1]={text=_('Select multiple groups'),mandatory=#(self.group_keys or {})>0 and '✓' or '',
                callback=select(function() self:showMultiGroupMenu() end)}
        end
        for _index, group in ipairs(self.groups or {}) do
            local label = group.label
            if not ShelfGroups.unique(self.groups, group.key) then label = T(_('Unavailable: %1'), label) end
            if group.incomplete then label = T(_('%1 (incomplete)'),label) end
            add_group(group.key, label, #group.books)
        end
        if self.group_membership_incomplete then
            items[#items+1]={text=_('Some group memberships are unknown. Refresh the bookshelf.'),select_enabled=false}
        end
        if self.on_manage_local_groups then
            items[#items+1]={text=_('Manage local groups'),callback=select(function() self.on_manage_local_groups() end)}
        end
    else
        items[1] = {
            text = _("Public Accounts"), mandatory = tostring(#(self.accounts or {})),
            callback = select(function() if self.on_switch then self.on_switch("public_account") end end),
        }
    end
    local header_height = header:getSize().h
    local row_height = Screen:scaleBySize(54)
    local available_height = self.screen_h - header_height - 2 * Size.border.window
    local paged = #items * row_height > available_height
    local per_page = paged and math.max(1, math.floor((available_height - Screen:scaleBySize(HEADER_SIZE)) / row_height))
        or #items
    dialog = Menu:new{
        title = _("Select content"), custom_title_bar = header,
        width = width,
        height = header_height + per_page * row_height + 2 * Size.border.window
            + (paged and Screen:scaleBySize(HEADER_SIZE) or 0),
        item_table = items, items_per_page = per_page, items_font_size = 22,
        _recalculateDimen = function(menu, ...)
            Menu._recalculateDimen(menu, ...)
            if not paged then
                -- Native Menu reserves a footer even for one page.
                menu.available_height = menu.inner_dimen.h - header_height
                menu.item_dimen.h = math.floor(menu.available_height / per_page)
            end
        end,
        -- Unlike the standard title bar, these buttons have no Sym/Menu key
        -- shortcuts. Keep them reachable with the five-way controller, too.
        mergeTitleBarIntoLayout = function(menu)
            table.insert(menu.layout, 1, { tabs[2] })
            table.insert(menu.layout, 1, { tabs[1] })
            menu.selected.y = menu.selected.y + 2
        end,
    }
    if not paged then
        -- Keep ownership for cleanup, but no invisible controls over the last row.
        dialog.page_info.paintTo = function() end
        dialog.page_info.handleEvent = function() return false end
    end
    -- Keep popout dismissal, but use square corners like the bookshelf.
    dialog[1].radius = 0
    Popup.show(self,dialog)
end

function LibraryView:showMultiGroupMenu()
    if self._shelf_closed or not self.on_select_groups then return end
    local Popup=require('weread.ui.shelf_popup')
    local Menu=require('ui/widget/menu')
    local selected={}
    for _,key in ipairs(self.group_keys or {}) do selected[key]=true end
    if not next(selected) and self.group_key then selected[self.group_key]=true end
    local items,dialog={},nil
    items[#items+1]={text=_('Apply selected groups'),callback=after_tap(function()
        if not Popup.current(self,dialog) then return end
        local keys={};for key in pairs(selected) do keys[#keys+1]=key end
        table.sort(keys);Popup.close(self);self.on_select_groups(keys)
    end)}
    items[#items+1]={text=_('Clear group selection'),callback=after_tap(function()
        if not Popup.current(self,dialog) then return end
        selected={};for i=3,#items do items[i].mandatory='' end;dialog:updateItems()
    end)}
    local function add_group(key,label,enabled)
        local item={text=label,mandatory=selected[key] and '✓' or '',select_enabled=enabled}
        item.callback=after_tap(function()
            if not Popup.current(self,dialog) or item.select_enabled==false then return end
            selected[key]=not selected[key] or nil
            item.mandatory=selected[key] and '✓' or '';dialog:updateItems()
        end)
        items[#items+1]=item
    end
    local missing={}
    for key in pairs(selected) do if not ShelfGroups.unique(self.groups,key) then missing[#missing+1]=key end end
    table.sort(missing)
    for _i,key in ipairs(missing) do add_group(key,_('Unavailable saved group'),true) end
    for _index,group in ipairs(self.groups or {}) do
        local label=group.incomplete and T(_('%1 (incomplete)'),group.label) or group.label
        add_group(group.key,label,ShelfGroups.unique(self.groups,group.key)~=nil)
    end
    if self.group_membership_incomplete then
        items[#items+1]={text=_('Some group memberships are unknown. Refresh the bookshelf.'),select_enabled=false}
    end
    local row_height=Screen:scaleBySize(54)
    local perpage=math.max(1,math.min(#items,math.floor((self.screen_h-Screen:scaleBySize(120))/row_height)))
    dialog=Menu:new{title=_('Select multiple groups'),width=math.floor(self.screen_w*.9),
        height=math.min(self.screen_h,Screen:scaleBySize(120)+perpage*row_height),
        item_table=items,items_per_page=perpage,items_font_size=22}
    Popup.show(self,dialog)
end

function LibraryView:showOptions()
    if self._shelf_closed then return end
    local Popup=require('weread.ui.shelf_popup')
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local function action(callback)
        return after_tap(function()
            if not Popup.current(self,dialog) then return end
            Popup.close(self);callback()
        end)
    end
    local buttons = {{ {
        text = T(_("Sort: %1"), self.sort_label or ""),
        callback = action(function() if self.on_sort then self.on_sort() end end),
    } }}
    if self.mode == "books" then
        buttons[#buttons + 1] = {{
            text = T(_("Filter: %1"), self.filter_label or _("All")),
            callback = action(function() if self.on_filter then self.on_filter() end end),
        }}
        local row = {}
        for _, option in ipairs({ { "list", _("List view") }, { "cover", _("Cover view") } }) do
            row[#row + 1] = {
                text = option[2], checked_func = function() return self.cover_mode == (option[1] == "cover") end,
                callback = action(function() self.on_display_change("view_mode", option[1]) end),
            }
        end
        buttons[#buttons + 1] = row
    elseif self.mode == "public_account" and self.on_import_mp_link and self.on_imported_mp_links then
        buttons[#buttons + 1] = {{text = _("Import article link"), callback = action(self.on_import_mp_link)}}
        buttons[#buttons + 1] = {{text = _("Imported articles"), callback = action(self.on_imported_mp_links)}}
        if self.on_manage_mp_accounts then
            buttons[#buttons + 1] = {{text = _("Manage public account subscriptions"), callback = action(self.on_manage_mp_accounts)}}
        end
    end
    if self.on_offline_changes then
        buttons[#buttons+1]={{text=_('Offline changes'),callback=action(self.on_offline_changes)}}
    end
    if not self.cover_mode then
        local row = {}
        for _, option in ipairs({ { true, _("Page mode") }, { false, _("Continuous scrolling") } }) do
            row[#row + 1] = {
                text = option[2], checked_func = function() return self.paged == option[1] end,
                callback = action(function() self.on_display_change("paginated", option[1]) end),
            }
        end
        buttons[#buttons + 1] = row
    end
    dialog = ButtonDialog:new{ title = _("Bookshelf"), buttons = buttons }
    dialog.movable[1].radius = 0
    Popup.show(self,dialog)
end

function LibraryView:itemStatus(book)
    if self.mode == "public_account" then return book.author or "" end
    local status
    local pending=self.finish_pending and self.finish_pending[tostring(book.bookId or book.book_id or '')]
    if pending then
        status=_(pending.desired and 'Done' or 'Not finished')..' · '.._(pending.phase=='queued' and 'Pending sync' or 'Needs review')
    elseif is_finished(book) then
        status = _("Done")
    elseif type(book._shelf_progress) == "number" then
        status = ShelfProgress.label(book._shelf_progress,book._shelf_progress_local,book._shelf_progress_exact) or ""
    else
        status = ShelfTime.date(self.last_read_times and self.last_read_times[book] or book.readUpdateTime) or ""
    end
    local parts={}
    local id=self.local_pins and require('weread.lib.shelf_snapshot').persisted_id(book)
    if id and self.local_pins[id] then parts[#parts+1]=_('Local pin') end
    if ShelfFlags.display(book,'pinned')==true then parts[#parts+1]=_('Pinned') end
    if is_private_book(book) then parts[#parts+1]=_('Private') end
    if status~='' then parts[#parts+1]=status end
    status=table.concat(parts,' · ')
    if book._cached then
        status = status ~= "" and ("✓  " .. status) or "✓"
    end
    return status
end

function LibraryView:preparePagination()
    local source = self.mode == "public_account"
        and (self.accounts or {}) or (self.books or {})
    self.page_size = math.max(1, math.floor(tonumber(self.page_size) or 10))
    if self.cover_mode then
        local columns = math.max(1, math.floor(tonumber(self.cover_columns) or 3))
        local rows = math.max(1, math.floor(tonumber(self.cover_rows) or 2))
        self.page_size = columns * rows
    end
    if self.paged then
        self.page_count = math.max(1, math.ceil(#source / self.page_size))
        self.page = math.max(
            1,
            math.min(math.floor(tonumber(self.page) or 1), self.page_count)
        )
    end
end

function LibraryView:content()
    local source = self.mode == "public_account"
        and (self.accounts or {}) or (self.books or {})
    local group = not self.paged and not self.cover_mode and ShelfListGroup or VerticalGroup
    local content = group:new{
        align = "left",
        HorizontalSpan:new{ width = self.list_width },
    }
    self._item_rows = {}
    self._focus_item_rows = {}
    self._list_bottoms = nil
    if group == ShelfListGroup then content._shelf_rows = self._item_rows end
    if self.on_prepare_visible_status then content._status_view = self end
    if #source == 0 then
        table.insert(content, VerticalSpan:new{ width = Size.padding.large })
        table.insert(content, TextWidget:new{
            text = self.empty_text or (self.keyword and self.keyword ~= "" and _("No shelf matches.") or _("No items.")),
            face = Font:getFace("cfont", 20),
            max_width = self.content_width,
        })
        return content
    end
    local first = 1
    local last = #source
    if self.paged then
        first = (self.page - 1) * self.page_size + 1
        last = math.min(#source, first + self.page_size - 1)
    end
    if self.cover_mode then
        local columns = math.max(1, math.floor(tonumber(self.cover_columns) or 3))
        local rows = math.max(1, math.floor(tonumber(self.cover_rows) or 2))
        local cell_width = math.floor(self.content_width / columns)
        local cell_height = math.floor(math.max(
            1,
            tonumber(self.cover_cell_height) or math.floor(self.screen_h * 0.28)
        ))
        local grid_height = math.max(cell_height, tonumber(self.cover_content_height)
            or cell_height * rows)
        local grid_row
        for index = first, last do
            local book = source[index]
            local column = ((index - first) % columns) + 1
            local row = math.floor((index - first) / columns) + 1
            if column == 1 then
                grid_row = {}
                self._focus_item_rows[#self._focus_item_rows + 1] = grid_row
                table.insert(content, HorizontalGroup:new(grid_row))
            end
            local width = column == columns
                and self.content_width - cell_width * (columns - 1)
                or cell_width
            local height = row == rows and grid_height - cell_height * (rows - 1)
                or cell_height
            local cover_cell = CoverCell:new{
                book = book,
                local_pinned = self.local_pins and self.local_pins[require('weread.lib.shelf_snapshot').persisted_id(book) or '']==true,
                finish_pending = self.finish_pending and self.finish_pending[tostring(book.bookId or book.book_id or '')],
                cached = book._cached == true,
                cover_path = self.cover_paths and self.cover_paths[book] or nil,
                cover_loading = self.cover_loading and self.cover_loading[book] == true,
                contain_cover = self.mode == "public_account",
                store_details = self.store_details,
                store_reason = self.store_reason,
                width = width,
                height = math.max(1, height),
                show_parent = self,
                callback = function()
                    if self.on_select then self.on_select(book, self.mode) end
                end,
                hold_callback = self.on_hold and self.mode == "books" and function()
                    self.on_hold(book, self.mode)
                end or nil,
            }
            self._item_rows[#self._item_rows + 1] = cover_cell
            grid_row[#grid_row + 1] = cover_cell
        end
    else
        local lazy_height, lazy_status_widths
        local defer_status = self.on_prepare_visible_status ~= nil
        local list_y = 0
        if not self.paged then
            self._list_bottoms = {}
            local probe = ShelfRow:new{ text = "", status = "", width = self.list_width,
                font_size = self.mode == "books" and 20 or 22 }
            lazy_height = probe:getSize().h
            if probe.free then probe:free() end
            lazy_status_widths = {}
        end
        for index = first, last do
            local book = source[index]
            local shelf_row = ShelfRow:new{
                book = book,
                text = book.title or book.bookId or book.book_id or _("Untitled"),
                status = defer_status and "" or self:itemStatus(book),
                defer_status = defer_status,
                width = self.list_width,
                font_size = self.mode == "books" and 20 or 22,
                lazy_frame = not self.paged,
                lazy_row_height = lazy_height,
                lazy_status_widths = lazy_status_widths,
                show_parent = self,
                callback = function()
                    if self.on_select then self.on_select(book, self.mode) end
                end,
                hold_callback = self.on_hold and self.mode == "books" and function()
                    self.on_hold(book, self.mode)
                end or nil,
            }
            shelf_row._shelf_list_row = not self.paged
            self._item_rows[#self._item_rows + 1] = shelf_row
            if self._list_bottoms then
                local bottom = list_y + shelf_row:getSize().h
                self._list_bottoms[#self._list_bottoms + 1] = bottom
                list_y = bottom + 1
            end
            self._focus_item_rows[#self._focus_item_rows + 1] = { shelf_row }
            table.insert(content, shelf_row)
            table.insert(content, HorizontalGroup:new{
                HorizontalSpan:new{ width = Size.padding.large },
                LineWidget:new{
                    dimen = Geom:new{ w = self.list_width - 2 * Size.padding.large, h = 1 },
                    background = Blitbuffer.COLOR_GRAY,
                },
            })
        end
    end
    return content
end

function LibraryView:showPageJump()
    if self._shelf_closed or self._shelf_popup or UIManager:getTopmostVisibleWidget() ~= self
        or not self.paged or self.page_count <= 1 or not self.on_page_changed then return end
    local Popup = require("weread.ui.shelf_popup")
    local limit = self.page_count
    local dialog
    local function finish(page)
        if not Popup.current(self, dialog) then return end
        Popup.close(self)
        if page and page ~= self.page then self.on_page_changed(page) end
    end
    dialog = require("ui/widget/inputdialog"):new{
        title = T(_("Go to page (1–%1)"), limit),
        input = "", input_type = "number",
        buttons = {
            {
                { text = _("First page"), enabled = self.page > 1, callback = after_tap(function() finish(1) end) },
                { text = _("Last page"), enabled = self.page < limit, callback = after_tap(function() finish(limit) end) },
            },
            {
                { text = _("Cancel"), callback = after_tap(function() finish() end) },
                { text = _("Go to page"), is_enter_default = true, callback = after_tap(function()
                    if not Popup.current(self, dialog) then return end
                    local input = require("weread.lib.search_query").trim(dialog:getInputText())
                    local page = input:match("^%d+$") and tonumber(input)
                    if not page or page < 1 or page > limit then
                        require("ui/widget/notification"):notify(T(_("Enter a whole page number from 1 to %1."), limit))
                        return
                    end
                    finish(page)
                end) },
            },
        },
    }
    Popup.show(self, dialog, function(widget)
        UIManager:show(widget)
        widget:onShowKeyboard()
    end)
end

function LibraryView:pageBar()
    if not self.paged or (self.page_count or 1) <= 1 then return nil end
    local cell_w = math.floor(self.screen_w / 3)
    local button_height = Screen:scaleBySize(54)
    local previous = Button:new{
        text = _("Previous"), width = cell_w, height = button_height,
        text_font_size = 22, text_font_bold = true, radius = 0, margin = 0, padding = 0,
        bordersize = 0, enabled = self.page > 1, show_parent = self,
        callback = after_tap(function()
            if self.page > 1 and self.on_page_changed then
                self.on_page_changed(self.page - 1)
            end
        end),
    }
    local page_text = Button:new{
        text = T(_("%1/%2 pages"), tostring(self.page), tostring(self.page_count)),
        width = cell_w, height = button_height, text_font_size = 18,
        radius = 0, margin = 0, bordersize = 0, padding = 0,
        enabled = self.on_page_changed ~= nil, show_parent = self,
        callback = after_tap(function() self:showPageJump() end),
    }
    local next_page = Button:new{
        text = _("Next"), width = self.screen_w - 2 * cell_w,
        height = button_height, text_font_size = 22, text_font_bold = true,
        radius = 0, margin = 0, bordersize = 0, padding = 0,
        enabled = self.page < self.page_count, show_parent = self,
        callback = after_tap(function()
            if self.page < self.page_count and self.on_page_changed then
                self.on_page_changed(self.page + 1)
            end
        end),
    }
    self._page_buttons = { previous, page_text, next_page }
    return HorizontalGroup:new{ previous, page_text, next_page }
end

function LibraryView:init()
    self.ges_events = {}
    self.screen_w = Screen:getWidth()
    self.screen_h = Screen:getHeight()
    self.screen_rotation = Screen.getRotationMode and Screen:getRotationMode()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }
    self.covers_fullscreen = true
    self.outer_margin = 0
    self.content_width = self.screen_w
    self.list_width = self.screen_w - 3 * Screen:scaleBySize(6)
    if Device:hasKeys() then self.key_events.Close = { { Device.input.group.Back } } end

    local header = self:headerBar()
    local actions = self:actionBar(self.actions)
    local navigation = self:actionBar(self.navigation, true)
    local status, summary, recent_heading
    if self.home_layout then
        if self.home_layout.show_status then
            status, self._home_status_label = self:homeTextRow(self.status_text or "", HomeLayout.HEIGHTS.status, 13, false)
            self._home_status_frame = status
        end
        if self.home_layout.show_summary then
            summary = Button:new{
                text = self.summary_text or "", width = self.screen_w, height = Screen:scaleBySize(HomeLayout.HEIGHTS.summary),
                text_font_size = 16, avoid_text_truncation = false, radius = 0, margin = 0, padding = 0, bordersize = 0,
                show_parent = self, callback = after_tap(self.on_summary or function() end),
            }
            self._summary_button = summary
        end
        recent_heading = self:homeTextRow(_("Recently read"), HomeLayout.HEIGHTS.recent_label, 16, true)
    end
    self:preparePagination()
    local page_bar = self:pageBar()
    local scroll_h = math.max(1, self.screen_h - header:getSize().h
        - (page_bar and page_bar:getSize().h or 0)
        - (actions and actions:getSize().h or 0)
        - (status and status:getSize().h or 0) - (summary and summary:getSize().h or 0)
        - (recent_heading and recent_heading:getSize().h or 0)
        - (navigation and navigation:getSize().h or 0))
    if self.cover_mode then
        local rows = math.max(1, math.floor(tonumber(self.cover_rows) or 2))
        self.cover_content_height = scroll_h
        self.cover_cell_height = math.max(1, math.floor(scroll_h / rows))
    end
    local content = self:content()
    local scroll = ScrollableContainer:new{
        dimen = Geom:new{ w = self.screen_w, h = scroll_h },
        show_parent = self,
        VerticalGroup:new{ align = "left", content },
    }
    self.scroll = scroll
    local offset = self.scroll_offset
    local browse = self.browse_scroll
    if browse and self._list_bottoms and self._list_bottoms[browse.index] then
        local top = ShelfVisible.top(self._list_bottoms, browse.index)
        local height = self._list_bottoms[browse.index] - top
        offset = { x = offset and offset.x or 0, y = top + math.max(-1, math.min(browse.inset or 0, height - 1)) }
    end
    if offset and not self.paged then
        scroll:initState()
        scroll:setScrolledOffset(offset)
        scroll:_scrollBy(0, 0) -- Clamp to the current list if it shrank while details were open.
    end
    if not self.paged and self.on_visible_changed then
        local scroll_by = scroll._scrollBy
        scroll._scrollBy = function(container, ...)
            scroll_by(container, ...)
            if self._visible_task then UIManager:unschedule(self._visible_task) end
            self._visible_task = function()
                self._visible_task = nil
                self.on_visible_changed()
            end
            UIManager:scheduleIn(0.3, self._visible_task)
        end
    end
    local rows = { self._header_buttons }
    local first_item_row, focus_x, focus_y
    local focus_index = self.focus_book_index
    if offset and not self.paged and self._list_bottoms then
        local top = self:getScrollOffset().y
        local bottom = focus_index and self._list_bottoms[focus_index]
        if not bottom or bottom <= top or ShelfVisible.top(self._list_bottoms, focus_index) >= top + scroll.dimen.h then
            focus_index = ShelfVisible.first(self._list_bottoms, top)
        end
    end
    local focused_book = focus_index and self._item_rows[focus_index - (self.page - 1) * self.page_size]
    local function book_rows()
        first_item_row = #self._focus_item_rows > 0 and #rows + 1 or nil
        for _, item_row in ipairs(self._focus_item_rows) do
            rows[#rows + 1] = item_row
            if focused_book and not focus_y then
                for x, item in ipairs(item_row) do
                    if item == focused_book then focus_x, focus_y = x, #rows; break end
                end
            end
        end
        if self._page_buttons then rows[#rows + 1] = self._page_buttons end
    end
    if self.home_layout then
        for _, key in ipairs(self.home_layout.sections) do
            if key == "shortcuts" and self._action_buttons then rows[#rows + 1] = self._action_buttons
            elseif key == "summary" and summary then rows[#rows + 1] = { summary }
            elseif key == "recent" then book_rows() end
        end
    else
        if self._action_buttons then rows[#rows + 1] = self._action_buttons end
        book_rows()
    end
    local outside_scroll = {}
    for _i, button in ipairs(self._header_buttons) do outside_scroll[button] = true end
    if self._page_buttons then
        for _i, button in ipairs(self._page_buttons) do outside_scroll[button] = true end
    end
    if summary then outside_scroll[summary] = true end
    if self._navigation_buttons then rows[#rows + 1] = self._navigation_buttons end
    for _, button in ipairs(self._action_buttons or {}) do outside_scroll[button] = true end
    for _, button in ipairs(self._navigation_buttons or {}) do outside_scroll[button] = true end
    self._first_item_focus_row = first_item_row
    FocusNav.apply(self, rows, { scroll = scroll, outside_scroll = outside_scroll })
    FocusNav.initialFocus(self, focus_x or 1, focus_y or first_item_row or 1)
    local body = { align = "left", header }
    if self.home_layout then
        local recent = VerticalGroup:new{ align = "left", recent_heading, scroll,
            page_bar or VerticalSpan:new{ width = 0 } }
        local sections = { status = status, summary = summary, shortcuts = actions, recent = recent }
        for _, key in ipairs(self.home_layout.sections) do if sections[key] then body[#body + 1] = sections[key] end end
    else
        if actions then body[#body + 1] = actions end
        body[#body + 1] = scroll
        body[#body + 1] = page_bar or VerticalSpan:new{ width = 0 }
    end
    if navigation then body[#body + 1] = navigation end
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0, padding = 0, margin = 0,
        dimen = self.dimen:copy(), VerticalGroup:new(body),
    }
    if self.paged then
        -- Let horizontal swipes reach the shelf pager, not the inner scroller.
        scroll.onScrollableSwipe = function() return false end
        self.ges_events.ShelfSwipe = {
            GestureRange:new{ ges = "swipe", range = scroll.dimen },
        }
    end
    if Device:hasKeys() then
        self.onNextPage = function(view) return view:turnShelfPage(1) end
        self.onPrevPage = function(view) return view:turnShelfPage(-1) end
    end
end

function LibraryView:turnShelfPage(direction)
    if self.paged then
        local page = self.page + direction
        if page >= 1 and page <= self.page_count and self.on_page_changed then self.on_page_changed(page) end
        return true
    end

    -- The viewport may have moved by touch since the last focus change.
    local scrolled
    if direction > 0 then scrolled = self.scroll:onScrollPageDown()
    else scrolled = self.scroll:onScrollPageUp() end
    if scrolled and Device:hasDPad() and self._first_item_focus_row then
        local index = ShelfVisible.first(self._list_bottoms, self:getScrollOffset().y)
        local y = self._first_item_focus_row + index - 1
        if index <= #self._list_bottoms and (self.selected.y ~= y or self.selected.x ~= 1) then
            self:moveFocusTo(1, y, FocusManager.FORCED_FOCUS)
        end
    end
    return true
end

function LibraryView:onShelfSwipe(_, ges)
    if not self.paged then return false end
    local delta = ges.direction == "west" and 1 or ges.direction == "east" and -1
    if not delta then return false end
    return self:turnShelfPage(delta)
end

function LibraryView:onShow()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    return true
end

-- KOReader delivers rotation before the file manager has resized the screen.
-- Reflow on the next tick, once, and only while this page is still visible.
function LibraryView:onSetRotationMode()
    local top=UIManager:getTopmostVisibleWidget()
    if self._shelf_closed or self._rotation_task or not self._rotation_redraw
        or top~=self and (not self._shelf_popup or top~=self._shelf_popup) then return false end
    self._rotation_task=function()
        self._rotation_task=nil
        local visible=UIManager:getTopmostVisibleWidget()
        if self._shelf_closed or visible~=self and (not self._shelf_popup or visible~=self._shelf_popup) then return end
        local rotation=Screen.getRotationMode and Screen:getRotationMode()
        if self.screen_w~=Screen:getWidth() or self.screen_h~=Screen:getHeight() or self.screen_rotation~=rotation then
            require('weread.ui.shelf_popup').redraw(self,function()
                if not self._shelf_closed and UIManager:getTopmostVisibleWidget()==self then self._rotation_redraw() end
            end)
        end
    end
    UIManager:nextTick(self._rotation_task)
    return false
end

function LibraryView:onCloseWidget()
    self._shelf_closed=true
    if self._rotation_task then UIManager:unschedule(self._rotation_task);self._rotation_task=nil end
    require('weread.ui.shelf_popup').close(self)
    if self._visible_task then UIManager:unschedule(self._visible_task) self._visible_task = nil end
    UIManager:setDirty(nil, function() return "ui", self.dimen end)
end

function LibraryView:onClose()
    if self.on_close then self.on_close() end
    UIManager:close(self)
    return true
end

local M = {}

function M.bookIndex(books, id)
    for index, book in ipairs(books) do
        if ShelfSnapshot.persisted_id(book) == id then return index end
    end
end

function M.navigation(entries, parent)
    return LibraryView.actionBar(parent, entries, true)
end

-- Measure before fetching covers, so the worker and the visible grid agree.
function M.getLayout(cover_mode, count, mode, extra_height, options)
    options = options or {}
    local width, height = Screen:getWidth(), Screen:getHeight()
    local header_height = Screen:scaleBySize(HEADER_SIZE + (extra_height or 0)) + Size.border.thin
    if options.home then
        header_height = Screen:scaleBySize(HEADER_SIZE) + Size.border.thin
            + HomeLayout.reserved(options.home, function(value) return Screen:scaleBySize(value) end)
    end
    local page_bar_height = Screen:scaleBySize(54)
    local function layout(reserved)
        if cover_mode then
            return CoverLayout.calculate{
                width = width, height = height,
                size_scale = Screen:scaleBySize(1000) / 1000,
                reserved_height = reserved,
                max_columns = options.store and 3 or nil,
                max_rows = options.store and 2 or nil,
                min_cell_width = options.home and options.home.density == "compact"
                    and math.ceil(140 * math.sqrt(Screen:scaleBySize(1000) / 1000)) or nil,
                min_cell_height = options.home and options.home.density == "compact"
                    and math.ceil(180 * math.sqrt(Screen:scaleBySize(1000) / 1000)) or nil,
            }
        end
        local row = ShelfRow:new{ width = width, text = "", font_size = mode == "public_account" and 22 or 20 }
        local row_height = row:getSize().h + 1
        if row.free then row:free() end
        return { page_size = math.max(1, math.floor((height - reserved) / row_height)) }
    end
    local result = layout(header_height)
    if count > result.page_size then result = layout(header_height + page_bar_height) end
    return result
end

function M.show(data, callbacks)
    callbacks = callbacks or {}
    local view = LibraryView:new{
        mode = data.mode,
        portal = data.portal,
        home_layout = data.home_layout,
        store_details = data.store_details,
        store_reason = data.store_reason,
        status_text = data.status_text,
        summary_text = data.summary_text,
        empty_text = data.empty_text,
        actions = data.actions,
        navigation = data.navigation,
        title = data.title,
        wp_enable = data.wp_enable ~= false,
        books = data.books,
        local_pins = data.local_pins,
        last_read_times = data.last_read_times,
        groups = data.groups,
        group_membership_incomplete = data.group_membership_incomplete,
        group_key = data.group_key,
        group_keys = data.group_keys,
        group_label = data.group_label,
        total_books = data.total_books,
        scroll_offset = data.scroll_offset,
        browse_scroll = data.browse_scroll,
        accounts = data.accounts,
        keyword = data.keyword,
        sort_label = data.sort_label,
        filter_label = data.filter_label,
        paged = data.paged == true,
        page = data.page,
        page_size = data.page_size,
        focus_book_index = data.focus_book_index,
        cover_mode = data.cover_mode == true,
        cover_columns = data.cover_columns,
        cover_rows = data.cover_rows,
        cover_cell_height = data.cover_cell_height,
        cover_paths = data.cover_paths,
        cover_loading = data.cover_loading,
        finish_pending = data.finish_pending,
        on_close = callbacks.on_close,
        on_switch = callbacks.on_switch,
        on_select_group = callbacks.on_select_group,
        on_select_groups = callbacks.on_select_groups,
        on_manage_local_groups = callbacks.on_manage_local_groups,
        on_display_change = callbacks.on_display_change,
        on_search = callbacks.on_search,
        on_refresh = callbacks.on_refresh,
        on_settings = callbacks.on_settings,
        on_summary = callbacks.on_summary,
        on_sort = callbacks.on_sort,
        on_filter = callbacks.on_filter,
        on_import_mp_link = callbacks.on_import_mp_link,
        on_imported_mp_links = callbacks.on_imported_mp_links,
        on_manage_mp_accounts = callbacks.on_manage_mp_accounts,
        on_offline_changes = callbacks.on_offline_changes,
        on_select = callbacks.on_select,
        on_hold = callbacks.on_hold,
        on_page_changed = callbacks.on_page_changed,
        on_prepare_visible_status = callbacks.on_prepare_visible_status,
        on_visible_changed = callbacks.on_visible_changed,
    }
    UIManager:show(view)
    return view
end

return M
