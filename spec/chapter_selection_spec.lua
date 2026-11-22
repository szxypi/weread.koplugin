package.path = "./?.lua;" .. package.path
local Selection = require("weread.lib.chapter_selection")
local chapters = {
    { chapterUid = "a", title = "Remote A", level = 1 },
    { chapterUid = "b", title = "Remote B", level = 1 },
    { chapterUid = "c", title = "Remote C", level = 1 },
}
local toc = {
    { title = "Part I", depth = 1, xpointer = "p" },
    { title = "Local A", depth = 2, xpointer = "a" },
    { title = "Section", depth = 2, xpointer = "s" },
    { title = "Local B", depth = 3, xpointer = "b" },
    { title = "Unused", depth = 1, xpointer = "u" },
    { title = "Local C", depth = 1, xpointer = "c" },
}
local ranges = { a = { toc_index = 2 }, b = { toc_index = 4 }, c = { toc_index = 6 } }
local model = Selection:new(chapters, ranges, toc, 2, function(chapter)
    if chapter.chapterUid == "a" then return "matched" end
    if chapter.chapterUid == "b" then return "ready_to_match" end
    return "ready_to_fetch"
end)
assert(#model.nodes == #toc and #model:visible() == #toc and model.count == 0)
assert(model.current == model.by_uid.b and model.by_uid.b.depth == 2
    and model.by_uid.b.title == "Local B", "local hierarchy/current chapter lost")
model:toggle(model.nodes[1]); assert(model.count == 0, "unmatched parent was selected")
assert(model.by_uid.a.state == "matched"
    and model.by_uid.b.state == "ready_to_match"
    and model.by_uid.c.state == "ready_to_fetch"
    and model.nodes[1].state == "unlinked"
    and model.by_uid.a.selectable and not model.by_uid.a.selected)
model:toggle(model.by_uid.b); model:toggle(model.by_uid.a)
local selected = model:selection()
assert(#selected == 2 and selected[1] == chapters[1] and selected[2] == chapters[2])
model:toggle(model.by_uid.b); assert(model.count == 1 and model.by_uid.a.selected)
model:clear(); assert(model.count == 0)
local empty = Selection:new({}, {}, toc)
assert(#empty.nodes == #toc and empty.nodes[1].xpointer == "p",
    "zero automatic matches must still allow manual chapter selection")
local duplicates = Selection:new({}, {}, { toc[1], toc[1], { title = "No anchor" } })
assert(duplicates.nodes[1].xpointer and not duplicates.nodes[2].xpointer and not duplicates.nodes[3].xpointer)
local window_chapters,window_toc,window_ranges={},{},{}
for index=1,15 do
    local uid=tostring(index)
    window_chapters[index]={chapterUid=uid,title='Remote '..uid}
    window_toc[index]={title='Local '..uid,xpointer=uid}
    if index~=5 then window_ranges[uid]={toc_index=index} end
end
local window=Selection:new(window_chapters,window_ranges,window_toc,3)
window:toggle(window.by_uid['1']);window:toggle(window.by_uid['15'])
assert(window:addCurrentWindow()==9 and window.count==11 and window.by_uid['1'].selected
    and window.by_uid['15'].selected and not window.by_uid['2'].selected
    and not window.by_uid['5'] and window.by_uid['12'].selected and not window.by_uid['13'].selected,
    'current window did not preserve manual selection or skipped an unmapped chapter incorrectly')
assert(window:addCurrentWindow()==0 and window.count==11,'repeating a window changed existing selections')
local near_end=Selection:new(window_chapters,window_ranges,window_toc,14)
assert(near_end:addCurrentWindow()==2 and near_end.count==2,'window extended past the catalog end')
local unknown=Selection:new(window_chapters,window_ranges,window_toc,nil)
assert(not unknown.current and unknown:addCurrentWindow()==0 and unknown.count==0,
    'unknown current chapter was assumed or selected an arbitrary range')
local unmapped=Selection:new(window_chapters,window_ranges,window_toc,5)
assert(unmapped:addCurrentWindow()==0 and unmapped.count==0,'unmapped current chapter selected an arbitrary range')
local interval=Selection:new(window_chapters,window_ranges,window_toc,nil)
interval:toggle(interval.by_uid['1']);interval:toggle(interval.by_uid['15'])
assert(interval:chapterIndex(interval.by_uid['3'])==3 and not interval:chapterIndex(interval.nodes[5]))
assert(interval:addRange(9,3)==6 and interval.count==8 and interval.by_uid['1'].selected
    and interval.by_uid['3'].selected and interval.by_uid['9'].selected and interval.by_uid['15'].selected
    and not interval.by_uid['2'].selected and not interval.by_uid['5'],
    'reverse range failed to preserve previous selections or skip an unmapped chapter')
assert(interval:addRange(3,9)==0 and interval:addRange(3,5)==0 and interval:addRange(0,3)==0
    and interval:addRange(3,3.5)==0 and interval.count==8,
    'repeat or invalid range modified the selection')
assert(interval:addRange(11,11)==1 and interval.by_uid['11'].selected, 'single-chapter range failed')
local reordered=Selection:new(chapters,{a={toc_index=6},b={toc_index=2},c={toc_index=4}},toc,nil)
assert(reordered:addRange(reordered:chapterIndex(reordered.by_uid.a),reordered:chapterIndex(reordered.by_uid.b))==2
    and reordered.by_uid.a.selected and reordered.by_uid.b.selected and not reordered.by_uid.c.selected,
    'range used local table-of-contents order instead of WeRead catalog order')
local large = {}
for index = 1, 10000 do large[index] = { chapterUid = tostring(index), level = index == 1 and 1 or 2 } end
local many = Selection:new(large, {}, nil, 1, function() return "matched" end)
assert(#many:visible() == 10000 and many.count == 0)
many:toggle(many.nodes[1]); assert(many.count == 1, "parent checkbox selected descendants")
many:toggle(many.nodes[5000]); assert(many.count == 2 and #many:selection() == 2)
assert(many:addRange(1,10000)==9998 and many.count==10000 and #many:selection()==10000,
    "large catalog range omitted chapters or toggled existing choices")
print("chapter_selection_spec: full TOC, independent selection, refetch and 10000 chapters passed")
