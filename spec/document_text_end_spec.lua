package.path = "./?.lua;" .. package.path
local Chapters = require("weread.lib.annotation_chapters")
local checks = 0
local function expect(value, label) checks = checks + 1; assert(value, label) end
local prefix = "/body/DocFragment[1]/body/p[1]/text()"
local function fixture(text)
    return {
        getPageCount = function() return 3 end,
        getPageXPointer = function() return prefix .. ".3" end,
        getNextVisibleWordEnd = function() return nil end,
        getPrevVisibleChar = function(_self, point) return prefix .. "." .. (tonumber(point:match("%.(%d+)$"))-1) end,
        getNextVisibleChar = function(_self, point)
            local n = tonumber(point:match("%.(%d+)$"))
            return n < 4 and prefix .. "." .. (n+1) or nil
        end,
        getTextFromXPointer = function() return text or "正文。！？" end,
        getNormalizedXPointer = function(_self, point) return point end,
    }
end
expect(Chapters.documentEnd(fixture()) == prefix .. ".5", "punctuation-only last page lost the final text boundary")
local End = require("weread.lib.document_text_end")
expect(End.last(fixture("甲😀乙。")) == prefix .. ".4", "native offsets must count Unicode scalars")
local broken = fixture(); broken.getNextVisibleChar = function(_self, point) return point end
expect(End.last(broken) == nil, "non-progressing native walks must stop")
broken = fixture(); broken.getNextVisibleChar = function() error("private native details") end
local value, reason = End.last(broken)
expect(value == nil and reason == "document_text_end/unavailable", "native exceptions leaked")
broken = fixture(); broken.getTextFromXPointer = function() return string.char(255) end
expect(End.last(broken) == nil, "invalid native text was accepted")
expect(End.last(fixture(), { root = "/body/DocFragment[2]" }) == nil, "the prior fragment leaked into an empty final chapter")
expect(End.node(fixture(), prefix .. ".2", { root = "/body/DocFragment[1]" }) == prefix .. ".5")
local old = { getPageCount = function() return 1 end, getPageXPointer = function() return "0" end,
    getNextVisibleWordEnd = function(_self, point) if point == "0" then return "10" end end }
expect(Chapters.documentEnd(old) == "10", "legacy native API support changed")
print("document_text_end_spec: " .. checks .. " checks")
