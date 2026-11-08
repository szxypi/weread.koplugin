package.path = "./?.lua;./?/init.lua;" .. package.path
local Data = require("weread.lib.shelf_progress")
local checks = 0
local function expect(value, message)
    checks = checks + 1
    assert(value, message)
end
for _, n in ipairs({ 0, 1, 50, 100 }) do
    local result = Data.parse({ bookId = "a", book = { progress = n } }, "a", 1000)
    expect(result and result.percent == n and result.fetched_at == 1000, "percent units changed")
end
for _, n in ipairs({ -1, 101, math.huge, 0 / 0, "bad", false }) do
    expect(not Data.parse({ book = { progress = n } }, "a"), "invalid progress accepted")
end
expect(not Data.parse({ bookId = "b", book = { progress = 50 } }, "a"), "root book mismatch accepted")
expect(not Data.parse({ book = { bookId = "b", progress = 50 } }, "a"), "nested book mismatch accepted")
expect(not Data.parse({ progress = 50 }, "a"), "missing progress container accepted")
local saved = { recent_read_account = "account-a", pending_upload_position = { percent = 83, book_id = "a" }, progress = 83 }
local snapshot = { percent = 37, fetched_at = 1000 }
local value, pending = Data.display(saved, snapshot, "account-a", "a")
expect(value == 83 and pending and saved.progress == 83 and snapshot.percent == 37, "local pending display was overwritten")
expect(Data.display(saved, snapshot, "account-b", "a") == 37, "another account's local progress displayed")
expect(Data.display(saved, snapshot, "account-a", "b") == 37, "another book's local position displayed")
expect(Data.display({}, nil, "account-a", "a") == nil, "missing progress invented")
local calls = {}
local ctx = { checkCancelled = function() end, emit = function() end }
local client = { get_progress = function(_self, id)
    calls[#calls + 1] = id
    if id == "bad" then error("private response must not be persisted") end
    return { bookId = id, book = { progress = 37 } }
end }
local batch = Data.fetch(client, { "a", "bad", "never" }, ctx)
expect(batch.failed and #batch.snapshots == 1 and #calls == 2, "failed batch flooded remaining books or lost valid prefix")
expect(batch.error == nil, "raw response error persisted")
local cancel_checks = 0
calls = {}
local ok = pcall(Data.fetch, client, { "a", "b" }, {
    emit = function() end,
    checkCancelled = function() cancel_checks = cancel_checks + 1 if cancel_checks > 1 then error("cancelled") end end,
})
expect(not ok and #calls == 1, "cancelled batch kept fetching")

local tasks, cancellations, writes, redrawn, account, online, configured = {}, {}, {}, 0, "account-a", true, true
local worker = {
    available = function() return true end,
    start = function(_self, options)
        local request = { options = options }
        tasks[#tasks + 1] = request
        return true, request
    end,
    cancel = function(_self, request) cancellations[#cancellations + 1] = request end,
}
local Progress = require("weread.ui.shelf_progress")
local cache = { a = { book_id = "a", percent = 37, fetched_at = os.time() } }
local host = setmetatable({
    settings = {
        get = function() return { a = saved } end,
        set = function() error("display refresh wrote reader settings") end,
        is_api_configured = function() return configured end,
    },
    library_db = {
        accountKey = function() return account end,
        getShelfProgress = function() return cache end,
        putShelfProgress = function(_self, snapshots) writes[#writes + 1] = snapshots return true end,
    },
    shelf_progress_worker = worker, client = client,
    isNetworkOnline = function() return online end,
    shelf_view = {},
}, { __index = Progress })
local books = { { bookId = "a" }, { bookId = "b" } }
host:prepareShelfProgress(books)
expect(books[1]._shelf_progress == 83 and books[1]._shelf_progress_local and books[2]._shelf_progress == nil,
    "cached/local progress not prepared for display")
host:refreshVisibleShelfProgress(host.shelf_view, books, cache, { on_redraw = function() redrawn = redrawn + 1 end })
expect(#tasks == 1, "visible batch not queued")
host:refreshVisibleShelfProgress({}, books, cache, { on_redraw = function() redrawn = redrawn + 10 end })
expect(#tasks == 1, "cover redraw restarted an identical progress request")
local result = tasks[1].options.task(ctx)
expect(#result.snapshots == 1 and result.snapshots[1].book_id == "b", "fresh cache not respected")
tasks[1].options.on_done { ok = true, value = result }
expect(#writes == 1 and redrawn == 10, "completion did not redraw latest view")
host:refreshVisibleShelfProgress({}, books, cache, { force = true })
local stale_task = tasks[#tasks]
expect(#stale_task.options.task(ctx).snapshots == 2, "manual force did not bypass fresh cache")
host:refreshVisibleShelfProgress({}, { { bookId = "c" } }, {}, {})
expect(cancellations[#cancellations] == stale_task, "page change did not cancel old request")
stale_task.options.on_done { ok = true, value = result }
expect(#writes == 1, "stale page wrote display data")
local current = tasks[#tasks]
account = "account-b"
current.options.on_done { ok = true, value = result }
expect(#writes == 1, "completion wrote to a different account database")
account = "account-a"
host:cancelShelfProgress()
host:refreshVisibleShelfProgress({}, books, cache, { force = true })
current = tasks[#tasks]
host.discovery_epoch = 1
current.options.on_done { ok = true, value = result }
expect(#writes == 1, "closed epoch wrote snapshots")
host:cancelShelfProgress()
online = false
local count = #tasks
host:refreshVisibleShelfProgress({}, books, {}, {})
expect(#tasks == count, "offline display started HTTP")
online, configured = true, false
host:refreshVisibleShelfProgress({}, books, {}, {})
expect(#tasks == count, "missing API key started HTTP")
configured = true
host:refreshVisibleShelfProgress({}, books, {}, {})
tasks[#tasks].options.on_done { ok = true, value = { snapshots = {}, failed = true } }
count = #tasks
host:refreshVisibleShelfProgress({}, books, {}, {})
expect(#tasks == count and host.shelf_progress_retry_at, "failed service immediately retried")
host.shelf_progress_retry_at = nil
cache.a.fetched_at = os.time() - Data.TTL - 1
host:refreshVisibleShelfProgress({}, { books[1] }, cache, {})
expect(#tasks == count + 1, "expired snapshot not refreshed")
print("shelf_progress_spec: " .. checks .. " checks")
