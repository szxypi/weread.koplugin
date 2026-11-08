-- Parent-only renewal ownership for read requests. Reuse the durable renewal
-- service; a cancelled/lost POST is never replayed by this adapter.
local M = {}

function M.current(settings, selected, capture)
    if not selected or not selected.native or not settings:auth_scope_matches(selected.native.scope) then return false end
    local current = capture(settings, selected.native.store)
    return current ~= nil and current.base_revision == selected.base_revision
end

function M.cancel(host, context)
    local job = context.renewal_job
    context.renewal_job = nil
    if job and host.native_renewal then host.native_renewal:cancel(job) end
end

function M.start(host, context, selected, options)
    if context.recovery_attempted or not host.native_renewal or not selected or not selected.native then return false end
    context.recovery_attempted, context.renewing = true, true
    local delivered = false
    local function complete(success)
        delivered = true
        context.renewal_job, context.renewing = nil, nil
        if not options.is_current() or not M.current(host.settings, selected, options.capture) then
            options.stale(); return
        end
        local current = options.capture(host.settings, selected.native.store)
        -- begin_renewal and save each advance the grant exactly once. A grant
        -- replaced by another operation must not be mistaken for our renewal.
        local native = current.native
        if not native then options.stale(); return end
        local delta = native.revision - selected.native.revision
        if success and (delta ~= 2 or native.renewal_pending) then
            options.stale(); return
        end
        if not success then
            local previous, credentials = selected.native.credentials, native.credentials
            local owned = (delta == 0 and not native.renewal_pending) or (delta == 1 and native.renewal_pending)
                or (delta == 2 and not native.renewal_pending)
            if not owned or credentials.accessToken ~= previous.accessToken or credentials.refreshToken ~= previous.refreshToken
                or credentials.deviceId ~= previous.deviceId then options.stale(); return end
        end
        options.complete(success, current)
    end
    local started, job = host.native_renewal:start({ expected_revision = selected.native.revision }, complete)
    if started then
        if not delivered then context.renewal_job = job end
    else complete(false) end
    return true
end

return M
