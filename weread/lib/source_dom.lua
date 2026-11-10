-- Chapter-scoped source coordinates <-> native DOM anchors. No networking,
-- navigation, whole-book search, mutable catalog mapping or settings writes.
local Coordinates = require('weread.lib.source_coordinates')
local Source = require('weread.lib.position_source')
local Identity = require('weread.lib.book_file_identity')
local TextEnd = require('weread.lib.document_text_end')
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

local function open_index(document,book_id,uid,options,metadata)
    return protected(function()
        local self = setmetatable({ document=document, options=options or {}, book_id=tostring(book_id),
            stats={steps=0,checkpoints=1} },Index)
        self:_check()
        -- This pins the current open archive, never a pathname or library record.
        local source
        if metadata then
            local snapshot = Source.document_metadata(document,book_id,uid)
            if snapshot and snapshot.metadata == metadata then source = snapshot.record end
        else source = Source.read_document(document,book_id,uid) end
        if not source then fail('source_unavailable') end
        self.file_id,self.chapter_uid,self.render_path=source.file_id,source.chapter_uid,source.render_path
        self:_check()
        self.basis = Source.coordinate_basis(source.format)
        if not self.basis then fail('format_unsupported') end
        if not metadata then
            self.map = Coordinates.build(source.raw,{format=source.format,allow_multiple_bodies=true})
            if not self.map then fail("source_unsupported") end
        end
        local ordinal,total=spine(document,source.render_path)
        self.root=document:getNormalizedXPointer('/body/DocFragment[' .. ordinal .. ']')
        if type(self.root) ~= 'string' or fragment(self.root) ~= self.root then fail('chapter_unavailable') end
        -- Ordinal lookup is only a candidate. Verify CREngine's actual Source
        -- attribute against the archive-bound rendered member, ignoring titles.
        if metadata then
            local member = M.member(document,self.root .. '.0')
            if not member or member.root ~= self.root or member.render_path ~= source.render_path then fail('chapter_mismatch') end
        else
            local html = document:getHTMLFromXPointer(self.root,0,false)
            if type(html) ~= 'string' or #html > M.MAX_TEXT_BYTES*2 then fail('text_limit') end
            local header = html:match('^<DocFragment%s+([^>]+)>')
            if not header or attributes(header).Source ~= source.render_path then fail('chapter_mismatch') end
        end
        self:_yield()
        local ending, ending_error
        local end_options = { root=self.root, max_steps=M.MAX_EDGE_STEPS, max_bytes=M.MAX_TEXT_BYTES,
            yield=function() self:_yield() end }
        if ordinal < total then
            local point=document:getPrevVisibleChar('/body/DocFragment[' .. (ordinal+1) .. '].0')
            ending,ending_error=TextEnd.node(document,point,end_options)
        else
            -- ReaderUI has already rendered the last page. Do not trigger
            -- rendering or move the viewport merely to find a DOM endpoint.
            if not document.been_rendered then fail('document_not_ready') end
            ending,ending_error=TextEnd.last(document,end_options)
        end
        if not ending then
            self:_check()
            fail(type(ending_error)=='string' and ending_error:match('^document_text_end/([a-z_]+)$') or 'chapter_end_unavailable')
        end
        self.ending=ending
        self.text=self:_extract(self.root .. '.0',self.ending)
        self.flat=normalize(self.text,function() self:_yield() end)
        if self.flat == '' then fail('text_unavailable') end
        self.points={{ptr=#self.text,flat=#self.flat+1,xp=self.ending}}
        self.indexed_ptr,self.new_steps=#self.text,0
        self:_check()
        return self
    end)
end

function M.open(document,book_id,uid,options)
    return open_index(document,book_id,uid,options)
end

-- The original member bytes and both hashes were checked in the independent
-- worker. This path only rechecks pinned metadata and builds the native index.
function M.open_prepared(document,book_id,metadata,options)
    local record = Source.decode_metadata(metadata)
    if not record or record.book_id ~= tostring(book_id) then return nil, 'source_dom/source_unavailable' end
    return open_index(document,book_id,record.chapter_uid,options,metadata)
end

local function copy(point) return {ptr=point.ptr,flat=point.flat,xp=point.xp} end
function Index:_page_checkpoint(last)
    local document=self.document
    if not document.getPageCount or not document.getPageXPointer then return end
    local ok,pages=pcall(document.getPageCount,document)
    if not ok or type(pages)~='number' or pages<32 or pages>100000 or pages%1~=0 then return end
    local lo,hi,best=1,pages,nil
    -- A native page boundary is only a candidate checkpoint. Its complete
    -- chapter prefix must match the pinned native text before it can shorten
    -- the exact character walk; no page ratio or nearest-text inference.
    while lo<=hi do
        self:_yield()
        local mid=math.floor((lo+hi)/2)
        local found,xp=pcall(document.getPageXPointer,document,mid)
        if not found or type(xp)~='string' then return end
        if fragment(xp)~=self.root then
            if not document.compareXPointers then return end
            local compared,order=pcall(document.compareXPointers,document,self.root..'.0',xp)
            if not compared or order~=1 and order~=-1 then return end
            if order==1 then hi=mid-1 else lo=mid+1 end
        else
            local prefix=self:_extract(self.root..'.0',xp)
            local flat=normalize(prefix,function() self:_yield() end)
            if self.flat:sub(1,#flat)~=flat then fail('walk_diverged') end
            if #flat+1>=last then
                if self.text:sub(1,#prefix)==prefix then best={ptr=#prefix,flat=#flat+1,xp=xp} end
                hi=mid-1
            else lo=mid+1 end
        end
    end
    self:_check()
    return best
end
function Index:_endpoints(first,target,last)
    -- Checkpoints descend through the chapter; retain one native pointer per
    -- 256 characters, not a pointer/table for every scalar in a long chapter.
    local lo,hi,best=1,#self.points,1
    while lo <= hi do
        local mid=math.floor((lo+hi)/2)
        if self.points[mid].flat >= last then best,lo=mid,mid+1 else hi=mid-1 end
    end
    local cursor=copy(self.points[best])
    if cursor.flat-last>4096 then
        local page=self:_page_checkpoint(last)
        if page and page.flat<cursor.flat then cursor=page end
    end
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
    local active,reason=protected(function() self:_check();return true end)
    if not active then return nil,reason end
    if not self.map then return nil,'source_dom/source_unavailable' end
    local anchor,err=self.map:anchor(co,{segment_only=true})
    if not anchor then anchor,err=self.map:anchor(co) end
    if not anchor then
        return nil,err == 'source_coordinates/offset_ambiguous' and 'source_dom/source_ambiguous' or 'source_dom/source_offset_unavailable'
    end
    return self:locate_anchor(anchor)
end

function Index:locate_anchor(anchor)
    return self:_protected(function()
        self:_check()
        if type(anchor) ~= 'table' or type(anchor.text) ~= 'string' or #anchor.text > Coordinates.MAX_ANCHOR_BYTES
            or anchor.basis ~= self.basis or anchor.point_unit ~= 'unicode_scalars'
            or type(anchor.co) ~= 'number' or anchor.co < 0 or anchor.co % 1 ~= 0 or anchor.co > Coordinates.MAX_BYTES*8
            or type(anchor.point_offset) ~= 'number' or anchor.point_offset < 0 or anchor.point_offset % 1 ~= 0 then
            fail('invalid_anchor')
        end
        local text, count=normalize(anchor.text)
        if text ~= anchor.text or count < 12 or anchor.point_offset > count then fail('invalid_anchor') end
        local co=anchor.co
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
    if not self.map then return nil,'source_dom/source_unavailable' end
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
        local function attempt(first,after,offset)
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
        local windows={}
        for _width_index,width in ipairs({24,48,96,192}) do
            local first,after,offset=byte,byte,0
            for _i=1,width do
                if first > 1 then
                    first=first-1
                    while first > 1 and self.flat:byte(first) >= 128 and self.flat:byte(first) < 192 do first=first-1 end
                    offset=offset+1
                end
                if after <= #self.flat then local _,size=scalar(self.flat,after); after=after+size end
            end
            local located=attempt(first,after,offset)
            if located then return located end
            windows[#windows+1]={byte,after,0};windows[#windows+1]={first,byte,offset}
        end
        local resolved
        for _i,window in ipairs(windows) do
            local located=attempt(window[1],window[2],window[3])
            if located then
                if resolved and resolved.co~=located.co then fail('source_point_unavailable') end
                resolved=located
            end
        end
        if resolved then return resolved end
        fail('source_point_unavailable')
    end)
end
return M
