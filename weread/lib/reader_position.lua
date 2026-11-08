-- Local KOReader geometry only. This does not interpret WeRead source offsets.
local _ = require("weread.lib.i18n").tr
local Position = {}

local function finite(value)
    value = tonumber(value)
    return value and value == value and math.abs(value) < math.huge and value or nil
end

local function read(document, method)
    if type(document[method]) ~= "function" then return nil end
    local ok, value = pcall(document[method], document)
    return ok and finite(value) or nil
end

local function ratio(value, total)
    value, total = finite(value), finite(total)
    if not value or value < 0 or not total or total <= 0 then return nil end
    return math.max(0, math.min(1, value / total))
end

function Position.fraction(document, footer, view_mode)
    if not document then return nil end
    local function page_fraction()
        return ratio(read(document, "getCurrentPage") or read(document, "getPageNumber"), read(document, "getPageCount"))
    end
    local function scroll_fraction()
        return ratio(read(document, "getCurrentPos") or document.current_pos,
            document.info and document.info.doc_height or document.doc_height)
    end
    local primary, secondary = page_fraction, scroll_fraction
    if view_mode == "scroll" then primary, secondary = secondary, primary end
    local value = primary()
    if value ~= nil then return value end
    value = secondary()
    if value ~= nil then return value end
    -- Footer updates may run after PageUpdate/PosUpdate listeners. It is only
    -- a compatibility fallback when the live document exposes no usable value.
    local cached = finite(footer and footer.percent_finished)
    if cached then return math.max(0, math.min(1, cached > 1 and cached / 100 or cached)) end
end

function Position.goto_fraction(ui, value)
    local fraction = finite(value)
    if not fraction or not ui then return false, _("Could not navigate to the reading position.") end
    local percent = math.max(0, math.min(1, fraction)) * 100
    local ok, result = pcall(function()
        if ui.rolling and type(ui.rolling.onGotoPercent) == "function" then
            return ui.rolling:onGotoPercent(percent)
        elseif type(ui.handleEvent) == "function" then
            return ui:handleEvent(require("ui/event"):new("GotoPercent", percent)) == true
        end
        return false
    end)
    if not ok then return false, result end
    if result == false then return false, _("Could not navigate to the reading position.") end
    return true
end

return Position
