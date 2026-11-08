-- Read-only display snapshots. Never write these into a reader's sync state.
local M = { TTL = 120 }

local function percent(value)
    local n = tonumber(value)
    if n and n == n and n >= 0 and n <= 100 then return math.floor(n) end
end

function M.parse(data, id, now)
    if type(data) ~= "table" or type(data.book) ~= "table" then return end
    if data.bookId ~= nil and tostring(data.bookId) ~= tostring(id) then return end
    if data.book.bookId ~= nil and tostring(data.book.bookId) ~= tostring(id) then return end
    local value = percent(data.book.progress)
    if not value then return end
    return { book_id = tostring(id), percent = value, fetched_at = now or os.time() }
end

function M.display(saved, snapshot, account, id)
    -- Legacy local records without an account binding cannot override this account's cloud data.
    local pending = type(saved) == "table" and saved.pending_upload_position
    local owner = type(saved) == "table" and (saved.pending_upload_account or saved.recent_read_account)
    if account and owner == account and type(pending) == "table"
        and (pending.book_id == nil or tostring(pending.book_id) == tostring(id)) then
        local value = percent(pending.percent)
        if value then return value, true end
    end
    return type(snapshot) == "table" and percent(snapshot.percent) or nil, false
end

function M.fetch(client, ids, context)
    local snapshots = {}
    for index, id in ipairs(ids) do
        context.checkCancelled()
        context.emit { stage = "shelf_progress", current = index, total = #ids }
        local ok, value = pcall(client.get_progress, client, id)
        local snapshot = ok and M.parse(value, id)
        if not snapshot then
            -- Stop on the first service/auth/rate failure; do not flood the remaining books.
            return { snapshots = snapshots, failed = true }
        end
        snapshots[#snapshots + 1] = snapshot
    end
    context.checkCancelled()
    return { snapshots = snapshots }
end

return M
