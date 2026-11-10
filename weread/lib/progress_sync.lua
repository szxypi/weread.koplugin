local PositionMapper = require("weread.lib.position_mapper")
local Crypto = require("weread.lib.crypto")
local ReaderPosition = require("weread.lib.reader_position")
local Source = require("weread.lib.position_source")
local SourceDom = require("weread.lib.source_dom")
local FileIdentity = require("weread.lib.book_file_identity")
local ProgressReadback = require("weread.lib.progress_readback")

local logger = require("weread.lib.logger").scoped("ProgressSync")

local ProgressSync = {}
ProgressSync.__index = ProgressSync

local OPEN_DELAY_SECONDS = 0.6
local RESUME_RECHECK_SECONDS = 5 * 60
local PULL_RETRY_DELAY_SECONDS = 15
local PULL_MAX_RETRIES = 3
local BUSY_RETRY_SECONDS = 2
local BUSY_RETRY_LIMIT = 10
local SAME_THRESHOLD_PERCENT = 2
local SOURCE_CONFLICT_THRESHOLD_PERCENT = 2

local function log(level, ...)
    if type(logger[level]) == "function" then
        logger[level](...)
    end
end

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end

local function is_mp_book(book_id)
    return tostring(book_id or ""):sub(1, 7) == "MP_WXS_"
end

local function document_path(document)
    if not document then return nil end
    return document.file
        or (type(document.getFilePath) == "function" and document:getFilePath())
end

function ProgressSync:new(options)
    options = options or {}
    assert(options.settings, "progress sync settings are required")
    assert(options.client, "progress sync client is required")
    assert(options.scheduler, "progress sync scheduler is required")
    assert(type(options.get_document) == "function", "get_document callback is required")
    assert(type(options.detect_book) == "function", "detect_book callback is required")
    assert(type(options.get_book) == "function", "get_book callback is required")
    assert(type(options.get_chapters) == "function", "get_chapters callback is required")
    assert(type(options.get_file_context) == "function", "get_file_context callback is required")
    assert(type(options.run_online) == "function", "run_online callback is required")
    assert(type(options.upload_position) == "function", "upload_position callback is required")
    assert(type(options.goto_fraction) == "function", "goto_fraction callback is required")
    assert(type(options.open_chapter) == "function", "open_chapter callback is required")

    local object = {
        settings = options.settings,
        client = options.client,
        scheduler = options.scheduler,
        get_document = options.get_document,
        get_footer = options.get_footer,
        get_source_position = options.get_source_position,
        get_view_mode = options.get_view_mode,
        get_viewport_height = options.get_viewport_height,
        get_navigation_xpointer = options.get_navigation_xpointer,
        on_before_navigate = options.on_before_navigate,
        detect_book = options.detect_book,
        get_book = options.get_book,
        get_chapters = options.get_chapters,
        refresh_catalog = options.refresh_catalog,
        get_file_context = options.get_file_context,
        run_online = options.run_online,
        upload_position = options.upload_position,
        confirm_position = options.confirm_position,
        goto_fraction = options.goto_fraction,
        open_chapter = options.open_chapter,
        is_online = options.is_online or function() return true end,
        on_choice = options.on_choice or function(context)
            context.keep_local()
        end,
        notify = options.notify or function() end,
        now = options.now or os.time,
        state = "idle",
        generation = 0,
        navigation_generation = 0,
        pull_retry_token = 0,
        account_generation = 0,
        dirty = false,
        verified = false,
    }
    return setmetatable(object, self)
end

function ProgressSync:_config()
    return self.settings:get("sync", {})
end

function ProgressSync:_account_key()
    local account = self.settings:get("account", {})
    local vid = type(account) == "table" and account.user_vid
    if vid == nil or tostring(vid) == "" then return nil end
    return string.sub(Crypto.sha256_hex("weread-library:" .. tostring(vid)), 1, 20)
end

function ProgressSync:_scope()
    return {
        generation = self.generation, account_generation = self.account_generation,
        account = self:_account_key(), book_id = tostring(self.detect_book() or ""),
        path = document_path(self.get_document()),
        navigation_generation = self.navigation_generation,
    }
end

function ProgressSync:_account_current(scope)
    return scope.account_generation == self.account_generation and scope.account == self:_account_key()
end

function ProgressSync:_session_current(scope)
    return self:_account_current(scope) and scope.generation == self.generation
        and scope.book_id == tostring(self.detect_book() or "")
        and scope.path == document_path(self.get_document())
end

function ProgressSync:_invalidate_pull()
    self.pull_retry_token = self.pull_retry_token + 1
    self.pull_job, self.pulling = nil, false
end

-- A local source request supersedes older cloud comparisons and decisions,
-- without changing the reading session or granting upload verification.
function ProgressSync:begin_local_navigation()
    self.navigation_generation = self.navigation_generation + 1
    self:_invalidate_pull()
    self.pending_jump = nil
    if self.state == "pulling" or self.state == "awaiting_choice" or self.state == "switching_chapter" then
        self.state = self.verified and "verified" or "unverified"
    end
end

-- A different EPUB can have the same original chapter with a new spine/path.
-- Preserve the previous local intent until that source-bound jump succeeds.
function ProgressSync:begin_file_resume()
    self:_begin_source_transition('file_resume')
    local id=tostring(self.detect_book() or '')
    local baseline=self:capture_local()
    if not baseline then return nil end
    local saved=self.get_book(id) or {}
    local owner=saved.pending_upload_account or saved.recent_read_account
    local frame={scope=self:_scope(),baseline=copy(baseline),marker=self:_navigation_marker(),
        had_pending=type(saved.pending_upload_position)=='table' and owner==self:_account_key()}
    self.current_book_id,self.checkpoint_account=id,self:_account_key()
    self.local_position,self.dirty=copy(baseline),false
    self.file_resume=frame
    return frame
end

function ProgressSync:_file_resume_unchanged(frame)
    if not self:_session_current(frame.scope) then return false end
    local position=self:capture_local()
    return not position or (PositionMapper.same_position(position,frame.baseline)
        and self:_navigation_marker()==frame.marker)
end

function ProgressSync:finish_file_resume(frame, applied)
    if self.file_resume~=frame or not self:_session_current(frame.scope) then return false end
    if not applied then
        frame.failed=true
        if not self:_file_resume_unchanged(frame) then self.file_resume=nil end
        self.state='unverified'
        return true
    end
    self.file_resume=nil
    self.local_position=self:capture_local() or frame.baseline
    self.dirty=frame.had_pending
    self:checkpoint_local('file_resume')
    self.state='unverified'
    if self:_config().pull_on_open==true then
        local scope,nav=self:_scope(),self.navigation_generation
        self.scheduler:scheduleIn(0.1,function()
            if not self.file_resume and self:_session_current(scope) and self.navigation_generation==nav then
                self:_pull({manual=false})
            end
        end)
    end
    return true
end

-- A read-only cloud choice must not be undone by an older queued local write.
-- Keep its durable intent until navigation succeeds, but close the report gate
-- and cancel this book's unsent task before starting the read/locate pipeline.
function ProgressSync:begin_cloud_source_navigation()
    self:_begin_source_transition('cloud_source_navigation')
end

function ProgressSync:begin_file_resume_departure()
    self:_begin_source_transition('file_resume_open')
end

function ProgressSync:_begin_source_transition(reason)
    self:begin_local_navigation()
    local id=tostring(self.detect_book() or '')
    if self.upload_job and self.upload_job.book_id==id then self.upload_job,self.uploading=nil,false end
    self:_clear_verified(reason)
    self.dirty,self.state=false,'unverified'
end

function ProgressSync:accept_cloud_source_target(position)
    if type(position)~='table' or position.basis~='filtered_xhtml_utf16' or position.upload_verified~=false
        or position.book_id~=tostring(self.detect_book() or '') then return false end
    local held=self:current_source_target()
    if not held or held.basis~=position.basis then return false end
    for _,key in ipairs({'book_id','chapter_uid','chapter_offset','file_id','book_version','raw_sha256','render_path'}) do
        if held[key]~=position[key] then return false end
    end
    self:_clear_verified('cloud_source_selected')
    self:_discard_pending_upload(position.book_id)
    self.dirty,self.state=false,'unverified'
    return true
end

function ProgressSync:chapter_request_current(pending, scope)
    return pending ~= nil and self.pending_jump == pending and self:_account_current(pending)
        and self:_session_current(scope) and scope.navigation_generation == self.navigation_generation
end

-- ReaderUI:switchDocument destroys this plugin and creates a new one. Carry a
-- bounded, one-use intent in its after-open callback, never in settings.
function ProgressSync:chapter_handoff(path)
    local pending = self.pending_jump
    local scope = self:_scope()
    if type(path) ~= "string" or path == "" or #path > 4096 or path:find("%z")
        or not self:chapter_request_current(pending, scope) then return nil end
    local offset, fraction = pending.chapter_offset, pending.overall_fraction
    if type(offset) ~= "number" or offset < 0 or offset ~= offset or offset >= math.huge
        or type(fraction) ~= "number" or fraction < 0 or fraction > 1 or fraction ~= fraction then return nil end
    local remote = { book_id = pending.book_id, chapter_uid = pending.chapter_uid,
        chapter_idx = tonumber(pending.remote and pending.remote.chapter_idx) or 0,
        chapter_offset = offset, has_chapter_offset = true, percent = fraction * 100 }
    local token, used = {}, false
    pending.handoff = token
    return function(reader)
        if used then return false end
        used = true
        if self.pending_jump ~= pending or pending.handoff ~= token or not self:_account_current(pending)
            or self.generation ~= scope.generation + 1 or self.navigation_generation ~= scope.navigation_generation then return false end
        pending.handoff, self.pending_jump = nil, nil
        local next_sync = reader and reader.weread and reader.weread.progress_sync
        local document = next_sync and next_sync.get_document()
        if not next_sync or next_sync == self or document ~= reader.document or document_path(document) ~= path
            or tostring(next_sync.detect_book() or "") ~= tostring(pending.book_id)
            or next_sync:_account_key() ~= pending.account or next_sync.navigation_generation ~= 0 or next_sync.pending_jump then return false end
        if FileIdentity.read_document(document, pending.book_id).version_source == "book_mismatch" then return false end
        next_sync.pending_jump = { account = pending.account, account_generation = next_sync.account_generation,
            book_id = pending.book_id, chapter_uid = pending.chapter_uid, chapter_offset = offset,
            fraction = pending.fraction, overall_fraction = fraction, chapter_fraction = pending.chapter_fraction,
            remote = remote, notify = pending.notify == true, expected_path = path }
        return true
    end
end

-- Authentication changes do not change the open EPUB. Invalidate its verified
-- session explicitly, so old dialogs, tasks and chapter downloads cannot act
-- with the newly installed credentials.
function ProgressSync:on_account_changed()
    self.file_resume=nil
    self.account_generation = self.account_generation + 1
    self.generation = self.generation + 1
    self:_invalidate_pull()
    self.upload_job, self.uploading = nil, false
    self.pending_jump, self.document_context = nil, nil
    self.remote_anchor, self.source_anchor = nil, nil
    self._suspend_pending_upload = nil
    self.checkpoint_account, self.network_disconnected = nil, nil
    self.current_book_id, self.local_position, self.remote_position = nil, nil, nil
    self.verified, self.dirty, self.state = false, false, "unverified"
end

function ProgressSync:_persist(book_id, patch)
    book_id = tostring(book_id or "")
    if book_id == "" or type(patch) ~= "table" then return false end
    local books = self.settings:get("books", {})
    local book = books[book_id] or { book_id = book_id }
    for key, value in pairs(patch) do
        if value == false then
            book[key] = nil
        else
            book[key] = copy(value)
        end
    end
    books[book_id] = book
    self.settings:set("books", books)
    self.settings:flush()
    return true
end

function ProgressSync:_local_fraction()
    local document = self.get_document()
    if not document then return nil end
    local footer = self.get_footer and self.get_footer()
    return ReaderPosition.fraction(document, footer, self.get_view_mode and self.get_view_mode())
end

function ProgressSync:_viewport(document)
    return ReaderPosition.snapshot(document, self.get_view_mode and self.get_view_mode(),
        self.get_viewport_height and self.get_viewport_height())
end

function ProgressSync:_navigation_marker()
    if not self.get_navigation_xpointer then return nil end
    local ok, marker = pcall(self.get_navigation_xpointer)
    if ok and type(marker) == "string" and marker ~= "" and #marker <= 4096 then return marker end
end

function ProgressSync:_retain_target(context, target)
    local document = self.get_document()
    local frame = self:_viewport(document)
    if not frame then return end
    local position = PositionMapper.local_to_remote(context.chapters, target.fraction, {
        catalog = self.document_context and self.document_context.position_catalog,
        is_full_book = context.is_full_book,
        current_chapter_uid = context.current_chapter
            and (context.current_chapter.chapterUid or context.current_chapter.chapterId),
        summary = context.book.summary or context.book.title or "",
    })
    if not position then return end
    -- Do not round-trip a known chapter offset through a floating percentage:
    -- that can lose one word, or select the next chapter at an exact boundary.
    if target.chapter and target.chapter_offset ~= nil then
        position.chapter_uid = target.chapter.chapterUid or target.chapter.chapterId or target.chapter.chapter_uid
        position.chapter_idx = tonumber(target.chapter.chapterIdx or target.chapter.chapterIndex or target.chapter.chapter_idx) or 0
        position.chapter_offset, position.chapter_fraction = target.chapter_offset, target.chapter_fraction
    end
    self.remote_anchor = { document = document, scope = self:_scope(), frame = frame,
        xpointer = frame.xpointer, navigation_marker = self:_navigation_marker(), position = position }
end

function ProgressSync:_settle_reflow(anchor, slot)
    slot = slot or "remote_anchor"
    if anchor.reflow_pending then return end
    anchor.reflow_pending = true
    local previous, samples, tick = nil, 0
    tick = function()
        if self[slot] ~= anchor then return end
        if self.suspended_at then anchor.reflow_pending = nil; return end
        local document = self.get_document()
        local frame = self:_viewport(document)
        samples = samples + 1
        if document ~= anchor.document or not self:_session_current(anchor.scope)
            or self:_navigation_marker() ~= anchor.navigation_marker then
            self[slot] = nil
        elseif not ReaderPosition.contains_anchor(document, frame, anchor.xpointer) then
            self:_unverify_target_layout(slot)
        elseif previous and ReaderPosition.same_view(previous, frame)
            and not ReaderPosition.layout_changed(previous, frame) then
            anchor.frame, anchor.reflow_pending = frame, nil
        elseif samples >= 4 then
            self:_unverify_target_layout(slot)
        else
            previous = frame
            self.scheduler:scheduleIn(0.1, tick)
            return
        end
        -- Native layout can emit several intermediate PageUpdate/PosUpdate
        -- events and restore the native position during the subsequent draw.
        -- Two stable observations become the next movement baseline.
        self:on_page_update()
    end
    self.scheduler:scheduleIn(0.1, tick)
end

function ProgressSync:_unverify_target_layout(slot)
    slot = slot or "remote_anchor"
    self[slot] = nil
    self:_clear_verified("target_layout_unverified")
    self.state = "unverified"
end

function ProgressSync:_retained_target(document, slot)
    slot = slot or "remote_anchor"
    local anchor = self[slot]
    if not anchor then return nil end
    local frame = self:_viewport(document)
    if anchor.document ~= document or not self:_session_current(anchor.scope) or not frame then
        self[slot] = nil
        return nil
    end
    if anchor.navigation_marker and self:_navigation_marker() ~= anchor.navigation_marker then
        self[slot] = nil
        return nil
    end
    if not ReaderPosition.same_view(anchor.frame, frame) then
        if not (ReaderPosition.layout_changed(anchor.frame, frame) or anchor.reflow_pending) then
            self[slot] = nil
            return nil
        end
        if not ReaderPosition.contains_anchor(document, frame, anchor.xpointer) then
            self:_unverify_target_layout(slot)
            return nil
        end
    end
    if anchor.navigation_marker and ReaderPosition.layout_changed(anchor.frame, frame) then
        self:_settle_reflow(anchor, slot)
    elseif not anchor.reflow_pending then anchor.frame = frame end
    return anchor.position
end

-- Only a target already tied to this exact EPUB may be pinned. This does not
-- interpret cloud payloads, change outer progress units, or grant upload rights.
function ProgressSync:retain_source_target(position, xpointer, metadata)
    if type(position) ~= "table" or not Source.is_coordinate_basis(position.basis) or position.upload_verified ~= false
        or type(position.chapter_offset) ~= "number" or position.chapter_offset < 0
        or position.chapter_offset % 1 ~= 0 or position.chapter_offset > Source.MAX_BYTES * 8 then return false end
    local document = self.get_document()
    local book_id = tostring(self.detect_book() or "")
    local snapshot = Source.document_metadata(document, book_id, position.chapter_uid, position.render_path)
    if not snapshot or snapshot.metadata ~= metadata then return false end
    if position.basis ~= Source.coordinate_basis(snapshot.record.format) then return false end
    for _, key in ipairs({"book_id", "chapter_uid", "file_id", "book_version", "raw_sha256", "render_path"}) do
        if position[key] ~= snapshot.record[key] then return false end
    end
    local member = SourceDom.member(document, xpointer)
    local frame = self:_viewport(document)
    if not member or member.render_path ~= position.render_path
        or not ReaderPosition.contains_anchor(document, frame, member.xpointer) then return false end
    local accepted = { retained_source_target = true, basis = position.basis, upload_verified = false }
    for _, key in ipairs({"book_id", "chapter_uid", "chapter_offset", "file_id", "book_version", "raw_sha256", "render_path"}) do
        accepted[key] = position[key]
    end
    if type(position.chapter_title) == "string" and #position.chapter_title <= 512 and not position.chapter_title:find("[%z%c]") then
        accepted.chapter_title = position.chapter_title
    end
    self.source_anchor = { document = document, scope = self:_scope(), frame = frame, xpointer = member.xpointer,
        navigation_marker = self:_navigation_marker(), position = accepted, metadata = metadata }
    self.remote_anchor = nil
    return true
end

function ProgressSync:current_source_target()
    if self.suspended_at then return nil end
    local anchor = self.source_anchor
    if anchor then
        local snapshot = Source.document_metadata(self.get_document(), anchor.position.book_id,
            anchor.position.chapter_uid, anchor.position.render_path)
        if not snapshot or snapshot.metadata ~= anchor.metadata then self.source_anchor = nil; return nil end
    end
    return copy(self:_retained_target(self.get_document(), "source_anchor"))
end

function ProgressSync:capture_local()
    local book_id = self.detect_book()
    if not book_id or is_mp_book(book_id) then
        return nil, "document_not_weread"
    end
    book_id = tostring(book_id)
    local document = self.get_document()
    local path = document_path(document)
    if not document or not path then return nil, "document_unavailable" end
    local cached = self.document_context
    local book
    local chapters
    local current_chapter
    local is_full_book
    if cached and cached.book_id == book_id and cached.path == path then
        book = cached.book
        chapters = cached.chapters
        current_chapter = cached.current_chapter
        is_full_book = cached.is_full_book
    else
        book = self.get_book(book_id)
        if type(book) ~= "table" then return nil, "book_not_found" end
        chapters = self.get_chapters(book)
        if type(chapters) ~= "table" or #chapters == 0 then
            return nil, "catalog_unavailable"
        end
        local _index
        _index, current_chapter, is_full_book =
            self.get_file_context(book, path)
        self.document_context = {
            book_id = book_id,
            book = book,
            chapters = chapters,
            position_catalog = PositionMapper.catalog(chapters),
            current_chapter = current_chapter,
            is_full_book = is_full_book == true,
            path = path,
        }
        cached = self.document_context
    end
    local fraction = self:_local_fraction()
    if fraction == nil then return nil, "position_unavailable" end
    local position, reason = PositionMapper.local_to_remote(
        chapters,
        fraction,
        {
            catalog = cached.position_catalog,
            is_full_book = is_full_book == true,
            current_chapter_uid = current_chapter
                and (current_chapter.chapterUid or current_chapter.chapterId),
            summary = book.summary or book.title or "",
        }
    )
    if not position then return nil, reason end
    local retained = self:_retained_target(document)
    if retained then
        local viewport_fraction = position.fraction
        for key, value in pairs(retained) do position[key] = copy(value) end
        position.viewport_fraction, position.retained_remote_target = viewport_fraction, true
    end
    -- Keep source units separate from the existing word/percent contract.
    -- The local source snapshot is read-only until wire write/readback validation.
    if self.get_source_position then position.source_position = copy(self.get_source_position()) end
    position.book_id = book_id
    position.captured_at = self.now()
    position.current_chapter_uid = current_chapter
        and (current_chapter.chapterUid or current_chapter.chapterId)
    position.is_full_book = is_full_book == true
    return position, nil, {
        book_id = book_id,
        book = book,
        chapters = chapters,
        current_chapter = current_chapter,
        is_full_book = is_full_book == true,
        path = path,
    }
end

function ProgressSync:_mark_verified(book_id, reason, local_position, remote)
    self.current_book_id = tostring(book_id)
    self.checkpoint_account = self:_account_key()
    self.verified = true
    self.verified_at = self.now()
    self.verified_reason = reason
    self.local_position = copy(local_position)
    self.remote_position = copy(remote)
    self.state = "verified"
    self:_persist(book_id, {
        verified_at = self.verified_at,
        verified_source = reason,
        last_local_position = local_position,
        last_remote_position = remote,
        last_sync_error = false,
    })
    log("info", "verified:",
        "book=", tostring(book_id),
        "reason=", tostring(reason),
        "local=", tostring(local_position and local_position.percent or "-"),
        "remote=", tostring(remote and remote.percent or "-"))
end

function ProgressSync:_clear_verified(reason)
    self.verified = false
    self.verified_at = nil
    self.verified_reason = reason
    if self.current_book_id then
        self:_persist(self.current_book_id, {
            verified_at = false,
            verified_source = reason or "cleared",
        })
    end
end

function ProgressSync:_fetch_remote(book_id, chapters, is_current)
    local gateway
    local web
    local gateway_error
    local web_error
    if self.settings:is_api_configured() then
        local ok, result = pcall(self.client.get_progress, self.client, book_id)
        if ok then
            gateway, gateway_error = PositionMapper.normalize_remote(
                result, book_id, "gateway", chapters)
        else
            gateway_error = tostring(result)
        end
    end
    if is_current and not is_current() then return nil, "session_changed" end
    if self.settings:is_cookie_configured() then
        local ok, result = pcall(
            self.client.get_web_progress, self.client, book_id)
        if ok then
            web, web_error = PositionMapper.normalize_remote(
                result, book_id, "web", chapters)
        else
            web_error = tostring(result)
        end
    end
    local selected = PositionMapper.choose_remote(
        web,
        gateway,
        SOURCE_CONFLICT_THRESHOLD_PERCENT
    )
    if not selected then
        return nil, gateway_error or web_error or "remote_unavailable"
    end
    return selected
end

function ProgressSync:_discard_pending_upload(book_id)
    if self.upload_job and self.upload_job.book_id == book_id then
        self.upload_job, self.uploading = nil, false
    end
    local saved = self.get_book(book_id) or {}
    local owner = saved.pending_upload_account or saved.recent_read_account
    if saved.pending_upload_position and owner and owner == self:_account_key() then
        self:_persist(book_id, {
            pending_upload_position = false, pending_upload_reason = false, pending_upload_account = false,
        })
    end
end

function ProgressSync:_apply_remote(remote, context, options)
    options = options or {}
    -- Park the latest movement before revoking writes. A rejected target or
    -- failed engine navigation or chapter download must not lose this checkpoint.
    self:checkpoint_local("cloud_navigation")
    if self.upload_job and self.upload_job.book_id == context.book_id then
        self.upload_job, self.uploading = nil, false
    end
    self:_clear_verified("cloud_navigation")
    self.dirty = false
    local target, reason = PositionMapper.remote_to_local(
        context.chapters,
        remote,
        {
            is_full_book = context.is_full_book,
            current_chapter_uid = context.current_chapter
                and (context.current_chapter.chapterUid
                    or context.current_chapter.chapterId),
        }
    )
    if not target then return false, reason end
    if self.on_before_navigate then
        local ready = pcall(self.on_before_navigate)
        if not ready then return false, "jump_failed" end
    end

    self.remote_anchor, self.source_anchor = nil, nil

    if target.requires_chapter_open then
        self:_clear_verified("switching_chapter")
        self.dirty = false
        self.pending_jump = {
            account = self:_account_key(), account_generation = self.account_generation,
            book_id = context.book_id,
            chapter_uid = target.chapter
                and (target.chapter.chapterUid or target.chapter.chapterId),
            fraction = target.fraction,
            overall_fraction = target.overall_fraction,
            chapter_offset = target.chapter_offset,
            chapter_fraction = target.chapter_fraction,
            remote = copy(remote),
            notify = options.manual == true,
        }
        self.state = "switching_chapter"
        local open_ok, opened, open_error = pcall(
            self.open_chapter, context.book, target.chapter)
        if not open_ok or opened == false then
            self.pending_jump = nil
            self.state = "error"
            return false, (open_ok and open_error or opened)
                or "target_chapter_unavailable"
        end
        return true
    end
    local ok, err = self.goto_fraction(target.fraction)
    if not ok then return false, err or "jump_failed" end
    self:_discard_pending_upload(context.book_id)
    self:_retain_target(context, target)
    local selected_position = self:capture_local()
    self.dirty = false
    self:_mark_verified(
        context.book_id,
        "remote_selected",
        selected_position or self.local_position,
        remote
    )
    if options.manual then
        self.notify("remote_applied", { position = remote })
    end
    local scope = self:_scope()
    self.scheduler:scheduleIn(0.15, function()
        if not self:_session_current(scope) then return end
        local position = self:capture_local()
        if position then
            self.local_position = position
            self:_persist(context.book_id, {
                last_local_position = position,
            })
        end
    end)
    return true
end

function ProgressSync:_upload_snapshot(position, reason, show_result)
    if type(position) ~= "table" then return false end
    local book_id = tostring(position.book_id or self.current_book_id or "")
    if book_id == "" then return false end
    position = copy(position)
    local scope = self:_scope()
    scope.book_id = book_id
    if not scope.account then return false end
    self:_persist(book_id, {
        last_local_position = position,
        pending_upload_position = position,
        pending_upload_reason = reason or "unspecified",
        pending_upload_account = scope.account,
    })
    -- Capture the latest location even while an older immutable snapshot is
    -- waiting on the time reporter. Its eventual acknowledgement may only
    -- remove that older snapshot, never this new one.
    if self.uploading then return false end
    if not self.is_online() then
        self.state = "offline"
        if show_result then self.notify("offline", {}) end
        return false
    end
    self.uploading = true
    if self:_session_current(scope) then self.state = "uploading" end
    local job = { scope = scope, book_id = book_id }
    self.upload_job = job
    local function current()
        if self.upload_job ~= job then return false end
        if self:_account_current(scope) then return true end
        self.upload_job, self.uploading = nil, false
        return false
    end
    local attempts = 0
    local attempt, finish
    finish = function(ok, accepted, outcome)
        if not current() then return end
        if ok and not accepted and type(outcome) == "table"
            and outcome.error_kind == "busy"
            and attempts < BUSY_RETRY_LIMIT then
            self.scheduler:scheduleIn(BUSY_RETRY_SECONDS, attempt)
            return
        end
        if ok and not accepted and type(outcome) == "table" and outcome.acknowledged == true
            and outcome.error_kind == "confirmation_pending" and outcome.confirmation
            and type(self.confirm_position) == "function" and (job.confirmation_polls or 0) < 2 then
            local receipt = outcome.confirmation
            job.confirmation_polls = (job.confirmation_polls or 0) + 1
            self.scheduler:scheduleIn(1, function()
                if not current() then return end
                local started = self.run_online("progress_confirmation", function()
                    if not current() then return end
                    finish(pcall(self.confirm_position, receipt))
                end, { silent_offline = true })
                if not started and current() then finish(true, false, { error_kind = "unconfirmed" }) end
            end)
            return
        end
        self.upload_job, self.uploading = nil, false
        local confirmed = ok and accepted and type(outcome) == "table" and outcome.position_confirmed == true
            and outcome.acknowledged == true
        if confirmed then
            local book = self.get_book(book_id) or {}
            local clear_pending = book.pending_upload_account == scope.account
                and ProgressReadback.same_intent(book.pending_upload_position, position)
            local patch = {
                last_uploaded_position = position,
                last_upload_at = self.now(),
                last_sync_error = false,
                last_remote_position = outcome.remote,
            }
            if clear_pending then
                patch.pending_upload_position, patch.pending_upload_reason, patch.pending_upload_account = false, false, false
            end
            self:_persist(book_id, patch)
            local active = self:_session_current(scope)
            if active then
                local live = self:capture_local() or self.local_position
                self.dirty = not ProgressReadback.same_wire_position(live, position) or not clear_pending
                self.last_uploaded_position = copy(position)
                if not self.pulling and self.state ~= "awaiting_choice" then
                    self.state = self.verified and "verified" or "unverified"
                end
            end
            log("info", "upload accepted:",
                "book=", book_id,
                "percent=", tostring(position.percent),
                "reason=", tostring(reason))
            if show_result and active then
                self.notify("upload_success", { position = position })
            end
            return
        end
        local error_message = ok and type(outcome) == "table"
            and outcome.error or outcome
        local active = self:_session_current(scope)
        local unconfirmed = accepted or type(outcome) == "table"
            and (outcome.error_kind == "unconfirmed" or outcome.error_kind == "confirmation_pending")
        if unconfirmed then error_message = "upload_readback_unconfirmed" end
        if active then
            if unconfirmed then self:_clear_verified("upload_readback_unconfirmed") end
            self.state = "error"
        end
        local patch = { last_sync_error = tostring(error_message or "upload_failed") }
        local saved = self.get_book(book_id) or {}
        if unconfirmed and saved.pending_upload_account == scope.account and saved.pending_upload_position then
            patch.pending_upload_reason = "upload_readback_unconfirmed"
        end
        self:_persist(book_id, patch)
        log("warn", "upload failed:", tostring(error_message))
        if show_result and active then
            self.notify(unconfirmed and "upload_unconfirmed" or "upload_failed", {
                error = tostring(error_message or "upload_failed"),
            })
        end
    end
    attempt = function()
        if not current() then return end
        attempts = attempts + 1
        finish(pcall(self.upload_position, book_id, copy(position), 0))
    end
    local started = self.run_online("progress_upload", attempt)
    if not started and self.upload_job == job then
        self.upload_job, self.uploading = nil, false
        self.state = "offline"
    end
    return started == true
end

function ProgressSync:_keep_local(local_position, remote, options)
    options = options or {}
    self.dirty = not PositionMapper.same_position(local_position, remote)
    self:_mark_verified(
        local_position.book_id,
        "local_selected",
        local_position,
        remote
    )
    if options.upload_now then
        self:_upload_snapshot(local_position, options.reason, true)
    elseif options.manual then
        self.notify("local_kept", { position = local_position })
    end
end

function ProgressSync:_resolve(local_position, remote, context, options)
    options = options or {}
    self.local_position = copy(local_position)
    self.remote_position = copy(remote)
    local comparison = PositionMapper.compare(
        local_position,
        remote,
        SAME_THRESHOLD_PERCENT
    )
    local saved = self.get_book(context.book_id) or {}
    local uncertain = saved.pending_upload_reason == "upload_readback_unconfirmed"
        and saved.pending_upload_account == self:_account_key() and saved.pending_upload_position ~= nil
    local needs_choice = uncertain and not ProgressReadback.matches_normalized(local_position, remote)

    if comparison == "same" and not remote.conflict and not needs_choice then
        self:_discard_pending_upload(context.book_id)
        self.dirty = false
        self:_mark_verified(
            context.book_id,
            "positions_match",
            local_position,
            remote
        )
        if options.manual then
            self.notify("already_synced", { position = local_position })
        end
        return
    end

    local ask = self:_config().ask_on_conflict ~= false
    if remote.conflict or ask or needs_choice then
        self.state = "awaiting_choice"
        local scope, decided = self:_scope(), false
        local function choice_is_current()
            if decided or not self:_session_current(scope) or scope.navigation_generation ~= self.navigation_generation then return false end
            decided = true
            return true
        end
        self.on_choice({
            book_title = context.book.title or context.book_id,
            local_position = copy(local_position),
            remote_position = copy(remote),
            source_conflict = remote.conflict == true,
            use_remote = function()
                if not choice_is_current() then return end
                local ok, reason = self:_apply_remote(
                    remote, context, { manual = options.manual })
                if not ok then
                    self.state = "error"
                    self.notify("jump_failed", { error = reason })
                end
            end,
            keep_local = function()
                if not choice_is_current() then return end
                local latest, reason = self:capture_local()
                if not latest then
                    self.notify("local_unavailable", { error = reason })
                    return
                end
                self:_keep_local(latest, remote, {
                    manual = options.manual,
                    upload_now = true,
                    reason = "explicit_local_choice",
                })
            end,
        })
        return
    end

    if comparison == "remote_ahead" then
        local ok, reason = self:_apply_remote(
            remote, context, { manual = options.manual })
        if not ok then
            self.state = "error"
            self.notify("jump_failed", { error = reason })
        end
    else
        self:_keep_local(local_position, remote, {
            manual = options.manual,
            upload_now = options.manual == true,
            reason = "manual_sync",
        })
    end
end

function ProgressSync:_schedule_pull_retry(options, retry_token)
    local attempt = (options.retry or 0) + 1
    if attempt > PULL_MAX_RETRIES then
        log("warn", "pull retries exhausted:",
            "book=", tostring(self.current_book_id))
        return false
    end
    local scope = self:_scope()
    self.scheduler:scheduleIn(PULL_RETRY_DELAY_SECONDS, function()
        if not self:_session_current(scope) then return end
        if retry_token ~= self.pull_retry_token then return end
        if self.verified or self.pulling then return end
        if self.state == "awaiting_choice" then return end
        self:_pull({
            manual = false,
            retry = attempt,
            retry_token = retry_token,
        })
    end)
    log("info", "pull retry scheduled:",
        "book=", tostring(self.current_book_id),
        "attempt=", tostring(attempt),
        "delay=", tostring(PULL_RETRY_DELAY_SECONDS))
    return true
end

function ProgressSync:_pull(options)
    options = options or {}
    if self.pulling then return false end
    local retry_token = options.retry_token
    if retry_token == nil then
        self.navigation_generation = self.navigation_generation + 1
        self.pull_retry_token = self.pull_retry_token + 1
        retry_token = self.pull_retry_token
        local book_id = tostring(self.detect_book() or "")
        if self.upload_job and self.upload_job.book_id == book_id then
            self.upload_job, self.uploading = nil, false
        end
        -- A new comparison replaces the previous decision, including when the
        -- server returns malformed/foreign data. Keep the local checkpoint.
        self:_clear_verified("progress_recheck")
    elseif retry_token ~= self.pull_retry_token then
        return false
    end
    local local_position, reason, context = self:capture_local()
    if not local_position then
        if not (options.manual == true
            and reason == "catalog_unavailable"
            and type(self.refresh_catalog) == "function") then
            if options.manual then
                self.notify("local_unavailable", { error = reason })
            end
            return false
        end
    end
    if not self.settings:is_api_configured()
        and not self.settings:is_cookie_configured() then
        if options.manual then self.notify("authentication_required", {}) end
        return false
    end
    if not self.is_online() then
        self.state = "offline"
        if options.manual then
            self.notify("offline", {})
        else
            self:_schedule_pull_retry(options, retry_token)
        end
        return false
    end

    local scope = self:_scope()
    local job = { scope = scope }
    self.pull_job = job
    local function current()
        if self.pull_job ~= job then return false end
        if self:_session_current(scope) and scope.navigation_generation == self.navigation_generation then return true end
        self.pull_job, self.pulling = nil, false
        return false
    end
    self.pulling = true
    self.state = "pulling"
    local started = self.run_online("progress_pull", function()
        if not current() then return end
        if not local_position then
            local book_id = tostring(self.detect_book() or "")
            local refresh_ok, refreshed, refresh_error = pcall(
                self.refresh_catalog, book_id)
            if not current() then return end
            if not refresh_ok then
                refresh_error = refreshed
                refreshed = nil
            end
            self.document_context = nil
            local_position, reason, context = self:capture_local()
            if not local_position then
                self.pull_job, self.pulling = nil, false
                self.state = "error"
                self.notify("local_unavailable", {
                    error = refresh_error or reason,
                })
                return
            end
            if type(refreshed) ~= "table" or #refreshed == 0 then
                log("warn", "catalog refresh returned no chapters for:", book_id)
            end
        end
        local remote, pull_error = self:_fetch_remote(
            context.book_id,
            context.chapters,
            current
        )
        if not current() then return end
        self.pull_job, self.pulling = nil, false
        if not remote then
            self.state = "error"
            self:_persist(context.book_id, {
                last_pull_at = self.now(),
                last_sync_error = tostring(pull_error),
            })
            if options.manual then
                self.notify("pull_failed", { error = tostring(pull_error) })
            end
            return
        end
        -- The user may have turned pages while the online task was queued.
        -- Compare the cloud result with the live page, not the opening page.
        local_position, reason, context = self:capture_local()
        if not local_position then
            self.state = "unsafe"
            if options.manual then self.notify("local_unavailable", { error = reason }) end
            return
        end
        self:_persist(context.book_id, {
            last_remote_position = remote,
            last_local_position = local_position,
            last_pull_at = self.now(),
            last_sync_error = false,
        })
        self:_resolve(local_position, remote, context, options)
    end, { silent_offline = true })
    if not started and self.pull_job == job then
        self.pull_job, self.pulling = nil, false
        self.state = "offline"
        if options.manual then
            self.notify("offline", {})
        else
            self:_schedule_pull_retry(options, retry_token)
        end
    end
    return started == true
end

function ProgressSync:_apply_pending_jump(book_id)
    local pending = self.pending_jump
    if pending and not self:_account_current(pending) then self.pending_jump = nil return false end
    if not pending or tostring(pending.book_id) ~= tostring(book_id) then
        return false
    end
    local local_position, _reason, context = self:capture_local()
    if not context or (pending.expected_path and context.path ~= pending.expected_path) then
        return false
    end
    local target = PositionMapper.remote_to_local(context.chapters, pending.remote, {
        is_full_book = context.is_full_book, current_chapter_uid = context.current_chapter
            and (context.current_chapter.chapterUid or context.current_chapter.chapterId),
    })
    if not target or target.requires_chapter_open then return false end
    self.pending_jump = nil
    if self.on_before_navigate then
        local ready = pcall(self.on_before_navigate)
        if not ready then self.state = "error"; self.notify("jump_failed", {}); return true end
    end
    local ok, err = self.goto_fraction(target.fraction)
    if not ok then
        self.state = "error"
        self.notify("jump_failed", { error = err })
        return true
    end
    self:_discard_pending_upload(book_id)
    self:_retain_target(context, target)
    local_position = self:capture_local() or local_position
    self.dirty = false
    self:_mark_verified(
        book_id,
        "remote_chapter_applied",
        local_position,
        pending.remote
    )
    if pending.notify then
        self.notify("remote_applied", { position = pending.remote })
    end
    local scope = self:_scope()
    self.scheduler:scheduleIn(0.15, function()
        if not self:_session_current(scope) then return end
        local position = self:capture_local()
        if position then
            self.local_position = position
            self:_persist(book_id, { last_local_position = position })
        end
    end)
    return true
end

function ProgressSync:cancel_pending_jump(reason)
    if not self.pending_jump then return false end
    self.pending_jump = nil
    self.dirty = false
    self.state = "unverified"
    self:_clear_verified(tostring(reason or "pending_jump_cancelled"))
    return true
end

function ProgressSync:on_reader_ready()
    self.file_resume=nil
    self.remote_anchor, self.source_anchor = nil, nil
    self.generation = self.generation + 1
    self:_invalidate_pull()
    if self.upload_job and self.upload_job.book_id == tostring(self.detect_book() or "") then
        -- A reopened copy/chapter of this book owns its next cloud comparison.
        -- Closing another book may still finish its independent final upload.
        self.upload_job, self.uploading = nil, false
    end
    local generation = self.generation
    local navigation_generation = self.navigation_generation
    self.current_book_id = nil
    self.checkpoint_account = self:_account_key()
    self.network_disconnected = nil
    self.local_position = nil
    self.remote_position = nil
    self.document_context = nil
    self.verified = false
    self.dirty = false
    self.state = "waiting"

    self.scheduler:scheduleIn(OPEN_DELAY_SECONDS, function()
        if generation ~= self.generation then return end
        local book_id = self.detect_book()
        if not book_id or is_mp_book(book_id) then
            self.state = "unsupported"
            return
        end
        book_id = tostring(book_id)
        self.current_book_id = book_id
        if self.file_resume then self.state='unverified';return end
        if navigation_generation ~= self.navigation_generation then
            if not self.local_position then self.local_position = self:capture_local() end
            if not self.verified then self.state = "unverified" end
            return
        end
        if self:_apply_pending_jump(book_id) then return end

        local local_position, reason = self:capture_local()
        if not local_position then
            self.state = "unsafe"
            log("warn", "local position unavailable:", tostring(reason))
            return
        end
        self.local_position = local_position
        self:_persist(book_id, { last_local_position = local_position })
        if self:_config().pull_on_open ~= true then
            self.state = "unverified"
            return
        end
        self:_pull({ manual = false })
    end)
end

function ProgressSync:on_page_update()
    if not self.current_book_id then return end
    if self.file_resume then
        if not self.file_resume.failed or self:_file_resume_unchanged(self.file_resume) then return end
        self.file_resume=nil
    end
    local position = self:capture_local()
    if not position then return end
    if self.local_position
        and not PositionMapper.same_position(position, self.local_position) then
        self.dirty = true
    end
    self.local_position = position
end

-- Durable local movement is independent of cloud verification and automatic
-- upload settings. A checkpoint never starts a request or opens the report gate.
function ProgressSync:checkpoint_local(reason, source_position)
    if self.file_resume then
        if not self.file_resume.failed or self:_file_resume_unchanged(self.file_resume) then return end
        self.file_resume=nil
    end
    local position = self:capture_local() or self.local_position
    if not position or (self.current_book_id ~= position.book_id and not self.verified) then return end
    local account = self:_account_key()
    if not account or self.checkpoint_account and self.checkpoint_account ~= account then return end
    if position and source_position and source_position.book_id == position.book_id then
        position.source_position = copy(source_position)
    end
    if self.local_position and not PositionMapper.same_position(position, self.local_position) then self.dirty = true end
    local patch = { last_local_position = position }
    if self.dirty then
        local saved = self.get_book(position.book_id) or {}
        patch.pending_upload_position = position
        patch.pending_upload_reason = saved.pending_upload_account == account
            and saved.pending_upload_reason == "upload_readback_unconfirmed" and "upload_readback_unconfirmed"
            or reason or "local_checkpoint"
        patch.pending_upload_account = account
    end
    self:_persist(position.book_id, patch)
    self.local_position = copy(position)
    return position
end

function ProgressSync:on_close_document(source_position)
    local position = self:checkpoint_local("document_close", source_position)
        or self:capture_local() or self.local_position
    if position and self.verified
        and self:_config().upload_on_close == true then
        if not self.local_position
            or not PositionMapper.same_position(position, self.local_position) then
            self.dirty = true
        end
        if self.dirty then
            self:_upload_snapshot(position, "document_close", false)
        end
    end
    self.generation = self.generation + 1
    self:_invalidate_pull()
    self.current_book_id = nil
    self.checkpoint_account, self.network_disconnected = nil, nil
    self.verified = false
    self.local_position = nil
    self.remote_position = nil
    self.document_context = nil
    self.remote_anchor, self.source_anchor = nil, nil
    self.file_resume=nil
end

function ProgressSync:on_suspend(source_position)
    local position = self:checkpoint_local("suspend", source_position)
    self.generation = self.generation + 1
    if self.file_resume then self.file_resume.scope.generation=self.generation end
    for _, slot in ipairs({"remote_anchor", "source_anchor"}) do
        if self[slot] then self[slot].scope.generation = self.generation end
    end
    self:_invalidate_pull()
    self._suspend_pending_upload = self.uploading == true
    self.upload_job, self.uploading = nil, false
    self.suspended_at = self.now()
    if position and self.dirty then self._suspend_pending_upload = true end
end

function ProgressSync:on_network_disconnected()
    if not self.current_book_id then return false end
    self:checkpoint_local("network_disconnected")
    self.navigation_generation = self.navigation_generation + 1
    self:_invalidate_pull()
    self.upload_job, self.uploading = nil, false
    self:_clear_verified("network_disconnected")
    self.network_disconnected, self.state = true, "offline"
    return true
end

function ProgressSync:on_network_connected()
    if self.file_resume or self:_config().pull_on_open ~= true or not self.current_book_id or self.pulling
        or self.state == "awaiting_choice" or self.pending_jump or self:current_source_target() then return false end
    if self.checkpoint_account ~= self:_account_key() then return false end
    if self.verified and not self.network_disconnected then return false end
    self.network_disconnected = nil
    self:_clear_verified("network_recheck")
    return self:_pull({ manual = false })
end

function ProgressSync:on_resume()
    local slept = self.suspended_at and self.now() - self.suspended_at or 0
    self.suspended_at = nil
    if self.file_resume then return end
    local pending = self._suspend_pending_upload
    self._suspend_pending_upload = nil
    local automatic = self:_config().pull_on_open == true
    if pending or (automatic and (slept >= RESUME_RECHECK_SECONDS or not self.verified)) then
        self:_clear_verified("resume_recheck")
        if automatic then self:_pull({ manual = false }) end
    end
end

function ProgressSync:sync_now()
    if self.file_resume and self.on_before_navigate then pcall(self.on_before_navigate) end
    self.file_resume=nil
    return self:_pull({ manual = true })
end

function ProgressSync:position_for_report(book_id)
    local current = self.detect_book()
    if not current or tostring(current) ~= tostring(book_id)
        or is_mp_book(book_id) then
        return nil, nil, false
    end
    if self.uploading then return nil, "progress_confirmation_pending", true end
    if not self.verified then
        return nil, "progress_unverified", true
    end
    local position, reason = self:capture_local()
    if not position then
        return nil, reason or "position_unavailable", true
    end
    if self.local_position
        and not PositionMapper.same_position(position, self.local_position) then
        self.dirty = true
    end
    self.local_position = position
    return position, nil, true
end

function ProgressSync:on_source_position_changed(state, position)
    self.source_state = state
    if self.local_position then
        self.local_position.source_position = position and tostring(position.book_id) == tostring(self.current_book_id)
            and copy(position) or nil
    end
end

function ProgressSync:status()
    return {
        state = self.state,
        source_state = self.source_state,
        source_position = self.get_source_position and copy(self.get_source_position()) or nil,
        book_id = self.current_book_id,
        verified = self.verified,
        dirty = self.dirty,
        pulling = self.pulling == true,
        uploading = self.uploading == true,
        local_position = copy(self.local_position),
        remote_position = copy(self.remote_position),
    }
end

return ProgressSync
