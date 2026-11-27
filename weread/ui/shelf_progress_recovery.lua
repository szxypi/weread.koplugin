-- The visible and full-shelf readers share the same single renewal per job.
local Data = require("weread.lib.shelf_progress")
local Access = require("weread.lib.read_access")
local NativeAccess = require("weread.lib.native_read_access")
local NativeRecovery = require("weread.lib.native_read_recovery")
local M = {}

local function revision(standard)
    return standard and standard.revision or ""
end

local function capture_native(settings, store)
    return {
        base_revision = revision(Access.capture(settings)),
        native = NativeAccess.capture(settings, store),
    }
end

function M.channel(context, result)
    if context.recovery_attempted then return end
    if result.native_expired then return "native" end
    if result.web_expired then return "web" end
end

function M.cancel(host, context)
    context.renewing = nil
    NativeRecovery.cancel(host, context)
    local request = context.web_request
    context.web_request = nil
    if request then require("weread.ui.web_renewal").cancel(host, request) end
end

function M.start(host, context, access, channel, options)
    if channel == "native" then
        if not access.native then return false end
        return NativeRecovery.start(host, context, {
            base_revision = revision(access.standard),
            native = access.native.grant,
        }, {
            capture = capture_native,
            is_current = options.is_current,
            stale = options.stale,
            complete = function(success, verified)
                local fresh = success and Data.selection(host.settings)
                if success and (not fresh or not fresh.native
                    or fresh.native.grant.fingerprint ~= verified.native.fingerprint) then
                    options.stale()
                    return
                end
                options.complete(success, fresh, false)
            end,
        })
    end
    local Web = require("weread.ui.web_renewal")
    context.recovery_attempted, context.renewing = true, true
    local delivered = false
    local function complete(success, reason)
        if delivered or not context.renewing then return end
        delivered = true
        context.web_request, context.renewing = nil, nil
        if not options.is_current() or reason == "session_changed" then options.stale(); return end
        local fresh = success and Data.selection(host.settings)
        if success and (not fresh or not fresh.web) then options.stale(); return end
        options.complete(success, fresh, true, not success and reason and Web.error_text(reason) or nil)
    end
    local called, started, request = pcall(Web.run, host, { is_current = options.is_current }, complete)
    if not delivered then
        if called and started and context.renewing and options.is_current() then
            context.web_request = request
        elseif called and started then
            Web.cancel(host, request)
        else
            complete(false)
        end
    end
    return true
end

return M
