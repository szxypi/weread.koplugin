-- The independent DOM check needs a visible text point, rather than CRE's
-- structural page origin. Never advance into text outside this viewport.
return function(document, location, height)
    local point = location.xpointer
    if point:find('/text()', 1, true) then return point end
    local Geometry = require('weread.lib.reader_position')
    local Dom = require('weread.lib.source_dom')
    local frame = Geometry.snapshot(document, location.view_mode, height)
    local next_point = document:getNextVisibleChar(point)
    assert(type(next_point) == 'string' and next_point:find('/text()', 1, true)
        and Geometry.contains_anchor(document, frame, next_point), 'no visible native text')
    local previous = document:getPrevVisibleChar(next_point)
    if previous and previous:find('/text()', 1, true) and Dom.fragment(previous) == Dom.fragment(next_point)
        and document.compareXPointers and document:compareXPointers(point, previous) == 1
        and Geometry.contains_anchor(document, frame, previous) then return previous end
    return next_point
end
