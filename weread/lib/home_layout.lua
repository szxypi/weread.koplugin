-- Small device-wide layout preferences. Account data remains in LibraryDB.
local M = { HEIGHTS = { status = 28, summary = 54, shortcuts = 54, recent_label = 28 } }
M.SECTIONS = { "status", "summary", "shortcuts", "recent" }
M.SHORTCUTS = { "shelf", "store", "search", "profile", "settings", "refresh" }
local defaults = { "shelf", "store", "search", "settings" }

local function ordered(values, allowed, fallback, append, maximum)
    local result, seen, valid = {}, {}, {}
    for _, key in ipairs(allowed) do valid[key] = true end
    for _, key in ipairs(type(values) == "table" and values or fallback) do
        if type(key) == "string" and valid[key] and not seen[key] and #result < maximum then
            result[#result + 1], seen[key] = key, true
        end
    end
    if append then
        for _, key in ipairs(allowed) do if not seen[key] then result[#result + 1] = key end end
    end
    return result
end

function M.normalize(raw)
    raw = type(raw) == "table" and raw or {}
    local limit = tonumber(raw.recent_limit)
    return {
        view_mode = raw.view_mode == "list" and "list" or "cover",
        density = raw.density == "compact" and "compact" or "comfortable",
        recent_limit = (limit == 6 or limit == 12 or limit == 24) and limit or 12,
        show_status = raw.show_status ~= false, show_summary = raw.show_summary ~= false,
        show_shortcuts = raw.show_shortcuts ~= false,
        sections = ordered(raw.sections, M.SECTIONS, M.SECTIONS, true, 4),
        shortcuts = ordered(raw.shortcuts, M.SHORTCUTS, defaults, false, 4),
    }
end

function M.move(values, key, delta)
    local result = {}
    for index, value in ipairs(values) do result[index] = value end
    for index, value in ipairs(result) do
        local target = index + delta
        if value == key and target >= 1 and target <= #result then
            result[index], result[target] = result[target], result[index]
            break
        end
    end
    return result
end

function M.reserved(preferences, scale)
    local height = scale(54) + scale(M.HEIGHTS.recent_label) -- navigation + recent heading
    if preferences.show_status then height = height + scale(M.HEIGHTS.status) end
    if preferences.show_summary then height = height + scale(M.HEIGHTS.summary) end
    if preferences.show_shortcuts and #preferences.shortcuts > 0 then height = height + scale(M.HEIGHTS.shortcuts) end
    return height
end

local function call(object, method)
    if not object or type(object[method]) ~= "function" then return nil end
    local ok, value = pcall(object[method], object)
    if ok then return value end
end

function M.status(device, network, now)
    local power = call(device, "getPowerDevice")
    local capacity = call(device, "hasBattery") and tonumber(call(power, "getCapacity"))
    if not capacity or capacity ~= capacity or capacity < 0 or capacity > 100 then capacity = nil end
    local on, connected = call(network, "isWifiOn"), call(network, "isConnected")
    if type(on) ~= "boolean" then on = nil end
    if type(connected) ~= "boolean" then connected = nil end
    return { clock = os.date("%m-%d %H:%M", now or os.time()),
        capacity = capacity and math.floor(capacity), charging = call(power, "isCharging") == true,
        wifi_on = on, connected = connected }
end

return M
