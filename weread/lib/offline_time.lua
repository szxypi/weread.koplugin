-- Offline-only collection from native KOReader statistics. The transport is
-- deliberately separate: collecting never sends requests or changes progress.
local Stats = require("weread.lib.offline_time_stats")
local Store = require("weread.lib.offline_time_store")
local FileIdentity = require("weread.lib.book_file_identity")
local loaded_time, Time = pcall(require, "ui/time")
local Collector = {}
Collector.__index = Collector

local function sample_clock()
    local wall = os.time()
    local zone = os.date("%z", wall)
    local monotonic
    if loaded_time and Time.monotonic and Time.to_s then monotonic = Time.to_s(Time.monotonic()) end
    if zone and zone:match("^[+-]%d%d%d%d$") then zone = zone:sub(1, 3) .. ":" .. zone:sub(4, 5) else zone = nil end
    return { wall = wall, monotonic = monotonic, zone = zone }
end

local function finite(n)
    return type(n) == "number" and n == n and math.abs(n) < math.huge
end

function Collector:new(options)
    return setmetatable({
        settings = assert(options.settings), library_db = assert(options.library_db),
        scheduler = assert(options.scheduler), get_context = assert(options.get_context),
        is_online = assert(options.is_online), clock = options.clock or sample_clock,
        source = options.source or Stats, store = options.store or Store:new(options.settings.data_dir),
        recovered = {}, state = "disabled",
    }, self)
end

function Collector:enabled()
    return self.settings:get("offline_time", {}).enabled == true
end

function Collector:_clock()
    local ok, sample = pcall(self.clock)
    if not ok or type(sample) ~= "table" or not finite(sample.wall) or sample.wall % 1 ~= 0
        or not finite(sample.monotonic) or not sample.zone then return nil end
    return sample
end

function Collector:_snapshot(active, endpoint)
    local rows = {}
    if active.stats.id_curr_book == active.stats_book then rows = self.source.snapshot(active.stats, endpoint, active.sources) end
    local settled = self.source.persisted(active.stats, active.last_seen, endpoint, active.stats_book)
    for _, row in ipairs(settled) do rows[#rows + 1] = row end
    return rows
end

function Collector:_collect(endpoint, close)
    local active = self.active
    if not active then return true end
    local rows = {}
    if endpoint > active.last_seen then
        local ok, snapshot = pcall(self._snapshot, self, active, endpoint)
        if not ok then self.error = "statistics_unavailable" return false end
        rows = snapshot
    end
    local result, err = self.store:collect(active.account, active.id, rows, endpoint, close)
    if not result then self.error = err return false end
    active.last_seen = endpoint
    self.error = nil
    if close then self.active = nil end
    return true
end

function Collector:_seal(endpoint)
    if not self.active then return true end
    self.active.closing_at = self.active.closing_at or endpoint
    return self:_collect(self.active.closing_at, true)
end

function Collector:_cancel_timer()
    if self.task then self.scheduler:unschedule(self.task) self.task = nil end
end

function Collector:_schedule()
    if self.task or self.suspended or self.paused or not self:enabled() then return end
    local context = self.get_context()
    if not context or not context.book_id or not self.library_db:accountKey() then return end
    local task
    task = function()
        if self.task ~= task then return end
        self.task = nil
        self:update("timer")
    end
    self.task = task
    self.scheduler:scheduleIn(self.active and 15 or 30, task)
end

function Collector:update(reason, online_hint)
    self:_cancel_timer()
    if not self:enabled() and not self.active then self.state, self.error = "disabled", nil return true end
    local sample = self:_clock()
    local context = self.get_context()
    local account = self.library_db:accountKey()
    local ok, online = pcall(self.is_online)
    if not ok or type(online) ~= "boolean" then online = nil end
    if type(online_hint) == "boolean" then online = online_hint end
    local enabled = self:enabled() and not self.suspended and not self.paused
    local eligible = enabled and context and type(context.book_id) == "string" and context.book_id ~= ""
        and context.book_id:sub(1, 7) ~= "MP_WXS_" and context.path and context.visible ~= false and account
        and self.source.available(context.stats)
    local active = self.active
    if active and active.closing_at then
        if not self:_seal(active.closing_at) then self.state = "error" self:_schedule() return false end
        active = nil
    end
    if active then
        local same = eligible and account == active.account and context.book_id == active.book_id
            and context.path == active.path and context.document == active.document
            and context.stats == active.stats and context.stats.id_curr_book == active.stats_book
        local clock_changed = not sample or sample.wall < active.clock.wall
            or sample.monotonic < active.clock.monotonic or sample.zone ~= active.clock.zone
            or math.abs((sample.wall - active.clock.wall) - (sample.monotonic - active.clock.monotonic)) >= 5
        if not same or online ~= false or clock_changed or active.stats._reading_paused_ts then
            local endpoint = active.last_seen
            if same and sample and not clock_changed and (online == false or reason == "network_connected") then
                endpoint = math.max(endpoint, math.min(sample.wall, active.stats._reading_paused_ts or sample.wall))
            end
            if not self:_seal(endpoint) then self.state = "error" self:_schedule() return false end
            if clock_changed then
                self.state, self.error = "error", "clock_changed"
                self:_schedule()
                return false
            end
        else
            if not self:_collect(sample.wall, false) then self.state = "error" self:_schedule() return false end
            active.clock = sample
        end
    end
    if not self.active and eligible and sample and online == false and not context.stats._reading_paused_ts then
        if not self.recovered[account] then
            local recovered, err = self.store:recover(account)
            if not recovered then self.state, self.error = "error", err self:_schedule() return false end
            self.recovered[account] = true
        end
        local identity = FileIdentity.read_document(context.document, context.book_id)
        if identity.version_source == "book_mismatch" then
            self.state, self.error = "book_mismatch", nil
            self:_schedule()
            return false
        end
        local id, err = self.store:begin(account, { book_id = context.book_id, stats_book = context.stats.id_curr_book,
            start_time = sample.wall, time_zone = sample.zone, book_version = identity.book_version,
            file_id = identity.file_id, version_source = identity.version_source })
        if id == false then err = "clock_changed" end
        if not id then self.state, self.error = "error", err self:_schedule() return false end
        self.active = { account = account, book_id = context.book_id, path = context.path, id = id,
            stats = context.stats, stats_book = context.stats.id_curr_book, last_seen = sample.wall,
            document = context.document,
            clock = sample, sources = setmetatable({}, { __mode = "k" }) }
        self.error = nil
    end
    if self.active then self.state = "recording"
    elseif not self:enabled() then self.state = "disabled"
    elseif self.suspended or self.paused or (context and context.stats and context.stats._reading_paused_ts) then self.state = "paused"
    elseif not account then self.state = "account_unavailable"
    elseif not context or not context.book_id then self.state = "no_book"
    elseif context.visible == false then self.state = "reader_hidden"
    elseif context.book_id:sub(1, 7) == "MP_WXS_" then self.state = "unsupported_book"
    elseif not self.source.available(context.stats) then self.state = "statistics_unavailable"
    elseif not sample then self.state = "clock_unavailable"
    else self.state = online == true and "online" or "network_unavailable" end
    self.error = nil
    self:_schedule()
    return true
end

function Collector:start()
    self.suspended, self.paused = false, false
    return self:update("start")
end

-- Native statistics may handle ReaderReady/ReadingResumed after this plugin.
-- Defer once until every event listener has restored its counters and pause flag.
function Collector:resume()
    self:_cancel_timer()
    self.suspended, self.paused = false, false
    if not self:enabled() then return self:update("resume") end
    local task
    task = function()
        if self.task ~= task then return end
        self.task = nil
        self:update("resume")
    end
    self.task = task
    self.scheduler:scheduleIn(0.1, task)
end

function Collector:stop(reason)
    self:_cancel_timer()
    if not self.active then return true end
    local sample = self:_clock()
    local active, context = self.active, self.get_context()
    local ok, online = pcall(self.is_online)
    local endpoint = active.last_seen
    if sample and ok and online == false and self.library_db:accountKey() == active.account
        and context and context.path == active.path and context.document == active.document
        and context.book_id == active.book_id and sample.wall >= active.clock.wall
        and sample.monotonic >= active.clock.monotonic and sample.zone == active.clock.zone
        and math.abs((sample.wall - active.clock.wall) - (sample.monotonic - active.clock.monotonic)) < 5 then
        endpoint = math.max(endpoint, math.min(sample.wall, active.stats._reading_paused_ts or sample.wall))
    end
    local saved = self:_seal(endpoint)
    self.state = saved and (reason or "paused") or "error"
    return saved
end

function Collector:pause(reason)
    local saved = self:stop(reason or "paused")
    self.paused = true
    return saved
end

function Collector:suspend()
    local saved = self:stop("paused")
    self.suspended = true
    return saved
end

function Collector:status()
    local account = self.library_db:accountKey()
    local summary, err
    if account then summary, err = self.store:summary(account) end
    summary = summary or { pending = 0, unknown = 0, in_flight = 0, confirmed = 0 }
    summary.state, summary.error = self.state, self.error or err
    return summary
end

return Collector
