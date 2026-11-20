-- Parent-only credential commits; authentication runs through memory pipes.
-- A durable pending marker precedes the POST and blocks replay after a lost
-- receipt, cancellation or restart. Only a proved pre-dispatch error releases it.
local Auth = require("weread.lib.native_authorization")
local Credentials = require("weread.lib.native_credentials")
local Worker = require("weread.lib.memory_worker")
local Renewal = {}
Renewal.__index = Renewal

function Renewal:new(options)
    return setmetatable({ settings = assert(options.settings), client = assert(options.client),
        scheduler = assert(options.scheduler), store = options.store or Credentials:new(options.settings),
        worker = options.worker, make_auth = options.make_auth or function(client, opts) return Auth:new(client, opts) end }, self)
end

function Renewal:_current(job)
    if self.job ~= job or not self.settings:auth_scope_matches(job.scope) then return false end
    local credentials, revision, err, pending = self.store:read()
    return not err and credentials ~= nil and revision == job.revision and pending == true
end

function Renewal:cancel(expected)
    local job = self.job
    if not job or (expected and job ~= expected) then return end
    self.job = nil
    if self.worker then self.worker:cancel() end
    if job.auth then job.auth:cancel() end
    job.previous, job.credentials, job.callback = nil, nil, nil
end

function Renewal:_finish(job, ok, reason, retain)
    if self.job ~= job then return end
    local callback = job.callback
    job.callback = nil
    if not retain then self:cancel(job) end
    if callback then callback(ok, reason) end
end

function Renewal:retry_save()
    local job = self.job
    if not job or job.state ~= "save_failed" or not self.settings:auth_scope_matches(job.scope) then
        if job then self:cancel(job) end
        return false, "session_changed"
    end
    local ok, reason
    if self:_current(job) then
        ok, reason = self.store:save(job.credentials, job.scope, job.revision, job.book_count)
    elseif type(self.store.confirm_saved) == "function" then
        ok, reason = self.store:confirm_saved(job.credentials, job.scope, job.revision + 1, job.book_count)
        if not ok and reason ~= "save_failed" then
            self:cancel(job)
            return false, "session_changed"
        end
    else
        self:cancel(job)
        return false, "session_changed"
    end
    if ok then self:cancel(job) end
    return ok, reason
end

function Renewal:_save(job)
    if not self:_current(job) then self:_finish(job, false, "session_changed") return end
    local ok = self.store:save(job.credentials, job.scope, job.revision, job.book_count)
    if ok then
        self:_finish(job, true)
    else
        job.state = "save_failed"
        self:_finish(job, false, "save_failed", true)
    end
end

function Renewal:_stage(job, stage)
    if not self:_current(job) then self:_finish(job, false, "session_changed") return end
    if not self.worker then self.worker = Worker:new{ scheduler = self.scheduler, codec = self.client } end
    local started = self.worker:start(function()
        local ok, credentials, shelf
        if stage == "renew" then ok, credentials, shelf = pcall(job.auth.renew, job.auth, job.previous)
        else ok, credentials, shelf = pcall(job.auth.verify, job.auth) end
        return { ok = ok, credentials = ok and credentials or nil, book_count = ok and shelf and #shelf.books or nil,
            attempted = job.auth.renewal_attempted == true, pending = job.auth.pending_credentials,
            error = not ok and type(credentials) == "string" and credentials:match("^native_auth/[a-z_]+/[a-z_0-9]+$") or nil }
    end, function(result)
        if self.job ~= job then return end
        if not self:_current(job) then self:_finish(job, false, "session_changed") return end
        if type(result) ~= "table" or type(result.attempted) ~= "boolean" then
            self:_finish(job, false, "renewal_unconfirmed") return
        end
        job.auth.renewal_attempted, job.auth.pending_credentials = result.attempted, result.pending
        if result.ok then
            job.previous, job.credentials, job.book_count = nil, result.credentials, result.book_count
            self:_save(job)
        elseif result.pending and stage == "renew" and result.error ~= "native_auth/shelf/http_429" then
            job.previous = nil
            self:_stage(job, "verify")
        else
            if not result.attempted then self.store:release_renewal(job.scope, job.revision) end
            self:_finish(job, false, result.attempted and "renewal_unconfirmed" or "not_dispatched")
        end
    end)
    if not started then
        -- runInSubProcess did not create a worker; no protocol code ran.
        if stage == "renew" and not job.auth.renewal_attempted then
            self.store:release_renewal(job.scope, job.revision)
            self:_finish(job, false, "not_dispatched")
        else self:_finish(job, false, "renewal_unconfirmed") end
    end
end

function Renewal:start(options, callback)
    options = options or {}
    if self.job then return false, self.job.state == "save_failed" and "save_failed" or "busy" end
    local scope = self.settings:get_auth_scope()
    if not self.settings:auth_scope_matches(scope) then return false, "session_changed" end
    local credentials, revision, err = self.store:read()
    if err or not credentials then return false, "unavailable" end
    if options.expected_revision and options.expected_revision ~= revision then return false, "replaced" end
    local ok, next_revision = self.store:begin_renewal(scope, revision)
    if not ok then return false, next_revision end
    local job = { scope = scope, revision = next_revision, previous = credentials, callback = callback }
    self.job = job
    job.auth = self.make_auth(self.client, { expected_vid = scope.vid, is_current = function() return self:_current(job) end })
    self:_stage(job, "renew")
    return true, job
end

return Renewal
