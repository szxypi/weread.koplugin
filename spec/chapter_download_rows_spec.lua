package.path = './?.lua;' .. package.path

local menu, top, screen_width
local dirty = {}
package.preload['ui/uimanager'] = function()
    return { getTopmostVisibleWidget = function() return top end,
        setDirty = function(_, widget, mode, region)
            assert(widget == menu and mode == 'ui')
            dirty[#dirty + 1] = region
        end }
end
package.preload.device = function()
    return { screen = { getWidth = function() return screen_width end, getHeight = function() return 800 end } }
end
local Rows = require('weread.ui.chapter_download_rows')

local function painted_region(y, height)
    return { x = 0, y = y, w = 600, h = height or 40,
        copy = function(region) return painted_region(region.y, region.h) end,
        combine = function(a, b)
            local top_edge = math.min(a.y, b.y)
            return painted_region(top_edge, math.max(a.y + a.h, b.y + b.h) - top_edge)
        end }
end

local function row(entry, index, y, focus)
    return {
        entry = entry, idx = index, text = entry.text, mandatory = entry.mandatory, builds = 0,
        _underline_container = { color = focus },
        { dimen = painted_region(y) },
        clear = function(widget) widget[1] = nil end,
        init = function(widget)
            widget.builds = widget.builds + 1
            widget._underline_container = { color = 'unfocused' }
            widget[1] = { getSize = function() return { w = 600, h = widget.resized and 45 or 40 } end }
        end,
    }
end

local function fixture()
    local header = { download = true, text = '0 selected' }
    local middle = { chapter_index = 1, text = '[  ] One', mandatory = '100 words' }
    local chapter = { chapter_index = 2, text = '[  ] Two', mandatory = '200 words' }
    local widgets = { row(header, 1, 80, 'unfocused'), row(middle, 2, 120, 'unfocused'), row(chapter, 3, 160, 'focused') }
    menu = { item_table = { header, middle, chapter }, item_group = widgets,
        is_borderless = true, screen_w = 600, screen_h = 800 }
    menu.show_parent = menu
    top, screen_width, dirty = menu, 600, {}
    header.text, chapter.text, chapter.mandatory = '1 selected', '[✓] Two', 'Selected'
    return widgets
end

local widgets = fixture()
assert(Rows.update(menu) and widgets[1].builds == 1 and widgets[2].builds == 0 and widgets[3].builds == 1)
assert(widgets[3].mandatory == 'Selected' and widgets[3]._underline_container.color == 'focused')
assert(#dirty == 1 and dirty[1].y == 80 and dirty[1].h == 120)
assert(Rows.update(menu) and #dirty == 1, 'identical rows requested another refresh')

widgets = fixture()
top = {}
assert(not Rows.update(menu) and not dirty[1] and widgets[1].builds == 0, 'an overlay allowed a partial repaint')
top, screen_width = menu, 800
assert(not Rows.update(menu) and widgets[1].builds == 0, 'resized screen used stale coordinates')
screen_width, menu.items_max_lines = 600, 2
assert(not Rows.update(menu) and widgets[1].builds == 0, 'a variable-height menu bypassed layout')

widgets = fixture()
widgets[3][1].dimen = nil
assert(not Rows.update(menu) and widgets[1].builds == 0 and not dirty[1], 'unpainted rows used partial refresh')
widgets = fixture()
menu.item_table[3] = {}
assert(not Rows.update(menu) and widgets[1].builds == 0 and not dirty[1], 'stale page used partial refresh')
widgets = fixture()
widgets[3].resized = true
assert(not Rows.update(menu) and not dirty[1], 'changed row geometry requested partial refresh')
print('chapter_download_rows_spec: fixed rows, focus and geometry fallbacks passed')
