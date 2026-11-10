-- Actual SQLite checkpoints with captured-channel and parent-resume guards.
package.path = "./?.lua;" .. package.path
local helper = require("spec.helpers.annotation_test_store")
local Sync = require("weread.lib.annotation_sync")
local checks, sequence = 0, 0
local function expect(value, label) checks = checks + 1; assert(value, label) end
local function fixture()
    sequence = sequence + 1
    local book = tostring(900000 + sequence)
    local selected = { native = {}, api_key = nil }
    local current, fail_range, failure, calls, response_kind = true, "3-4", "annotation_source/native_expired", {}, "native"
    local client = {
        capture_annotation_access = function() return selected end,
        annotation_access_matches = function(_self, value) return current and value.native == selected.native and value.api_key == selected.api_key end,
        get_chapter_underlines = function(_self, _book, _uid, value)
            expect(value.native == selected.native and value.api_key == selected.api_key, "captured access reaches underline fetch")
            calls[#calls + 1] = "underlines"
            return true, { _source_kind = response_kind, underlines = { { range = "1-2", markText = "a" }, { range = "3-4", markText = "b" } } }
        end,
        build_chapter_review_batches = function(_self, ranges)
            return { { { range = ranges[1] } }, { { range = ranges[2] } } }
        end,
        get_chapter_reviews_batch = function(_self, _book, _uid, batch, value)
            expect(value.native == selected.native and value.api_key == selected.api_key, "captured access reaches thought fetch")
            expect(value.channel == response_kind, "thought batches use pinned first-response channel")
            local marker = batch[1].range; calls[#calls + 1] = marker
            if marker == fail_range then return false, nil, failure end
            return true, { reviews = { { range = marker, pageReviews = { { review = { content = "Synthetic", abstract = marker } } } } } }
        end,
    }
    local store = helper.new()
    return { store = store, client = client, selected = selected, calls = calls, book = book,
        new = function(options)
            local values = { store = store, client = client, book_id = book, chapters = { { chapterUid = "2" } } }
            for key, value in pairs(options or {}) do values[key] = value end
            return Sync:new(values)
        end,
        change = function(values)
            if values.current ~= nil then current = values.current end
            if values.fail_range ~= nil then fail_range = values.fail_range end
            if values.failure then failure = values.failure end
            if values.key then selected.api_key = values.key end
            if values.response_kind then response_kind = values.response_kind end
        end }
end
local function finish(job)
    for _i = 1, 1000 do
        local done, state = job:step()
        if done == nil or done then return done, state end
    end
    error("job did not settle")
end
local f = fixture()
local done, reason = finish(f.new())
expect(done == nil and reason == "annotation_source/native_expired" and #f.calls == 3, "expired second batch is sent once")
expect(f.store:get(f.book, "download", "2").next_batch == 2 and f.store:get(f.book, "batch", "2:1")
    and not f.store:get(f.book, "source", "2"), "partial native batch is durable without publishing incomplete source")
f.change { fail_range = "" }
expect(finish(f.new()) and #f.calls == 4 and f.calls[4] == "3-4", "manual resume requests only remaining batch")
expect(f.store:get(f.book, "source", "2") and f.store:get(f.book, "thought", "2:3-4")
    and not f.store:get(f.book, "download", "2"), "complete source and popup commit atomically")
f.change { current = false }
expect(finish(f.new()) and #f.calls == 4, "offline-ready completed source does not need a fresh network grant")

for _, error_code in ipairs({ "annotation_source/native_expired", "annotation_source/rate_limited", "annotation_source/rejected" }) do
    f = fixture(); f.change { fail_range = "1-2", failure = error_code }
    done, reason = finish(f.new())
    expect(done == nil and reason == error_code and #f.calls == 2, "terminal native failure never consumes three attempts")
    expect(f.store:get(f.book, "download", "2") and not f.store:get(f.book, "source", "2"), "failed native fetch keeps checkpoint")
end
f = fixture(); f.change { fail_range = "1-2", failure = "annotation_source/unavailable" }
expect(not finish(f.new()) and #f.calls == 4, "temporary read failure keeps bounded existing retries")

f = fixture()
local job = f.new { async_network = true }
local state
for _i = 1, 100 do
    done, state = job:step()
    if state and state.network then break end
end
expect(done == false and state and state.network, "network work yields outside matching coroutine")
local success, data, err = state.network()
f.change { current = false }
done, reason = job:step(success, data, err)
expect(done == nil and reason == "annotation_source/session_changed", "parent rejects child response after grant change")
expect(not f.store:get(f.book, "download", "2") and not f.store:get(f.book, "source", "2"), "stale response writes no checkpoint")

f = fixture()
f.store:put(f.book, "download", "2", { source_kind = "gateway", next_batch = 2,
    underlines = { { range = "1-2" }, { range = "3-4" } } }, "2")
f.store:put(f.book, "batch", "2:1", { { range = "1-2", pageReviews = {} } }, "2")
done, reason = finish(f.new())
expect(done == nil and reason == "annotation_source/source_changed" and #f.calls == 0, "resume cannot mix native with saved gateway batches")
expect(f.store:get(f.book, "download", "2").source_kind == "gateway" and f.store:get(f.book, "batch", "2:1"), "channel change preserves previous batches")

f = fixture(); f.change { key = "synthetic-key", response_kind = "gateway", fail_range = "" }
expect(finish(f.new()) and #f.calls == 3, "fresh fallback pins all thought requests to gateway")
f = fixture(); f.change { key = "synthetic-key", response_kind = "gateway", fail_range = "" }
f.store:put(f.book, "download", "2", { source_kind = "gateway", next_batch = 2, revision = "1",
    underlines = { { range = "1-2", markText = "a" }, { range = "3-4", markText = "b" } } }, "2")
f.store:put(f.book, "batch", "2:1", { { range = "1-2", pageReviews = {} } }, "2")
expect(finish(f.new()) and #f.calls == 1 and f.calls[1] == "3-4", "saved gateway batch resumes on gateway while native access is also present")
helper.cleanup()
print("native_annotation_sync_spec: " .. checks .. " checks")
