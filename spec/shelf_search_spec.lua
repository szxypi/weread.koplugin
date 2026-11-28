local previous = package.loaded["ffi/utf8proc"]
local calls = 0
package.loaded["ffi/utf8proc"] = {
    count = function(value) return #value, not value:find("\255", 1, true) end,
    lowercase = function(value)
        calls = calls + 1
        if value == "É" then return "é" end
        if value == "ＣＡＦＥ" then return "cafe" end
        if value == "\226\128\139" then return "" end
        return string.lower(value)
    end,
}
package.loaded["weread.lib.shelf_search"] = nil
local Search = require("weread.lib.shelf_search")
local checks = 0
local function expect(value, message) checks = checks + 1; assert(value, message) end

expect(Search.matches({title="café"}, Search.prepare("É")), "Unicode case mapping did not match title")
expect(Search.matches({author="cafe"}, Search.prepare("ＣＡＦＥ")), "compatibility form did not match author")
expect(Search.matches({bookId=123456}, Search.prepare("345")), "numeric book identifier was skipped")
expect(Search.matches({book_id="CB_123"}, Search.prepare("cb_")), "alternate identifier was skipped")
expect(not Search.matches({title="no match"}, Search.prepare("%")), "query was interpreted as a pattern")
expect(not Search.matches({title="anything"}, Search.prepare("\226\128\139")), "ignorable-only query matched all")
expect(not Search.matches({title="anything"}, Search.prepare("\255")), "invalid query matched unrelated title")
local before = calls
expect(Search.matches({title="A\0B"}, Search.prepare("A\0B")), "NUL fallback did not match safely")
expect(calls == before, "NUL was passed to the Unicode normalizer")
expect(Search.matches({}, nil) and not Search.matches(nil, "x"), "empty or malformed input handling changed")
expect(Search.contains("café",Search.prepare("É")),"shared text matching lost Unicode case mapping")
expect(not Search.contains(nil,Search.prepare("x")) and not Search.contains("text",nil),"shared text matching accepted invalid input")
local book={title="三体 黑暗森林",author="刘慈欣",bookId=123456}
for _, query in ipairs({"三体 刘慈欣", "刘慈欣　森林", "123456\194\160刘慈欣", "森林 三体"}) do
    local needle=Search.prepare(query)
    expect(Search.matches(book,needle,Search.terms(needle)),"multiword title/author/id query failed")
end
expect(not Search.matches(book,Search.prepare("三体 不存在")),"missing keyword matched")
expect(not Search.matches({title="三体",author="刘慈欣"},Search.prepare("三体 %")),"keyword treated as a pattern")
expect(Search.matches({title="one two"},Search.prepare("one two")),"exact phrase stopped matching")
expect(not Search.matches({title="one",author="other"},Search.prepare("one two")),"incomplete cross-field query matched")

local normalize = Search.cached_fold()
local offset, folded = Search.find("ＣＡＦＥ", "afe", normalize)
expect(offset == 2 and folded == "cafe", "the match offset did not identify the folded text")
local first_query = Search.prepare("三体 刘慈欣")
local next_query = Search.prepare("123456 森林")
before = calls
expect(Search.matches(book, first_query, nil, normalize) and calls == before + 3,
    "cold cache changed how title, author and identifier were searched")
before = calls
expect(Search.matches(book, next_query, nil, normalize) and calls == before,
    "another query did not reuse the same display fields")
book.title = "新版标题"
expect(not Search.matches(book, next_query, nil, normalize) and calls == before + 1,
    "editing a title returned a stale search match")
expect(normalize("A\0B") == "a\0b" and normalize("\255") == "\255",
    "the cache changed matching for NUL or invalid UTF-8")
local oversized = string.rep("A", 140 * 1024)
before = calls
normalize(oversized)
normalize(oversized)
expect(calls == before + 2, "one large value exceeded the cache byte limit")
local limited = Search.cached_fold()
for i=1,4096 do limited("fixture" .. i) end
before = calls
limited("overflow")
limited("overflow")
expect(limited("fixture1") == "fixture1" and calls == before + 2,
    "the entry limit discarded useful folds or kept growing")

package.loaded["ffi/utf8proc"] = previous
package.loaded["weread.lib.shelf_search"] = nil
print(("shelf_search_spec: %d checks"):format(checks))
