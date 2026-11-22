-- Full local TOC and transient per-row download selection. Mapping is saved
-- by the controller; toggling a row never performs network or database work.
local Chapters = require("weread.lib.annotation_chapters")
local Selection = {}
Selection.__index = Selection

function Selection:new(chapters, ranges, toc, current_index, state_of)
    local model = setmetatable({ chapters = chapters, nodes = {}, by_uid = {}, catalog_index = {}, count = 0 }, self)
    for index, chapter in ipairs(chapters) do model.catalog_index[Chapters.uid(chapter)] = index end
    local by_toc, by_point = {}, {}
    for index, entry in ipairs(toc or {}) do
        if entry.xpointer and not by_point[entry.xpointer] then by_point[entry.xpointer] = index end
    end
    for _, chapter in ipairs(chapters) do
        local range = ranges and ranges[Chapters.uid(chapter)]
        local index = range and (range.toc_index or by_point[range.start_xpointer])
        if index then by_toc[index] = chapter end
    end
    local stack = {}
    local function add(title, depth, chapter, index, point)
        depth = math.max(1, tonumber(depth) or 1)
        while #stack > 0 and stack[#stack].source_depth >= depth do table.remove(stack) end
        local parent = stack[#stack]
        local node = { title = title or "", chapter = chapter,
            depth = parent and parent.depth + 1 or 0, source_depth = depth,
            toc_index = index, xpointer = point, index = #model.nodes + 1,
            selectable = chapter ~= nil,
            state = chapter and state_of and state_of(chapter)
                or chapter and "ready_to_fetch" or "unlinked" }
        if parent then parent.branch = true end
        stack[#stack + 1], model.nodes[#model.nodes + 1] = node, node
        if chapter then model.by_uid[Chapters.uid(chapter)] = node end
    end
    if toc and #toc > 0 then
        for index, entry in ipairs(toc) do
            add(entry.title, entry.depth, by_toc[index], index,
                by_point[entry.xpointer] == index and entry.xpointer or nil)
        end
    else
        for _, chapter in ipairs(chapters) do add(chapter.title, chapter.level, chapter) end
    end
    local current = type(current_index)=='number' and current_index%1==0 and chapters[current_index] or nil
    model.current = current and model.by_uid[Chapters.uid(current)]
    if type(current_index)=='number' and current_index%1==0 and current_index>=1
        and current_index<=#chapters and model.current then
        model.current_index=current_index
    end
    return model
end

function Selection:chapterIndex(node)
    local uid = node and node.chapter and Chapters.uid(node.chapter)
    return uid and self.by_uid[uid] == node and self.catalog_index[uid] or nil
end

-- Endpoints must both be linked; entries between them follow WeRead catalog
-- order, not the possibly different order of the local table of contents.
function Selection:addRange(first, last)
    if type(first) ~= 'number' or first % 1 ~= 0 or type(last) ~= 'number' or last % 1 ~= 0
        or first < 1 or last < 1 or first > #self.chapters or last > #self.chapters then return 0 end
    local start_node = self.by_uid[Chapters.uid(self.chapters[first])]
    local end_node = self.by_uid[Chapters.uid(self.chapters[last])]
    if not start_node or not start_node.selectable or not end_node or not end_node.selectable then return 0 end
    if first > last then first, last = last, first end
    local added = 0
    for index = first, last do
        local node = self.by_uid[Chapters.uid(self.chapters[index])]
        if node and node.selectable and not node.selected then self:toggle(node); added = added + 1 end
    end
    return added
end

-- Add a bounded window in catalog order; leave unrelated manual selections
-- intact and never select an unlinked local TOC entry.
function Selection:addCurrentWindow()
    if not self.current_index or not self.current or not self.current.selectable then return 0 end
    local added=0
    for index=self.current_index,math.min(#self.chapters,self.current_index+9) do
        local node=self.by_uid[Chapters.uid(self.chapters[index])]
        if node and node.selectable and not node.selected then
            self:toggle(node);added=added+1
        end
    end
    return added
end

function Selection:visible()
    return self.nodes
end

function Selection:toggle(node)
    if not node.selectable then return end
    node.selected = not node.selected
    self.count = self.count + (node.selected and 1 or -1)
end

function Selection:clear()
    for _, node in ipairs(self.nodes) do node.selected = false end
    self.count = 0
end

function Selection:selection()
    local result = {}
    for _, chapter in ipairs(self.chapters) do
        local node = self.by_uid[Chapters.uid(chapter)]
        if node and node.selected then result[#result + 1] = chapter end
    end
    return result
end

return Selection
