-- Search the catalog already on screen without reloading or changing its rows.
local Search = require("weread.lib.shelf_search")
local Catalog = require("weread.lib.chapter_catalog")
local Query = require("weread.lib.search_query")
local Popup = require("weread.ui.shelf_popup")
local Util = require("weread.lib.plugin_util")
local _, T = Util.tr, Util.T

local M = {}

local function matches_title(title, needle, terms, normalize)
    local position, folded = Search.find(title, needle, normalize)
    if position then return true end
    if not folded or #terms < 2 then return false end
    for _, term in ipairs(terms) do
        if not folded:find(term, 1, true) then return false end
    end
    return true
end

function M.title_filter(rows, empty_title)
    local normalize
    return function(query)
        local needle = Search.prepare(query)
        if not needle then return end
        -- The cache belongs to this catalog and is allocated on its first search.
        normalize = normalize or Search.cached_fold(Catalog.MAX_CHAPTERS, 1024 * 1024)
        local terms = Search.terms(needle)
        local matches, counts = {}, {}
        for index, row in ipairs(rows) do
            local title = row.title == "" and empty_title or row.title
            if matches_title(title, needle, terms, normalize) then
                matches[#matches + 1] = index
                counts[title] = (counts[title] or 0) + 1
            end
        end
        return matches, counts
    end
end

function M.label(title, index, counts, label)
    label = label or title
    if index and counts and counts[title] > 1 then
        return T("%1. %2", index, label)
    end
    return label
end

function M.prompt(host, view, query, current, apply)
    if not current() then return end
    local dialog
    local function submit(value)
        if not current() or not Popup.current(view, dialog) then return end
        local next_query = Query.trim(value)
        if #next_query > 1024 then host:showInfo(_("Search text is too long.")); return end
        Popup.close(view)
        if next_query ~= query then apply(next_query) end
    end
    dialog = require("ui/widget/inputdialog"):new{
        title = _("Find chapter"), input = query, input_type = "text",
        buttons = {{
            { text = _("Clear"), callback = function() submit("") end },
            { text = _("Search"), is_enter_default = true, callback = function() submit(dialog:getInputText()) end },
        }},
    }
    Popup.show(view, dialog, function(widget) host:showInputDialog(widget) end)
end

return M
