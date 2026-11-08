local Auth = require("weread.lib.native_authorization")
local Credentials = require("weread.lib.native_credentials")
local MemoryWorker = require("weread.lib.memory_worker")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local QRMessage = require("ui/widget/qrmessage")
local UIManager = require("ui/uimanager")
local PluginUtil = require("weread.lib.plugin_util")
local _, T = PluginUtil.tr, PluginUtil.T
local Controller = {}
Controller.__index = Controller
local STATE_FIELDS = { "uid", "last", "confirmed_code", "login_attempted", "pending_credentials", "closed" }
local SOURCE_LABELS = { auto = "Automatic", gateway = "Standard bookshelf", native = "E-Ink bookshelf" }

function Controller:new(host, client, settings, options)
    options = options or {}
    return setmetatable({ host = host, client = client, settings = settings, generation = 0,
        store = options.store or Credentials:new(settings), worker = options.worker,
        scheduler = options.scheduler or UIManager, now = options.now or os.time,
        make_auth = options.make_auth or function(opts) return Auth:new(client, opts) end }, self)
end

function Controller:_close()
    local dialog = self.dialog
    self.dialog = nil
    if dialog then self.scheduler:close(dialog) end
end

function Controller:cancel()
    if self.renewal_job and self.host.native_renewal then self.host.native_renewal:cancel(self.renewal_job) end
    self.renewal_job = nil
    self.generation = self.generation + 1
    if self.scheduled then self.scheduler:unschedule(self.scheduled) self.scheduled = nil end
    if self.worker then self.worker:cancel() end
    if self.auth then self.auth:cancel() end
    self.auth, self.credentials, self.scope, self.started, self.book_count = nil, nil, nil, nil, nil
    self:_close()
end

function Controller:_show(widget, options)
    self:_close()
    local generation = self.generation
    local dialog
    if options.ok_callback then
        local callback = options.ok_callback
        options.ok_callback = function()
            if self.dialog == dialog and self.generation == generation then callback() end
        end
    end
    options.dismiss_callback = function()
        if self.dialog == dialog and self.generation == generation then
            self.dialog = nil
            self:cancel()
        end
    end
    if widget == ConfirmBox then
        options.cancel_callback = options.dismiss_callback
        options.keep_dialog_open = true
    end
    dialog = widget:new(options)
    if widget == ConfirmBox then
        local original = dialog.onCloseWidget
        dialog.onCloseWidget = function(instance)
            if original then original(instance) end
            options.dismiss_callback()
        end
    end
    self.dialog = dialog
    self.scheduler:show(dialog)
end

function Controller:_current(generation)
    return self.generation == generation and self.settings:auth_scope_matches(self.scope)
end

function Controller:_later(callback)
    local generation = self.generation
    self.scheduled = function()
        self.scheduled = nil
        if self.generation ~= generation then return end
        if self:_current(generation) then callback() else self:cancel() end
    end
    self.scheduler:scheduleIn(0.5, self.scheduled)
end

function Controller:_error(message)
    self:cancel()
    self.host:showInfo(message)
end

function Controller:_cancel_reads()
    for _, method in ipairs({ "cancelShelfRefresh", "cancelBookMetadata", "cancelDiscoveryRequest", "cancelProfileRefresh", "cancelReadStatsRequest" }) do
        if self.host[method] then self.host[method](self.host) end
    end
end

function Controller:start()
    self:cancel()
    self:_cancel_reads()
    if self.host.native_renewal then self.host.native_renewal:cancel() end
    self.scope = self.settings:get_auth_scope()
    if not self.settings:auth_scope_matches(self.scope) then
        self:_error(_("Please complete QR code login before authorizing E-Ink access."))
        return
    end
    if not self.host:isNetworkConnected() then
        self:cancel()
        self.host:showOffline(_("E-Ink authorization"))
        return
    end
    local revision, err = select(2, self.store:read())
    if err then self:_error(_("E-Ink authorization storage is unavailable.")) return end
    self.revision, self.started = revision, self.now()
    if self.host.qr_login then self.host.qr_login:cancel() end
    local generation = self.generation
    self.auth = self.make_auth({ expected_vid = self.scope.vid,
        is_current = function() return self:_current(generation) end })
    self:_show(InfoMessage, { text = _("Preparing E-Ink authorization…\nTap or press a key to cancel.") })
    self:_stage("begin")
end

function Controller:_stage(stage)
    if self.now() - self.started > 300 then
        self:_error(_("The QR code has expired. Please try again.")) return
    end
    local generation, auth = self.generation, self.auth
    if not self:_current(generation) then self:cancel() return end
    if not self.worker then self.worker = MemoryWorker:new{ scheduler = self.scheduler, codec = self.client } end
    local started = self.worker:start(function()
        local ok, value, shelf = pcall(auth[stage], auth)
        local state = {}
        for _, key in ipairs(STATE_FIELDS) do state[key] = auth[key] end
        local err
        if not ok then
            err = type(value) == "string" and value:match("^native_auth/[a-z_]+/[a-z_0-9]+$") or "worker_failed"
        end
        return { ok = ok, value = ok and value or nil, book_count = ok and shelf and #shelf.books or nil,
            state = state, error = err }
    end, function(result)
        if self.generation ~= generation then return end
        if not self:_current(generation) then self:cancel() return end
        if type(result) ~= "table" or type(result.state) ~= "table" then
            self:_error(_("E-Ink authorization was interrupted. Please scan a new QR code.")) return
        end
        for _, key in ipairs(STATE_FIELDS) do auth[key] = result.state[key] end
        if result.ok ~= true then self:_failed(stage, result.error) return end
        if stage == "begin" then
            local size = math.floor(math.min(Device.screen:getWidth(), Device.screen:getHeight()) * 0.72)
            self:_show(QRMessage, { text = result.value, width = size, height = size, scale_factor = 0.9 })
            self:_later(function() self:_stage("poll") end)
        elseif stage == "poll" then
            if result.value == "confirmed" then
                self:_show(InfoMessage, { text = _("Verifying E-Ink access…\nTap or press a key to cancel.") })
                self:_stage("finish")
            elseif result.value == "pending" or result.value == "scanned" then
                self:_later(function() self:_stage("poll") end)
            else
                self:_error(_("The QR code has expired or authorization was declined. Please try again."))
            end
        else
            self.credentials, self.book_count = result.value, result.book_count
            self:_save()
        end
    end)
    -- A missing/lost worker receipt must never replay a potentially consumed
    -- login code. A complete child receipt restores the exact protocol state.
    if started and stage == "finish" and not auth.pending_credentials then
        auth.login_attempted, auth.confirmed_code = true, nil
    elseif not started then
        self:_error(_("E-Ink authorization could not start. Please try again."))
    end
end

function Controller:_failed(stage, err)
    if type(err) == "string" and err:find("account_mismatch", 1, true) then
        self:_error(_("The scanned account differs from the current account. Please authorize the same WeRead account."))
    elseif stage == "poll" and type(err) == "string"
        and (err:match("/transport$") or err:match("/timeout$")) then
        self:_later(function() self:_stage("poll") end)
    elseif stage == "finish" and self.auth.pending_credentials then
        self:_close()
        self:_show(ConfirmBox, { text = _("Login succeeded, but the bookshelf could not be verified. Retry verification?"),
            ok_text = _("Retry"), ok_callback = function()
                self:_close()
                self:_show(InfoMessage, { text = _("Verifying E-Ink access…\nTap or press a key to cancel.") })
                self:_stage("finish")
            end })
    else
        self:_error(_("E-Ink authorization failed. Please scan a new QR code."))
    end
end

function Controller:_save()
    if not self:_current(self.generation) then self:cancel() return end
    local ok, err = self.store:save(self.credentials, self.scope, self.revision, self.book_count)
    if ok then
        local count = self.book_count
        self:cancel()
        if self.host.refreshLoginMenu then self.host:refreshLoginMenu() end
        self.host:showInfo(T(_("E-Ink authorization saved. Verified %1 books.\nAuthorize again if access expires."), count))
    elseif err == "account_changed" or err == "replaced" then
        self:_error(_("Account or authorization changed. Please reopen E-Ink authorization."))
    else
        -- Verified credentials remain only in memory while the retry dialog is
        -- open. A local save retry sends no login or shelf request.
        self:_show(ConfirmBox, { text = _("Could not save E-Ink authorization. Retry saving?"), ok_text = _("Retry"),
            ok_callback = function() self:_save() end })
    end
end

function Controller:clear()
    self:cancel()
    self:_cancel_reads()
    if self.host.native_renewal then self.host.native_renewal:cancel() end
    local scope = self.settings:get_auth_scope()
    local revision = select(2, self.store:read())
    local ok = revision and self.store:clear(scope, revision)
    if self.host.refreshLoginMenu then self.host:refreshLoginMenu() end
    self.host:showInfo(ok and _("E-Ink authorization cleared.") or _("Could not clear E-Ink authorization. Please try again."))
end

function Controller:clearForLogout()
    self:cancel()
    self:_cancel_reads()
    if self.host.native_renewal then self.host.native_renewal:cancel() end
    -- Account reset immediately invalidates any old grant even if storage is
    -- unavailable; removing the bounded primary/backup also drops local tokens.
    os.remove(self.store.path)
    os.remove(self.store.path .. ".old")
end

function Controller:showMenu()
    self:cancel()
    self:_cancel_reads()
    local value = self.store:read()
    local source = require("weread.lib.shelf_source").mode(self.settings)
    local dialog
    dialog = ButtonDialog:new{
        modal = true,
        title = value and _("E-Ink authorization is saved for the current account.") or _("E-Ink access is not authorized."),
        buttons = {
            {{ text = value and _("Authorize E-Ink again") or _("Authorize E-Ink access"), callback = function()
                self.scheduler:close(dialog) self:start()
            end }},
            {{ text = self.host.native_renewal and self.host.native_renewal.job
                and self.host.native_renewal.job.state == "save_failed" and _("Retry saving renewed authorization")
                or _("Renew E-Ink authorization"), enabled = value ~= nil and self.host.native_renewal ~= nil, callback = function()
                self.scheduler:close(dialog) self:renew()
            end }},
            {{ text = _("Clear E-Ink authorization"), enabled = value ~= nil, callback = function()
                self.scheduler:close(dialog) self:clear()
            end }},
            {{ text = T(_("Bookshelf source: %1"), _(SOURCE_LABELS[source])), callback = function()
                self.scheduler:close(dialog) self:chooseSource()
            end }},
            {{ text = _("Cancel"), callback = function() self.scheduler:close(dialog) end }},
        },
    }
    self.scheduler:show(dialog)
end

function Controller:_renewal_saved()
    self.renewal_job = nil
    self:_close()
    if self.host.refreshLoginMenu then self.host:refreshLoginMenu() end
    self.host:showInfo(_("E-Ink authorization renewed and saved."))
end

function Controller:_retry_renewal_save()
    local ok, err = self.host.native_renewal:retry_save()
    if ok then self:_renewal_saved()
    elseif err == "session_changed" then
        self:cancel()
        self.host:showInfo(_("Account or authorization changed. Please reopen E-Ink authorization."))
    else
        self:_show(ConfirmBox, { text = _("Could not save renewed authorization. Retry saving without another renewal request?"),
            ok_text = _("Retry"), ok_callback = function() self:_retry_renewal_save() end })
    end
end

function Controller:renew()
    self:cancel()
    self:_cancel_reads()
    local service = self.host.native_renewal
    if not service then return end
    if service.job and service.job.state == "save_failed" then
        self.renewal_job = service.job
        self:_retry_renewal_save()
        return
    end
    if not self.host:isNetworkConnected() then self.host:showOffline(_("E-Ink authorization")) return end
    local generation = self.generation
    self:_show(InfoMessage, { text = _("Renewing E-Ink authorization…\nTap or press a key to cancel.") })
    local started, job = service:start({}, function(ok, err)
        if generation ~= self.generation then return end
        if ok then self:_renewal_saved()
        elseif err == "save_failed" then self:_retry_renewal_save()
        else
            self.renewal_job = nil
            self:_close()
            self.host:showInfo(_("E-Ink renewal could not be confirmed. Please authorize again."))
        end
    end)
    if started then self.renewal_job = job
    else
        self:_close()
        self.host:showInfo(job == "renewal_unconfirmed" and _("A previous renewal is unconfirmed. Please authorize again.")
            or _("E-Ink renewal could not start. Check authorization and storage, then try again."))
    end
end

function Controller:chooseSource()
    local dialog
    local buttons = {}
    for _i, source in ipairs({ "auto", "gateway", "native" }) do
        buttons[#buttons + 1] = {{ text = _(SOURCE_LABELS[source]), callback = function()
            self.scheduler:close(dialog)
            if self.host.cancelShelfRefresh then self.host:cancelShelfRefresh() end
            if not self.settings:set_shelf_source(source) then
                self.host:showInfo(_("Could not save bookshelf source. Please try again."))
                return
            end
            self:showMenu()
        end }}
    end
    buttons[#buttons + 1] = {{ text = _("Cancel"), callback = function() self.scheduler:close(dialog) end }}
    dialog = ButtonDialog:new{ modal = true, title = _("Automatic prefers E-Ink authorization. Standard bookshelf uses an official key when available, then the Web login. E-Ink bookshelf uses only E-Ink access."),
        buttons = buttons }
    self.scheduler:show(dialog)
end

return Controller
