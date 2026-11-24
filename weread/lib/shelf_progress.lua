-- Read-only display snapshots. Never write these into a reader's sync state.
local M = { TTL = 120 }
local Access = require("weread.lib.read_access")
M.book_id, M.selection, M.matches = Access.display_book_id, Access.capture, Access.matches

function M.supports(id, selected)
    return M.book_id(id) ~= nil and (Access.book_id(id) ~= nil or type(selected) == "table" and type(selected.web) == "table")
end

local function exact_percent(value)
    local n = tonumber(value)
    if n and n == n and n >= 0 and n <= 100 then return n end
end

local function percent(value)
    local n = exact_percent(value)
    if n then return math.floor(n) end
end

-- A pending position belongs to this device; it must not look like a
-- confirmed cloud percentage in the home or bookshelf views.
function M.label(value, local_position, exact)
    value=percent(value)
    if value==nil then return nil end
    exact=exact_percent(exact)
    local text=value==0 and exact and exact>0 and exact<1 and '<1%' or tostring(value)..'%'
    if local_position then
        local template=require('weread.lib.i18n').tr('Local · %1')
        return (template:gsub('%%1',function() return text end))
    end
    return text
end

function M.parse(data, id, now)
    if type(data) ~= "table" then return nil, "invalid" end
    if (data.errcode ~= nil and tonumber(data.errcode) ~= 0)
        or (data.errCode ~= nil and tonumber(data.errCode) ~= 0)
        or (data.succ ~= nil and data.succ ~= true and tonumber(data.succ) ~= 1) then return nil, "invalid" end
    if data.bookId ~= nil and tostring(data.bookId) ~= tostring(id) then return end
    if type(data.book) == "table" and data.book.bookId ~= nil and tostring(data.book.bookId) ~= tostring(id) then return end
    if type(data.book) ~= "table" or data.book.progress == nil then
        if data.recordReadingTime ~= nil then return nil, "unavailable" end
        return nil, "invalid"
    end
    local precise = exact_percent(data.book.progress)
    if not precise then return end
    return { book_id = tostring(id), percent = math.floor(precise), exact_percent = precise, fetched_at = now or os.time() }
end

function M.display(saved, snapshot, account, id)
    -- Legacy local records without an account binding cannot override this account's cloud data.
    local pending = type(saved) == "table" and saved.pending_upload_position
    local owner = type(saved) == "table" and (saved.pending_upload_account or saved.recent_read_account)
    if account and owner == account and type(pending) == "table"
        and (pending.book_id == nil or tostring(pending.book_id) == tostring(id)) then
        local precise = exact_percent(pending.percent)
        if precise then return math.floor(precise), true, precise end
    end
    local value = type(snapshot) == "table" and percent(snapshot.percent) or nil
    local precise = type(snapshot) == "table" and exact_percent(snapshot.exact_percent) or nil
    if not value or not precise or math.floor(precise) ~= value then precise = nil end
    -- Legacy zero was rounded down and cannot prove the exact value was zero.
    if not precise and value and value > 0 then precise = value end
    return value, false, precise
end

function M.fetch(client, ids, context, selected, options)
    selected = selected or M.selection(client.settings)
    local snapshots = {}
    if not selected then return { snapshots = snapshots, failed = true } end
    local access = options and options.web_only and selected.web or selected.gateway or selected.web
    if not access or options and options.web_only and not selected.web then return {snapshots=snapshots,failed=true} end
    local function current()
        context.checkCancelled()
        return M.matches(client.settings, selected)
    end
    for index, id in ipairs(ids) do
        if not current() then return { snapshots = {}, stale = true } end
        context.emit { stage = "shelf_progress", current = index, total = #ids }
        -- CB_ is verified only on Web. Do not send it to the gateway, and do
        -- not switch later ordinary books away from their selected channel.
        local book_access = type(id) == "string" and id:sub(1, 3) == "CB_" and selected.web or access
        if type(id) == "string" and id:sub(1, 3) == "CB_" and not selected.web then
            return { snapshots = snapshots, failed = true }
        end
        local ok, value = pcall(client.get_shelf_display_progress, client, id, book_access)
        if not current() then return { snapshots = {}, stale = true } end
        local snapshot, reason
        if ok then snapshot, reason = M.parse(value, id) end
        if not snapshot and reason ~= "unavailable" and book_access.kind == "gateway" and selected.web then
            -- After one failed gateway read, use Web for the rest of this batch.
            access = selected.web
            book_access = access
            ok, value = pcall(client.get_shelf_display_progress, client, id, book_access)
            if not current() then return { snapshots = {}, stale = true } end
            if ok then snapshot, reason = M.parse(value, id) else reason = nil end
        end
        if snapshot then
            snapshot.source = book_access.kind
            snapshots[#snapshots + 1] = snapshot
        elseif reason == "unavailable" then
            -- Cache absence for the same TTL, so cover redraws do not repeatedly
            -- fetch a book which has duration but no cloud reading position.
            snapshots[#snapshots + 1] = { book_id = tostring(id), fetched_at = os.time(),
                source = book_access.kind, unavailable = true }
        elseif reason ~= "unavailable" then
            -- Stop on the first service/auth/rate failure; do not flood the remaining books.
            return { snapshots = snapshots, failed = true,
                web_expired = not ok and book_access.kind == "web" and value == "display_progress/login" or nil,
                next_index = index }
        end
    end
    if not current() then return { snapshots = {}, stale = true } end
    return { snapshots = snapshots }
end

return M
