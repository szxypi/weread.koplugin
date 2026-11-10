-- Opt-in addon for the real-book reading probe. Tokens are read-only RAM
-- values; only one selected chapter's underline/thought reads can dispatch.
return function(input, mode, counters)
    local Json = require("json")
    local Crypto = require("weread.lib.crypto")
    local Protocol = require("weread.lib.protocol")
    local config = assert(input.annotations)
    assert(type(config.ranges) == "table" and #config.ranges > 0 and #config.ranges <= 4096)
    assert(type(config.digest) == "string" and config.digest:match("^[a-f0-9]+$") and #config.digest == 64)
    assert(config.underlines == #config.ranges and config.thought_items > 0)
    local credentials = assert(config.credentials)
    assert(credentials.vid == input.vid and type(credentials.accessToken) == "string")
    local case = { enabled = false, ranges = config.ranges, report = {
        source_data_matches = false, picker_and_matching = false, all_records_checked = false,
        real_overlay_tap = false, popup_matches_cached_items = false, position_restored = false,
        underlines = 0, thought_items = 0, located = 0, unmatched = 0, partial = 0,
        native_underlines_requests = 0, native_thought_requests = 0, native_denied_requests = 0, failed_line = 0,
        unmatched_missing_quote = 0, unmatched_quote_search_hits = 0,
        unmatched_original_quote_differs = 0, unmatched_original_search_hits = 0,
        source_quote_recheck_verified = false, source_quote_recheck_located = 0, source_quote_recheck_unmatched = 0,
        source_quote_miss_overlap = 0, source_quote_miss_equal_start = 0,
        source_quote_miss_earlier_hit = 0, source_quote_miss_outside_chapter = 0,
        sealed_chapter_recheck_located = 0,
    } }
    local owner_case = case
    local Store = require("weread.lib.native_credentials")
    function Store:_read()
        if not self.settings:auth_scope_matches({ vid = input.vid, epoch = 1 }) then return nil, "unavailable" end
        if not owner_case.enabled then return { revision = 0 } end
        local grant = {}
        for key, value in pairs(credentials) do grant[key] = value end
        grant.epoch, grant.verified_at, grant.book_count = 1, os.time(), input.shelf_books
        return { revision = 1, authorization = grant }
    end
    function Store:_write() error("native credential writes disabled", 0) end
    local underlines_url = "https://i.weread.qq.com/book/underlines?bookId=" .. Protocol.urlencode(input.book_id)
        .. "&chapterUid=" .. Protocol.urlencode(input.chapter_uid) .. "&synckey=0"
    function case:is_native(options)
        local headers = options.headers or {}
        return type(options.url) == "string" and options.url:find("https://i.weread.qq.com", 1, true) == 1
            or headers.accessToken ~= nil or headers.vid ~= nil
    end
    function case:request(client, options, dispatch)
        local headers = options.headers or {}
        local common = mode == "live" and self.enabled and options.skip_cookie == true
            and options.persist_response_cookies == false and options.sensitive == true
            and headers.vid == input.vid and headers.accessToken == credentials.accessToken
            and not headers.Cookie and not headers.cookie and not headers.Authorization and not headers.authorization
        local kind
        if common and options.url == underlines_url and options.method == "GET" and not options.body and counters[20] == 0 then
            kind = 20
        elseif common and options.url == "https://i.weread.qq.com/book/readreviews" and options.method == "POST"
            and type(options.body) == "string" and #options.body <= 16384 and counters[20] == 1 then
            local valid, body = pcall(Json.decode, options.body)
            if valid and type(body) == "table" and body.bookId == input.book_id
                and body.chapterUid == tonumber(input.chapter_uid) and body.cht2sMode == "" and type(body.reviews) == "table" then
                local fields, known_fields = 0, true
                for key in pairs(body) do
                    if not ({ bookId = true, chapterUid = true, cht2sMode = true, reviews = true })[key] then known_fields = false end
                    fields = fields + 1
                end
                local start = tonumber(counters[21]) * 30 + 1
                local count = math.min(30, #self.ranges - start + 1)
                local exact = known_fields and fields == 4 and count > 0 and #body.reviews == count
                for _i, row in ipairs(body.reviews) do
                    local keys = 0
                    for key in pairs(row) do
                        if not ({ range = true, maxIdx = true, count = true, synckey = true })[key] then exact = false end
                        keys = keys + 1
                    end
                    if keys ~= 4 or row.range ~= self.ranges[start + _i - 1] or row.maxIdx ~= 0
                        or row.count ~= 30 or row.synckey ~= 0 then exact = false end
                end
                if exact then kind = 21 end
            end
        end
        if not kind then counters[22] = counters[22] + 1; error("native annotation scope rejected", 0) end
        counters[kind] = counters[kind] + 1
        return dispatch(client, options)
    end
    local function digest(source)
        local parts = {}
        local function add(value)
            if value == nil or value == Json.util.null then value = "" end
            assert(type(value) == "string" or type(value) == "number")
            value = tostring(value); parts[#parts + 1] = #value .. ":" .. value
        end
        local underlines, reviews = {}, {}
        for _i, row in ipairs(source.underlines) do underlines[#underlines + 1] = row.range end
        table.sort(underlines)
        for _i, marker in ipairs(underlines) do add("underline"); add(marker) end
        for _i, row in ipairs(source.reviews) do reviews[#reviews + 1] = row end
        table.sort(reviews, function(a, b) return a.range < b.range end)
        for _i, row in ipairs(reviews) do
            add("range"); add(row.range); add(#row.pageReviews)
            for _j, page in ipairs(row.pageReviews) do
                local review = page.review or page
                add(review.reviewId); add(review.content); add(review.abstract); add(review.contextAbstract)
            end
        end
        return Crypto.sha256_hex(table.concat(parts))
    end
    function case:run(plugin, reader, pump, tick)
        local UI = require("ui/uimanager")
        local function dismiss()
            local top = UI:getTopmostVisibleWidget()
            if top and getmetatable(top) == require("ui/widget/infomessage") then UI:close(top) end
        end
        dismiss(); self.enabled = true
        if mode == "live" then
            local picker = assert(plugin:chooseAnnotationChapters())
            local target = assert(picker.model.by_uid[input.chapter_uid]); assert(target.selectable)
            local position
            for index, node in ipairs(picker.model:visible()) do if node == target then position = index; break end end
            assert(position)
            picker.page = math.floor((position - 1) / picker.per_page) + 1; picker:rebuild()
            picker.layout[(position - 1) % picker.per_page + 1][1].callback()
            pump(function() return picker.model.count == 1 end)
            picker.action_button.callback()
        else
            plugin.isNetworkConnected = function() return false end
            plugin:getUnifiedAnnotationMenuItems()[2].callback()
        end
        pump(function() return plugin._external_annotation_sync ~= nil end)
        pump(function() return not plugin._external_annotation_sync end)
        local context = assert(plugin:_prepareAnnotationContext(false))
        local source = assert(context.store:get(input.book_id, "source", input.chapter_uid))
        assert(digest(source) == config.digest)
        self.report.source_data_matches = true
        local count = 0
        for _i, row in ipairs(source.reviews) do count = count + #row.pageReviews end
        assert(#source.underlines == config.underlines and count == config.thought_items)
        self.report.underlines, self.report.thought_items = #source.underlines, count
        local key = context.store:projectionKey(context.document_key, input.chapter_uid)
        local projection = assert(context.store:get(input.book_id, "projection", key))
        local stats = assert(projection.stats)
        self.report.located, self.report.unmatched, self.report.partial = stats.located, stats.total - stats.located, stats.partial or 0
        assert(stats.total == config.underlines and stats.located == #projection.records and stats.located > 0)
        assert(not context.store:get(input.book_id, "download", input.chapter_uid))
        self.report.picker_and_matching = true
        local located = {}
        for _i, record in ipairs(projection.records) do located[record.range] = true end
        local External = require("weread.lib.external_annotations")
        local original = context.store:get(input.book_id, "original", input.chapter_uid)
        -- Re-run a private copy against the sealed, actually opened source.
        -- This experiment never changes stored source/projections or the UI.
        local sealed = assert(require("weread.lib.position_source").read_document(reader.document, input.book_id, input.chapter_uid))
        local spans = require("weread.lib.annotation_source").index(sealed.raw)
        local source_quotes, quote_parts = {}, {}
        local markers = {}
        for _i, marker in ipairs(config.ranges) do markers[#markers + 1] = marker end
        table.sort(markers)
        for _i, marker in ipairs(markers) do
            local text = require("weread.lib.annotation_source").quote(spans, marker)
            source_quotes[marker] = text
            quote_parts[#quote_parts + 1] = #marker .. ":" .. marker .. #text .. ":" .. text
        end
        assert(Crypto.sha256_hex(table.concat(quote_parts)) == config.source_quotes_digest)
        local candidate = { book_id = source.book_id, chapter_uid = source.chapter_uid, reviews = source.reviews, underlines = {} }
        for _i, row in ipairs(source.underlines) do
            local copy = {}
            for field, value in pairs(row) do copy[field] = value end
            local text = source_quotes[row.range]
            if text ~= "" then copy.markText = text end
            candidate.underlines[#candidate.underlines + 1] = copy
        end
        local candidate_records, candidate_stats = External.locate(reader.document, { candidate }, {
            chapter_ranges = context.ranges, include_items = false })
        self.report.source_quote_recheck_located = candidate_stats.located
        self.report.source_quote_recheck_unmatched = candidate_stats.total - candidate_stats.located
        for _i, record in ipairs(candidate_records) do
            local text = assert(reader.document:getTextFromXPointers(record.pos0, record.pos1))
            assert(External.flatten_text(text) == External.flatten_text(record.text))
        end
        self.report.source_quote_recheck_verified = true
        local source_index = assert(require("weread.lib.source_dom").open(reader.document, input.book_id, input.chapter_uid))
        local bounded = { start_xpointer = context.ranges[input.chapter_uid].start_xpointer, end_xpointer = source_index.ending }
        local sealed_records, sealed_stats = External.locate(reader.document, { candidate }, {
            chapter_ranges = { [input.chapter_uid] = bounded }, include_items = false })
        for _i, record in ipairs(sealed_records) do
            local text = assert(reader.document:getTextFromXPointers(record.pos0, record.pos1))
            assert(External.flatten_text(text) == External.flatten_text(record.text))
            assert(require("weread.lib.source_dom").fragment(record.pos0) == source_index.root
                and require("weread.lib.source_dom").fragment(record.pos1) == source_index.root)
        end
        self.report.sealed_chapter_recheck_located = sealed_stats.located
        local rechecked, previous = {}, nil
        for _i, record in ipairs(candidate_records) do rechecked[record.range] = record end
        local ordered = {}
        for _i, row in ipairs(candidate.underlines) do ordered[#ordered + 1] = row end
        table.sort(ordered, function(a, b) return tonumber(a.range:match("^(%d+)")) < tonumber(b.range:match("^(%d+)")) end)
        for _i, row in ipairs(ordered) do
            if rechecked[row.range] then previous = rechecked[row.range]
            else
                local quote = External.quote_for(row, source.reviews)
                local hits = reader.document:findAllText(quote, true, 0, 16, false, 0) or {}
                local same, earlier, inside = false, false, false
                local boundary = assert(context.ranges[input.chapter_uid])
                for _j, hit in ipairs(hits) do
                    if previous then
                        local cmp = reader.document:compareXPointers(previous.pos0, hit.start)
                        same, earlier = same or cmp == 0, earlier or cmp == -1
                    end
                    local cmp = reader.document:compareXPointers(boundary.start_xpointer, hit.start)
                    if cmp ~= -1 and reader.document:compareXPointers(hit.start, boundary.end_xpointer) == 1
                        and reader.document:compareXPointers(hit["end"], boundary.end_xpointer) ~= -1 then inside = true end
                end
                if previous and tonumber(row.range:match("^(%d+)")) < tonumber(previous.range:match("%-(%d+)$")) then
                    self.report.source_quote_miss_overlap = self.report.source_quote_miss_overlap + 1
                end
                if same then self.report.source_quote_miss_equal_start = self.report.source_quote_miss_equal_start + 1 end
                if earlier then self.report.source_quote_miss_earlier_hit = self.report.source_quote_miss_earlier_hit + 1 end
                if #hits > 0 and not inside then self.report.source_quote_miss_outside_chapter = self.report.source_quote_miss_outside_chapter + 1 end
            end
        end
        for _i, row in ipairs(source.underlines) do
            if not located[row.range] then
                local quote = External.quote_for(row, source.reviews)
                if quote == "" then self.report.unmatched_missing_quote = self.report.unmatched_missing_quote + 1
                else
                    local hits = reader.document:findAllText(quote, true, 0, 16, false, 0) or {}
                    if #hits > 0 then self.report.unmatched_quote_search_hits = self.report.unmatched_quote_search_hits + 1 end
                end
                local raw_quote = require("weread.lib.annotation_source").quote(original, row.range)
                if raw_quote ~= "" and External.flatten_text(raw_quote) ~= External.flatten_text(quote) then
                    self.report.unmatched_original_quote_differs = self.report.unmatched_original_quote_differs + 1
                    local hits = reader.document:findAllText(raw_quote, true, 0, 16, false, 0) or {}
                    if #hits > 0 then self.report.unmatched_original_search_hits = self.report.unmatched_original_search_hits + 1 end
                end
            end
        end
        reader.document:clearSelection()
        local function normalized(text) return text:gsub("%s+", ""):gsub("\194\160", ""):gsub("\227\128\128", "") end
        local selected, expected
        for _i, record in ipairs(projection.records) do
            assert(record.book_id == input.book_id and record.chapter_uid == input.chapter_uid)
            assert(type(record.pos0) == "string" and type(record.pos1) == "string" and not record.partial)
            local text = assert(reader.document:getTextFromXPointers(record.pos0, record.pos1))
            assert(normalized(text) == normalized(record.text))
            if source_quotes[record.range] ~= "" then
                assert(External.flatten_text(record.text) == External.flatten_text(source_quotes[record.range]))
            end
            local review
            for _j, row in ipairs(source.reviews) do if row.range == record.range then review = row; break end end
            if not selected and review and #review.pageReviews > 0 then
                selected, expected = record, require("weread.lib.annotations").buildThoughtPopupItems(review)
            end
        end
        self.report.all_records_checked = true
        dismiss(); assert(selected and expected and #expected > 0)
        reader.rolling:onGotoXPointer(selected.pos0); tick(); UI:forceRePaint()
        assert(plugin._xpointer_overlay and plugin._xpointer_overlay.enabled)
        local visible
        for _i, item in ipairs(plugin._xpointer_overlay.visible or {}) do
            if item.record and item.record.range == selected.range then visible = item; break end
        end
        assert(visible)
        local pos = { x = visible.rect.x + visible.rect.w / 2, y = visible.rect.y + visible.rect.h / 2 }
        assert(plugin:_onXPointerOverlayTap({ pos = pos })); self.report.real_overlay_tap = true
        local popup = assert(UI:getTopmostVisibleWidget())
        assert(type(popup.items) == "table" and #popup.items == #expected)
        for _i, item in ipairs(expected) do
            for _j, field in ipairs({ "content", "author", "abstract" }) do assert(popup.items[_i][field] == item[field]) end
        end
        UI:forceRePaint(); require("weread.ui.thought_popup").closeVisible()
        self.report.popup_matches_cached_items = true
    end
    function case:secrets()
        return { credentials.accessToken, credentials.refreshToken, credentials.deviceId }
    end
    function case:finish(reason)
        self.report.native_underlines_requests, self.report.native_thought_requests = tonumber(counters[20]), tonumber(counters[21])
        self.report.native_denied_requests = tonumber(counters[22])
        self.report.failed_line = tonumber(type(reason) == "string" and reason:match("owner_annotations_case%.lua:(%d+):")) or 0
    end
    return case
end
