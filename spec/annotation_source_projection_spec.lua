package.path = "./?.lua;" .. package.path
local helper = require("spec.helpers.annotation_test_store")
package.preload.util = function() return { htmlEntitiesToUtf8 = function(value) return value end } end
local External = require("weread.lib.external_annotations")
local Sync = require("weread.lib.annotation_sync")
local json = require("json")
local checks = 0
local function expect(value, label) checks = checks + 1; assert(value, label) end
local doc = {
    findAllText = function(_self, quote)
        if quote == "alpha" then return { { start = "10", ["end"] = "15" } } end
        return {}
    end,
    compareXPointers = function(_self, a, b) return tonumber(a) < tonumber(b) and 1 or tonumber(a) > tonumber(b) and -1 or 0 end,
}
local source = { book_id = "book", chapter_uid = "1", revision = "1",
    underlines = { { range = "3-8", markText = "old edition quote" } }, reviews = {} }
local records = External.locate(doc, { source }, { chapter_quotes = { ["1"] = { ["3-8"] = "alpha" } } })
expect(#records == 1 and records[1].text == "alpha", "verified local source range must outrank a stale cloud quote")
expect(source.underlines[1].markText == "old edition quote", "projection rewrote fetched source data")
records = External.locate(doc, { source }, { chapter_quotes = { ["other"] = { ["3-8"] = "alpha" } } })
expect(#records == 0, "a different chapter's quote leaked into this chapter")
local fallback = { book_id = "book", chapter_uid = "1", underlines = { { range = "3-8", markText = "alpha" } }, reviews = {} }
records = External.locate(doc, { fallback }, { chapter_quotes = { ["1"] = { ["3-8"] = "transformed footnote text" } } })
expect(#records == 1 and records[1].text == "alpha", "the bounded full-quote fallback was lost")
records = External.locate(doc, { fallback }, { chapter_quotes = { ["1"] = { ["3-8"] = "  " } } })
expect(#records == 1 and records[1].text == "alpha", "whitespace-only source ranges blocked the legacy quote")
records = External.locate(doc, { fallback }, {
    chapter_quotes = { ["1"] = { ["3-8"] = "transformed footnote text" } },
    chapter_ranges = { ["1"] = { start_xpointer = "0", end_xpointer = "9" } },
})
expect(#records == 0, "source quote fallback crossed the chapter boundary")
local repeated = { findAllText = function() return { { start = "10", ["end"] = "15" }, { start = "20", ["end"] = "25" } } end,
    compareXPointers = doc.compareXPointers }
records = External.locate(repeated, { { book_id = "book", chapter_uid = "1", reviews = {},
    underlines = { { range = "3-8", markText = "alpha" }, { range = "11-16", markText = "alpha" } } } }, {
    chapter_quotes = { ["1"] = { ["3-8"] = "transformed text", ["11-16"] = "transformed text" } },
})
expect(#records == 2 and records[1].pos0 == "10" and records[2].pos0 == "20", "fallback reused an earlier identical quote")
local store = helper.new()
store:put("book", "source", "1", source, "1")
store:put("book", "source_status", "1", { revision = "1", total = 1 }, "1")
local range_key = require("weread.lib.annotation_chapters").rangeKey(nil)
store:put("book", "projection", "cached:1", { revision = "1", matcher_version = 3, range_key = range_key,
    stats = { total = 1, located = 1 }, records = { { pos0 = "30", pos1 = "35", text = "old edition quote" } } }, "1")
store:put("book", "status", "cached:1", { revision = "1", matcher_version = 3, range_key = range_key,
    stats = { total = 1, located = 1 } }, "1")
store:put("book", "matching", "cached:1", { revision = "1", matcher_version = 3, range_key = range_key,
    next_index = 2, records = { { pos0 = "30", pos1 = "35", text = "old edition quote" } },
    stats = { total = 1, located = 1 } }, "1")
store:put("book", "thought", "1:3-8", { { content = "saved thought" } }, "1")
local before = json.encode(store:get("book", "source", "1"))
local thoughts_before = json.encode(store:list("book", "thought"))
local reads = 0
local function finish(job)
    for _i = 1, 100 do
        local done, reason = job:step()
        if done == nil then error(reason) end
        if done then return end
    end
    error("job did not finish")
end
local function job(key)
    return Sync:new { store = store, client = {}, book_id = "book", chapters = { { chapterUid = "1" } },
        document = doc, document_key = key, offline = true,
        get_document_source = function(chapter)
            expect(chapter.chapterUid == "1", "document source requested for a different chapter")
            reads = reads + 1
            return { raw = "<p>alpha</p>", format = "web_xhtml" }
        end }
end
finish(job("cached"))
local projection = assert(store:get("book", "projection", "cached:1"))
expect(projection.stats.located == 1 and projection.records[1].text == "alpha", "cached annotations did not use the current document source")
expect(projection.matcher_version == External.MATCHER_VERSION and projection.records[1].pos0 == "10", "version 3 projection/checkpoint was reused")
expect(json.encode(store:get("book", "source", "1")) == before, "offline reprojection changed shared cloud data")
expect(json.encode(store:list("book", "thought")) == thoughts_before, "offline reprojection changed saved thoughts")
finish(job("cached")); expect(reads == 1, "a valid saved projection reparsed its document source")
print("annotation_source_projection_spec: " .. checks .. " checks")
