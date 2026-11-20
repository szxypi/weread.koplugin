local trim = require("weread.lib.search_query").trim
local spaces = {
    "\t", "\n", "\v", "\f", "\r", " ", "\194\133", "\194\160", "\225\154\128",
    "\226\128\128", "\226\128\129", "\226\128\130", "\226\128\131", "\226\128\132",
    "\226\128\133", "\226\128\134", "\226\128\135", "\226\128\136", "\226\128\137",
    "\226\128\138", "\226\128\168", "\226\128\169", "\226\128\175", "\226\129\159", "\227\128\128",
}
for _, space in ipairs(spaces) do
    assert(trim(space .. "书 名" .. space) == "书 名", "edge whitespace not trimmed")
    assert(trim(space) == "", "whitespace-only query not cleared")
    assert(trim("书" .. space .. "名") == "书" .. space .. "名", "interior whitespace changed")
end
assert(trim(" \227\128\128\194\160关键词\t\227\128\128") == "关键词", "mixed whitespace not trimmed")
assert(trim("\255\227\128\128") == "\255", "malformed byte handling changed")
assert(trim("\227\128") == "\227\128", "partial Unicode character changed")
assert(trim(nil) == "" and trim(42) == "", "non-string query handling changed")
print("search_query_spec: Unicode whitespace and byte preservation verified")
