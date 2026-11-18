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

package.loaded["ffi/utf8proc"] = previous
package.loaded["weread.lib.shelf_search"] = nil
print(("shelf_search_spec: %d checks"):format(checks))
