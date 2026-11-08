package.path = "./?.lua;" .. package.path
local Source = require("weread.lib.source_coordinates")
local checks = 0
local function eq(actual, expected)
    checks = checks + 1
    assert(actual == expected, tostring(actual) .. " ~= " .. tostring(expected))
end
local function build(raw, options)
    local map, err = Source.build(raw, options)
    assert(map, err)
    return map
end
local function locate(map, text, before, after)
    local point, err = map:locate(text, before, after)
    assert(point, err)
    return point
end

-- Golden offsets independently observed from the official Web parser. Ignored
-- tags do not advance a text run; retained tags reset to their original end.
local raw = '<html><body><p>prefix</p><a>Marker</a><p>suffix</p></body></html>'
local map = build(raw)
eq(#map.segments, 3)
eq(map.segments[1][1], 15)
eq(map.segments[2][1], 25)
eq(map.segments[3][1], 41)
eq(map.segments[2][2], "Marker")
local point = locate(map, "prefixMarkersuffix")
eq(point.co, 15)
eq(point.end_co, 47)

map = build('<html><body><p>before<a href="a > b">outer<q>inner</q>tail</a>after<wbr/>last</p></body></html>')
eq(#map.segments, 1)
eq(map.segments[1][2], "beforeouterinnertailafterlast")
eq(locate(map, "outerinnertailafter").co, 21)

map = build('<html><body><p>before<!--kept comment-->after<a/>tail</p></body></html>')
eq(map.segments[1][2], "beforeaftertail")
eq(locate(map, "beforeaftertail").co, 15)
eq(locate(map, "beforeaftertail").end_co, 30)

map = build('<html><body><p>left > right <3 tail</p></body></html>')
eq(map.segments[1][2], "left &gt; right &lt;3 tail")
eq(locate(map, "left > right <3 tail").end_co, 41)

raw = '\239\187\191<html><body><p>abcdefghijklm<a>甲😀乙&amp;丙0123456789</a>tail</p></body></html>'
map = build(raw)
point = locate(map, "甲😀乙&丙0123456789")
eq(point.co, 29)
eq(point.end_co, 49)
local anchor = assert(map:anchor(point.co))
eq(anchor.point_offset, 13)
eq(anchor.point_unit, "unicode_scalars")
local reverse, err = map:anchor(point.co + 2)
eq(reverse, nil)
eq(err, "source_coordinates/inside_entity_or_scalar")

-- Sparse indexing crosses Unicode/entity boundaries while avoiding a table
-- for every rune in a long chapter. Anchors near the end retain source units.
local prefix = string.rep("甲 &amp;😀 ", 2000)
raw = '<html><body><p>' .. prefix .. 'unique ending anchor for a long chapter</p></body></html>'
map = build(raw)
point = locate(map, "unique ending anchor for a long chapter")
eq(point.co, 15 + 2000 * 10)
eq(#map.points < 100, true)
eq(assert(map:anchor(point.co)).co, point.co)
eq(assert(map:anchor(point.end_co)).point_offset > 0, true)

-- Repeated/overlapping phrases need real context; no nearest-match heuristic.
map = build('<html><body><p>left same repeated content phrase one</p><p>right same repeated content phrase two</p></body></html>')
point, err = map:locate("same repeated content phrase")
eq(point, nil)
eq(err, "source_coordinates/anchor_ambiguous")
eq(locate(map, "same repeated content phrase", "right", "two").co,
    ('<html><body><p>left same repeated content phrase one</p><p>right '):len())
map = build('<html><body><p>' .. string.rep("x", 40) .. '</p></body></html>')
point, err = map:locate(string.rep("x", 12))
eq(point, nil)
eq(err, "source_coordinates/anchor_ambiguous")

-- Escaping can make a run overlap the next retained-tag coordinate interval.
-- One co can then denote two places: the reverse direction must refuse it.
map = build('<html><body><p>' .. string.rep(">", 20) .. '</p><p>abcdefghijklmnop</p></body></html>')
reverse, err = map:anchor(43)
eq(reverse, nil)
eq(err, "source_coordinates/offset_ambiguous")

-- One entity may produce several visible scalars but has only one co interval.
map = build('<html><body><p>prefix&pair;ordinary ending text</p></body></html>', {
    decode_entity = function(entity) eq(entity, "&pair;") return "XY" end,
})
point, err = map:locate("Yordinary ending text")
eq(point, nil)
eq(err, "source_coordinates/inside_entity_or_scalar")
eq(locate(map, "XYordinary ending text").co, 21)

for _, value in ipairs({ -1, 0.5, math.huge, "42" }) do
    reverse, err = map:anchor(value)
    eq(reverse, nil)
    eq(err, "source_coordinates/invalid_offset")
end
point, err = map:locate("short")
eq(point, nil)
eq(err, "source_coordinates/anchor_too_short")
point, err = map:locate(string.rep("a", Source.MAX_ANCHOR_BYTES + 1))
eq(point, nil)
eq(err, "source_coordinates/invalid_anchor")

for _, value in ipairs({
    '<p>no body</p>', '<BODY>upper</BODY>', '<body>incomplete', '<body>one</body><body>two</body>',
    '<body><![CDATA[text]]></body>', '<body><?processing instruction?></body>',
    '<body><script>"<p>markup</p>"</script></body>', '<body>bad\0control</body>',
    '<body>bad\237\160\128surrogate</body>', '<body>&unterminated</body>', '<body>&#0;</body>', '<body>&#xFFFF;</body>',
    '<body><p title="broken>text</p></body>', string.rep("a", Source.MAX_BYTES + 1),
}) do
    local invalid, reason = Source.build(value)
    eq(invalid, nil)
    eq(type(reason) == "string" and reason:match("^source_coordinates/[%a_]+$") ~= nil, true)
end

print("source_coordinates_spec: " .. checks .. " checks")
