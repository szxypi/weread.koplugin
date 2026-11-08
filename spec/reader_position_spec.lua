package.path = "./?.lua;./?/init.lua;" .. package.path
local Position = require("weread.lib.reader_position")
local checks = 0
local function eq(got, expected, label)
    checks = checks + 1
    assert(got == expected, label .. ": " .. tostring(got) .. " ~= " .. tostring(expected))
end
local function near(got, expected, label)
    checks = checks + 1
    assert(math.abs(got - expected) < 1e-9, label)
end
local doc = {
    getCurrentPage = function() return 157 end, getPageCount = function() return 400 end,
    getCurrentPos = function() return 12345 end, info = { doc_height = 100000 },
}
local footer = { percent_finished = 0.99 }
eq(Position.fraction(doc, footer, "page"), 157 / 400, "live page beats delayed footer")
eq(Position.fraction(doc, footer, "scroll"), 12345 / 100000, "scroll uses live engine position")
eq(Position.fraction(doc, footer), 157 / 400, "unspecified mode retains page compatibility")
doc.getCurrentPage = function() error("not supported") end
eq(Position.fraction(doc, footer, "page"), 0.12345, "failed page API falls back to engine position")
doc.getCurrentPos = function() return 0 end
eq(Position.fraction(doc, footer, "scroll"), 0, "zero is a valid live scroll position")
doc.info.doc_height = 0
eq(Position.fraction(doc, footer, "scroll"), 0.99, "invalid document geometry uses footer fallback")
eq(Position.fraction(nil, footer), nil, "no document cannot reuse a stale footer")
eq(Position.fraction({}, { percent_finished = 45 }), 0.45, "legacy integer footer percent supported")
eq(Position.fraction({}, { percent_finished = 0/0 }), nil, "invalid cached value rejected")
doc.getCurrentPage = function() return math.huge end
doc.getCurrentPos = nil
eq(Position.fraction(doc), nil, "nonfinite live values rejected")

local percents = {}
local ui = { rolling = { onGotoPercent = function(_self, percent)
    percents[#percents + 1] = percent
    return true
end } }
eq(Position.goto_fraction(ui, 0.503125), true, "fractional jump accepted")
near(percents[#percents], 50.3125, "fractional percentage is not rounded to an integer")
eq(Position.goto_fraction(ui, -0.1), true, "negative fraction clipped")
eq(percents[#percents], 0, "lower bound")
eq(Position.goto_fraction(ui, 1.1), true, "overshoot clipped")
eq(percents[#percents], 100, "upper bound")
local count = #percents
for _, invalid in ipairs({ "bad", math.huge, -math.huge, 0/0 }) do
    eq(Position.goto_fraction(ui, invalid), false, "invalid target rejected")
end
eq(#percents, count, "invalid target never navigates")
eq(Position.goto_fraction(nil, 0.5), false, "missing reader rejected")
ui.rolling.onGotoPercent = function() return false end
eq(Position.goto_fraction(ui, 0.5), false, "native rejection is not treated as success")
ui.rolling.onGotoPercent = function() error("rejected") end
eq(Position.goto_fraction(ui, 0.5), false, "native error propagated")
package.preload["ui/event"] = function()
    return { new = function(_self, name, value) return { name = name, value = value } end }
end
eq(Position.goto_fraction({ handleEvent = function(_self, event)
    eq(event.name, "GotoPercent", "native event fallback")
    near(event.value, 50.3125, "event preserves fractional precision")
    return true
end }, 0.503125), true, "event-only reader supported")
eq(Position.goto_fraction({ handleEvent = function() end }, 0.5), false, "unhandled native event is not success")
print("reader_position_spec: " .. checks .. " checks")
