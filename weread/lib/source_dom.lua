-- Chapter-scoped source coordinates <-> native DOM anchors. No networking,
-- navigation, whole-book search, mutable catalog mapping or settings writes.
local Coordinates = require('weread.lib.source_coordinates')
local Source = require('weread.lib.position_source')
local Identity = require('weread.lib.book_file_identity')
local M = { MAX_TEXT_BYTES = 8 * 1024 * 1024, CHECKPOINT_INTERVAL = 256, MAX_EDGE_STEPS = 65536 }
local Index = {}
Index.__index = Index
local function fail(reason) error('source_dom/' .. reason, 0) end
local function protected(task)
    local ok, value = pcall(task)
    if ok then return value end
    return nil, type(value) == 'string' and value:match('^source_dom/[a-z_]+$') and value or 'source_dom/native_failure'
end

-- Same Unicode scalar and whitespace policy as source_coordinates schema 1.
-- Keep literal bracketed numbers and BOM; annotation-specific cleanup would
-- silently move source positions around original text such as "[36]".
local function scalar(text, at)
    local a,b,c,d = text:byte(at, at + 3)
    if not a then fail('invalid_utf8') end
    if a < 128 then return a, 1 end
    local function tail(n) return n and n >= 128 and n <= 191 end
    if a >= 194 and a <= 223 and tail(b) then return (a-192)*64+b-128,2 end
    if a >= 224 and a <= 239 and tail(b) and tail(c) and (a ~= 224 or b >= 160) and (a ~= 237 or b < 160) then
        return (a-224)*4096+(b-128)*64+c-128,3
    end
    if a >= 240 and a <= 244 and tail(b) and tail(c) and tail(d) and (a ~= 240 or b >= 144) and (a ~= 244 or b <= 143) then
        return (a-240)*262144+(b-128)*4096+(c-128)*64+d-128,4
    end
    fail('invalid_utf8')
end
local function whitespace(cp)
    return (cp >= 9 and cp <= 13) or (cp >= 28 and cp <= 32) or cp == 133 or cp == 160 or cp == 5760
        or (cp >= 8192 and cp <= 8202) or cp == 8232 or cp == 8233 or cp == 8239 or cp == 8287 or cp == 12288
end
local function normalize(text, yield)
    if type(text) ~= 'string' or #text > M.MAX_TEXT_BYTES then fail('text_limit') end
    local chunks, pieces, at, first, count = {}, {}, 1, 1, 0
    local function append(last)
        if first <= last then pieces[#pieces+1] = text:sub(first,last) end
        if #pieces >= 256 then chunks[#chunks+1],pieces = table.concat(pieces),{} end
    end
    local next_yield = 16384
    while at <= #text do
        local cp, width = scalar(text,at)
        if whitespace(cp) then append(at-1); first = at+width else count=count+1 end
        at=at+width
        if at >= next_yield then
            if yield then yield() end
            next_yield=at+16384
        end
    end
    append(#text)
    chunks[#chunks+1] = table.concat(pieces)
    return table.concat(chunks),count
end
function M.normalize(text) return protected(function() return normalize(text) end) end
local function byte_after(text, count)
    if type(count) ~= 'number' or count < 0 or count % 1 ~= 0 then fail('invalid_point') end
    local at = 1
    for _i = 1,count do local _,width=scalar(text,at); at=at+width end
    return at
end
local function attributes(raw)
    local fields = {}
    for key, _quote, value in raw:gmatch('([%w_:%-]+)%s*=%s*([\'"])(.-)%2') do
        if fields[key] then fail('ambiguous_attributes') end
        fields[key] = value
    end
    return fields
end
local function fragment(xp)
    if type(xp) ~= 'string' then return nil end
    return xp:match('^(/body/DocFragment%[%d+%])') or xp:match('^(/body/DocFragment)[/%.]')
        or (xp == '/body/DocFragment' and xp or nil)
end
local function clear(document)
    if type(document.clearSelection) == 'function' then pcall(document.clearSelection,document) end
end
function M.fragment(xpointer) return fragment(xpointer) end

-- An empty range serialized with its ancestors gives the actual Source
-- attribute without copying an entire chapter into the UI event loop.
function M.member(document, xpointer)
    return protected(function()
        local xp = document:getNormalizedXPointer(xpointer)
        local root = fragment(xp)
        if not root then fail('chapter_unavailable') end
        local html = document:getHTMLFromXPointers(xp, xp, 0, true)
        if type(html) ~= 'string' or #html > 8192 then fail('text_limit') end
        local header = html:match('<DocFragment%s+([^>]+)>')
        local path = header and attributes(header).Source
        if not path then fail('chapter_unavailable') end
        return { root = root, render_path = path, xpointer = xp }
    end)
end
function Index:_check()
    if self.invalid then fail(self.invalid) end
    if self.options.is_current then
        local ok,current=pcall(self.options.is_current)
        if not ok or current ~= true then self.invalid='cancelled'; fail('cancelled') end
    end
    local current = Identity.read_document(self.document,self.book_id)
    if self.file_id and current.file_id ~= self.file_id then self.invalid='file_changed'; fail('file_changed') end
end
function Index:_yield()
    self:_check()
    if self.options.yield then self.options.yield() end
    self:_check()
end
function Index:_extract(first,last)
    self:_check()
    local ok,text = pcall(self.document.getTextFromXPointers,self.document,first,last)
    clear(self.document)
    self:_check()
    if not ok or type(text) ~= 'string' then fail('text_unavailable') end
    return text
end

local function spine(document, path)
    local opf = document:getDocumentFileContent('OEBPS/content.opf')
    if type(opf) ~= 'string' or #opf > M.MAX_TEXT_BYTES then fail('spine_unavailable') end
    local manifest = opf:match('<manifest%s*>(.-)</manifest>')
    local refs = opf:match('<spine[^>]*>(.-)</spine>')
    if not manifest or not refs then fail('spine_unavailable') end
    local items = {}
    for attrs in manifest:gmatch('<item%s+([^>]+)>') do
        local item = attributes(attrs)
        if not item.id or not item.href or items[item.id] then fail('spine_ambiguous') end
        items[item.id] = 'OEBPS/' .. item.href
    end
    local index,found,total = nil,0,0
    for attrs in refs:gmatch('<itemref%s+([^>]+)>') do
        local ref = attributes(attrs)
        if not ref.idref or not items[ref.idref] then fail('spine_unavailable') end
        total=total+1
        if total > 100001 then fail('spine_limit') end
        if items[ref.idref] == path then index,found = total,found+1 end
    end
    if found ~= 1 then fail('spine_ambiguous') end
    return index,total
end

local function node_end(index, point)
    local doc = index.document
    if fragment(point) ~= index.root then fail('chapter_end_unavailable') end
    local prefix = point:match('^(.-)%.%d+$')
    if not prefix or not prefix:find('/text()',1,true) then fail('chapter_end_unavailable') end
    local text = doc:getTextFromXPointer(point)
    if type(text) ~= 'string' or #text > M.MAX_TEXT_BYTES then fail('text_limit') end
    local at,count=1,0
    while at <= #text do local _,width=scalar(text,at); at,count=at+width,count+1 end
    local ending = doc:getNormalizedXPointer(prefix .. '.' .. count)
    if type(ending) ~= 'string' or fragment(ending) ~= index.root then fail('chapter_end_unavailable') end
    return ending
end

-- A final page can contain only an image or punctuation. Word-boundary
-- traversal misses its preceding text; walk visible characters from the
-- already-rendered final page, retaining only this fragment's last text node.
local function final_text(index)
    local doc=index.document
    if not doc.been_rendered then fail('document_not_ready') end
    local cursor=doc:getPageXPointer(doc:getPageCount())
    if type(cursor) ~= 'string' then fail('chapter_end_unavailable') end
    cursor=doc:getPrevVisibleChar(cursor) or cursor
    local ending
    for step=1,M.MAX_EDGE_STEPS do
        if fragment(cursor) == index.root and cursor:find('/text()',1,true) then ending=cursor end
        local next_point=doc:getNextVisibleChar(cursor)
        if not next_point then return ending end
        if next_point == cursor then fail('walk_diverged') end
        cursor=next_point
        if step % 128 == 0 then index:_yield() end
    end
    fail('chapter_end_limit')
end

function M.open(document,book_id,uid,options)
    return protected(function()
        local self = setmetatable({ document=document, options=options or {}, book_id=tostring(book_id),
            stats={steps=0,checkpoints=1} },Index)
        self:_check()
        -- This pins the current open archive, never a pathname or library record.
        local source = Source.read_document(document,book_id,uid)
        if not source then fail('source_unavailable') end
        self.file_id,self.chapter_uid,self.render_path=source.file_id,source.chapter_uid,source.render_path
        self:_check()
        if source.format ~= 'web_xhtml' then fail('format_unsupported') end
        self.map = Coordinates.build(source.raw)
        if not self.map then fail("source_unsupported") end
        local ordinal,total=spine(document,source.render_path)
        self.root=document:getNormalizedXPointer('/body/DocFragment[' .. ordinal .. ']')
        if type(self.root) ~= 'string' or fragment(self.root) ~= self.root then fail('chapter_unavailable') end
        -- Ordinal lookup is only a candidate. Verify CREngine's actual Source
        -- attribute against the archive-bound rendered member, ignoring titles.
        do
            local html = document:getHTMLFromXPointer(self.root,0,false)
            if type(html) ~= 'string' or #html > M.MAX_TEXT_BYTES*2 then fail('text_limit') end
            local header = html:match('^<DocFragment%s+([^>]+)>')
            if not header or attributes(header).Source ~= source.render_path then fail('chapter_mismatch') end
        end
        self:_yield()
        local ending
        if ordinal < total then
            ending=document:getPrevVisibleChar('/body/DocFragment[' .. (ordinal+1) .. '].0')
        else
            -- ReaderUI has already rendered the last page. Do not trigger
            -- rendering or move the viewport merely to find a DOM endpoint.
            ending=final_text(self)
        end
        self.ending=node_end(self,ending)
        self.text=self:_extract(self.root .. '.0',self.ending)
        self.flat=normalize(self.text,function() self:_yield() end)
        if self.flat == '' then fail('text_unavailable') end
        self.points={{ptr=#self.text,flat=#self.flat+1,xp=self.ending}}
        self.indexed_ptr,self.new_steps=#self.text,0
        self:_check()
        return self
    end)
end

local function copy(point) return {ptr=point.ptr,flat=point.flat,xp=point.xp} end
function Index:_endpoints(first,target,last)
    -- Checkpoints descend through the chapter; retain one native pointer per
    -- 256 characters, not a pointer/table for every scalar in a long chapter.
    local lo,hi,best=1,#self.points,1
    while lo <= hi do
        local mid=math.floor((lo+hi)/2)
        if self.points[mid].flat >= last then best,lo=mid,mid+1 else hi=mid-1 end
    end
    local cursor=copy(self.points[best])
    local needed,result={[first]=true,[target]=true,[last]=true},{}
    if needed[cursor.flat] then result[cursor.flat]=cursor.xp end
    while cursor.flat > first and cursor.ptr >= 1 do
        self.stats.steps=self.stats.steps+1
        if self.stats.steps % 128 == 0 then self:_yield() end
        local start=cursor.ptr
        while start > 1 and self.text:byte(start) >= 128 and self.text:byte(start) < 192 do start=start-1 end
        local cp,width=scalar(self.text,start)
        if cp ~= 10 and cp ~= 13 then
            local previous=self.document:getPrevVisibleChar(cursor.xp)
            if not previous or fragment(previous) ~= self.root then fail('walk_diverged') end
            cursor.xp=previous
            if not whitespace(cp) then
                cursor.flat=cursor.flat-width
                if needed[cursor.flat] then result[cursor.flat]=cursor.xp end
            end
        end
        cursor.ptr=start-1
        if cursor.ptr < self.indexed_ptr then
            self.indexed_ptr,self.new_steps=cursor.ptr,self.new_steps+1
            if self.new_steps >= M.CHECKPOINT_INTERVAL then
                self.points[#self.points+1]=copy(cursor)
                self.stats.checkpoints,self.new_steps=#self.points,0
            end
        end
    end
    if not result[first] or not result[target] or not result[last] then fail('walk_diverged') end
    return result[first],result[target],result[last]
end

function Index:_protected(task)
    local result,err=protected(task)
    if not result and (err == 'source_dom/walk_diverged' or err == 'source_dom/cancelled'
        or err == 'source_dom/file_changed') then self.invalid=err:sub(#'source_dom/'+1) end
    return result,err
end

function Index:locate(co)
    return self:_protected(function()
        self:_check()
        local anchor,err=self.map:anchor(co)
        if not anchor then
            if err == 'source_coordinates/offset_ambiguous' then fail('source_ambiguous') end
            fail('source_offset_unavailable')
        end
        local first,last=self.flat:find(anchor.text,1,true)
        if not first then fail('anchor_missing') end
        if self.flat:find(anchor.text,first+1,true) then fail('anchor_ambiguous') end
        local relative=byte_after(anchor.text,anchor.point_offset)-1
        local begin,target,ending=self:_endpoints(first,first+relative,last+1)
        -- Native walking and extraction can disagree around hidden/generated
        -- content or collapsed whitespace. Verify the complete quote AND its
        -- exact prefix; a failed walk never falls back to an approximate page.
        if normalize(self:_extract(begin,ending)) ~= anchor.text then fail('walk_diverged') end
        local prefix=begin == target and '' or normalize(self:_extract(begin,target))
        if prefix ~= anchor.text:sub(1,relative) then fail('walk_diverged') end
        self:_check()
        return { xpointer=target,co=co,book_id=self.book_id,chapter_uid=self.chapter_uid,
            file_id=self.file_id,render_path=self.render_path,basis='verified_source_dom' }
    end)
end

function Index:capture(xpointer)
    return self:_protected(function()
        self:_check()
        local xp=self.document:getNormalizedXPointer(xpointer)
        if type(xp) ~= 'string' or fragment(xp) ~= self.root or not xp:find('/text()',1,true) then fail('invalid_point') end
        local node_offset=tonumber(xp:match('%.(%d+)$'))
        local node=self.document:getTextFromXPointer(xp)
        if not node_offset or type(node) ~= 'string' or #node > M.MAX_TEXT_BYTES then fail('invalid_point') end
        local at,count=1,0
        while at <= #node do
            local _,size=scalar(node,at)
            at,count=at+size,count+1
            if count % 4096 == 0 then self:_yield() end
        end
        if node_offset > count then fail('invalid_point') end
        local prefix=normalize(self:_extract(self.root .. '.0',xp))
        if self.flat:sub(1,#prefix) ~= prefix then fail('walk_diverged') end
        local byte=#prefix+1
        if byte > #self.flat+1 then fail('invalid_point') end
        for _,width in ipairs({24,48,96,192}) do
            local first,after,offset=byte,byte,0
            for _i=1,width do
                if first > 1 then
                    first=first-1
                    while first > 1 and self.flat:byte(first) >= 128 and self.flat:byte(first) < 192 do first=first-1 end
                    offset=offset+1
                end
                if after <= #self.flat then local _,size=scalar(self.flat,after); after=after+size end
            end
            local point=self.map:locate_point(self.flat:sub(first,after-1),offset)
            if point then
                local located,reason=self:locate(point.co)
                if located then
                    local actual=normalize(self:_extract(self.root .. '.0',located.xpointer))
                    if actual == prefix then return located end
                elseif self.invalid then fail(self.invalid)
                elseif reason == 'source_dom/cancelled' then fail('cancelled') end
            end
        end
        fail('source_point_unavailable')
    end)
end
return M
