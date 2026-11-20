-- Explicitly armed, four-POST maximum. Only the host's persisted intent can
-- select this addon. It never manufactures acknowledgements or retries POSTs.
return function(input, counters)
    local config = assert(input.progress_roundtrip)
    assert(type(config.permit_writes) == "boolean" and type(config.intent_digest) == "string"
        and (config.permit_writes and #config.intent_digest == 64 and config.intent_digest:match("^[0-9a-f]+$")
            or not config.permit_writes and config.intent_digest == ""))
    local shim = {}; for key, value in pairs(input) do shim[key] = value end
    shim.progress_preview = config
    local base = dofile(debug.getinfo(1, "S").source:match("^@(.*/)") .. "owner_progress_preview_case.lua")(shim,counters)
    local Remote = require("weread.lib.remote_progress")
    local Source = require("weread.lib.position_source")
    local baseline, target = config.baseline, config.target
    local case = { records = base.records, report = {
        result = "UNVERIFIED", source_points_verified = false, actual_upload_service = false,
        same_position_confirmed = false, probe_confirmed = false, probe_seen = false, restore_acknowledged = false,
        restoration_verified = false, reader_position_restored = false, source_upload_gate_preserved = false,
        safe_resolution = false, unrelated_position_seen = false, guard_denied = 0, posts_attempted = 0, guard_reads = 0,
        disarmed = not config.permit_writes, permission_blocked = false,
        synthetic_acknowledgements = 0, failed_line = 0, failure = "none",
    } }
    local function same_coordinate(first, second)
        return type(first) == "table" and tostring(first.book_id) == tostring(second.book_id)
            and tostring(first.chapter_uid) == tostring(second.chapter_uid) and first.chapter_idx == second.chapter_idx
            and first.chapter_offset == second.chapter_offset and first.has_chapter_offset == true
            and first.has_chapter_index == true
    end
    local function same_position(first, second)
        return same_coordinate(first,second) and first.raw_percent == second.raw_percent
    end
    function case:is_write(options) return base:is_write(options) end
    function case:install_guard() self.guard_installed = true end
    function case:current()
        if not self.plugin or not self.reader or self.plugin.ui ~= self.reader
            or require("apps/reader/readerui").instance ~= self.reader
            or self.plugin:detectWeReadBook() ~= input.book_id
            or self.plugin.settings:get("cookies",{}).wr_vid ~= input.vid then return false end
        local snapshot = Source.document_metadata(self.reader.document,input.book_id,input.chapter_uid)
        return snapshot and self.snapshot and snapshot.metadata == self.snapshot.metadata
            and snapshot.record.raw_sha256 == input.source_raw_sha256 and snapshot.record.format == "web_xhtml"
    end
    function case:observe(client)
        assert(self:current(),"experiment_session_changed")
        counters[36] = counters[36] + 1
        assert(counters[36] <= 24,"experiment_read_limit")
        local raw = client:get_web_progress(input.book_id,{ sensitive = true })
        local value, reason, supplied = Remote.project(raw,input.book_id,"web")
        assert(value and not reason and supplied.chapter_uid and supplied.chapter_idx and supplied.chapter_offset,
            "experiment_progress_unavailable")
        assert(self:current(),"experiment_session_changed")
        value.has_chapter_index = true
        return value
    end
    function case:request(client, options, dispatch)
        assert(type(dispatch) == "function")
        if not self.guard_installed or not self.active or not self:current() or counters[31] >= 4 then
            counters[30] = counters[30] + 1; error("experiment_write_scope",0)
        end
        base.active = true
        local record = base:validate_request(client,options)
        local current = self:observe(client)
        local allowed = record.stage == "write_restore" and same_coordinate(current,target)
            or record.stage ~= "write_restore" and same_position(current,baseline)
        if not allowed then
            self.report.unrelated_position_seen = not same_coordinate(current,baseline) and not same_coordinate(current,target)
            self.report.failure = "position_changed"
            counters[30] = counters[30] + 1; error("experiment_position_changed",0)
        end
        -- A slow GET cannot leave a stale signed request authorized to send.
        record = base:validate_request(client,options)
        if not config.permit_writes then
            self.report.permission_blocked = true; error("experiment_disarmed",0)
        end
        self.records[#self.records + 1] = record
        counters[31] = counters[31] + 1 -- uncertain sends consume their slot
        local raw, code, headers, status = dispatch(client,options)
        counters[31 + tonumber(counters[31])] = tonumber(code) or 0
        return raw, code, headers, status
    end
    function case:run(plugin, reader, pump, source_index, origin)
        self.plugin, self.reader = plugin, reader
        local navigate, snapshot = base:source_navigator(plugin,reader,pump,source_index)
        self.snapshot = snapshot
        local function upload(p)
            assert(self:current(),"experiment_session_changed")
            self.active = true
            local accepted, outcome = plugin.read_report:upload_position(input.book_id, {
                book_id = input.book_id, chapter_uid = p.chapter_uid, chapter_idx = p.chapter_idx,
                chapter_offset = p.chapter_offset, percent = p.raw_percent, summary = p.summary,
            },0)
            self.active = false
            for _i = 1,2 do
                if accepted or outcome.error_kind ~= "confirmation_pending" or not outcome.confirmation then break end
                local done
                require("ui/uimanager"):scheduleIn(1,function()
                    if self:current() then accepted,outcome = plugin.read_report:confirm_position(outcome.confirmation) end
                    done = true
                end)
                pump(function() return done end)
            end
            return accepted and outcome.acknowledged == true and outcome.position_confirmed == true
        end
        local ok, reason = pcall(function()
            -- Validate both native text targets before the first cloud write.
            navigate(baseline); navigate(target); navigate(baseline)
            self.report.source_points_verified = true
            assert(same_position(self:observe(plugin.client),baseline),"experiment_baseline_changed")
            self.report.actual_upload_service = true
            self.report.same_position_confirmed = upload(baseline)
            assert(self.report.same_position_confirmed,"experiment_same_unconfirmed")
            navigate(target)
            self.report.probe_confirmed = upload(target)
            self.report.probe_seen = self.report.probe_confirmed
            assert(self.report.probe_confirmed,"experiment_probe_unconfirmed")
        end)
        self.active = false
        if not ok then
            self.report.failure = self.report.failure ~= "none" and self.report.failure
                or tostring(reason):find("experiment_same_unconfirmed",1,true) and "same_unconfirmed"
                or tostring(reason):find("experiment_probe_unconfirmed",1,true) and "probe_unconfirmed" or "preparation_failed"
        end
        -- Only our exact probe coordinate can be conditionally restored. An
        -- unrelated reader's position is never overwritten. No fifth POST.
        local restored, restore_reason = pcall(function()
            local observed = self:observe(plugin.client)
            if tonumber(counters[31]) >= 3 and same_coordinate(observed,target) then
                self.report.probe_seen = true
                assert(tonumber(counters[31]) == 3,"experiment_restore_slot_consumed")
                navigate(baseline)
                self.report.restore_acknowledged = upload(baseline)
                observed = self:observe(plugin.client)
            elseif not same_coordinate(observed,baseline) then
                self.report.unrelated_position_seen = true
            end
            self.report.restoration_verified = same_position(observed,baseline)
        end)
        self.active = false
        if not restored and self.report.failure == "none" then self.report.failure = "restore_unconfirmed" end
        if not self.report.restoration_verified and self.report.failure == "none" then self.report.failure = "restore_unconfirmed" end
        if tonumber(counters[31]) == 4 and not self.report.restore_acknowledged and self.report.failure == "none" then
            self.report.failure = "restore_unconfirmed"
        end
        if not restored then reason = restore_reason end
        local local_ok = pcall(navigate,origin)
        self.report.reader_position_restored = local_ok
        self.report.source_upload_gate_preserved = origin.upload_verified == false
        local received = true
        for index = 1,tonumber(counters[31]) do if counters[31 + index] ~= 200 then received = false end end
        self.report.safe_resolution = self.report.restoration_verified and received
            and (tonumber(counters[31]) < 3 or tonumber(counters[31]) == 4 and self.report.probe_seen)
        if ok and restored and local_ok and self.report.restore_acknowledged and self.report.restoration_verified
            and tonumber(counters[31]) == 4 and counters[30] == 0 then self.report.result = "PASS" end
        self.report.failed_line = tonumber(type(reason) == "string" and reason:match("owner_progress_roundtrip_case%.lua:(%d+):")) or 0
    end
    function case:finish(reason)
        self.report.posts_attempted, self.report.guard_denied, self.report.guard_reads = tonumber(counters[31]),tonumber(counters[30]),tonumber(counters[36])
        self.report.post_statuses = require("json").decode("[]")
        for index = 1,tonumber(counters[31]) do self.report.post_statuses[index] = tonumber(counters[31 + index]) end
        if self.report.failed_line == 0 then
            self.report.failed_line = tonumber(type(reason) == "string" and reason:match("owner_progress_roundtrip_case%.lua:(%d+):")) or 0
        end
    end
    function case:private() return { records = self.records, guard_installed = self.guard_installed == true, intent_digest = config.intent_digest } end
    return case
end
