-- A small native viewport snapshot. Only bounded nearby text and file metadata
-- leave this module; the expensive source validation/indexing belongs in a worker.
local Dom = require('weread.lib.source_dom')
local Source = require('weread.lib.position_source')
local M = { WIDTH=192, MAX_CONTEXT_BYTES=8192 }
local function finite(value)
    return type(value)=='number' and value==value and value>=0 and value<1e15
end
local function same(a,b)
    return a and b and a.xpointer==b.xpointer and a.page==b.page and a.pos==b.pos and a.view_mode==b.view_mode
end
M.same_location=same
function M.location(document,mode)
    local ok,value=pcall(function()
        local page,pos=document:getCurrentPage(),document:getCurrentPos()
        if not finite(page) or not finite(pos) then return nil end
        local xp=mode=='scroll' and document:getXPointer() or document:getPageXPointer(page)
        xp=document:getNormalizedXPointer(xp)
        if type(xp)~='string' or #xp>4096 then return nil end
        return {xpointer=xp,page=page,pos=pos,view_mode=mode or 'page'}
    end)
    return ok and value or nil
end
local function count(text)
    local n=0
    for _char in text:gmatch('[%z\1-\127\194-\244][\128-\191]*') do n=n+1 end
    return n
end
function M.capture(document,book_id,location,options)
    options=options or {}
    local function check()
        if options.is_current and options.is_current()~=true then error('source_context/cancelled',0) end
    end
    local function extract(first,last)
        if first==last then return '' end
        local ok,text=pcall(document.getTextFromXPointers,document,first,last)
        if document.clearSelection then pcall(document.clearSelection,document) end
        check()
        if not ok or type(text)~='string' or #text>M.MAX_CONTEXT_BYTES then error('source_context/context_unavailable',0) end
        return text
    end
    local ok,result=pcall(function()
        check()
        local xp=location.xpointer
        if not xp:find('/text()',1,true) then return {error='no_visible_text'} end
        -- Validate one adjacent scalar without copying the whole native text
        -- node. A stale/out-of-bounds bookmark must not become a chapter-end co.
        local node,offset=xp:match('^(.-)%.(%d+)$')
        if not node then return {error='context_unavailable'} end
        offset=tonumber(offset)
        local from,to=xp,node..'.'..(offset+1)
        if offset>0 then from,to=node..'.'..(offset-1),xp end
        local adjacent=extract(from,to)
        if #adjacent>4 or count(adjacent)~=1 then return {error='context_unavailable'} end

        local member=Dom.member(document,xp)
        if not member then return {error='source_unavailable'} end
        local metadata=Source.document_metadata(document,book_id,nil,member.render_path)
        if not metadata then return {error='source_unavailable'} end
        local first,last=xp,xp
        local calls=0
        local function pause()
            calls=calls+1
            if calls%64==0 then check(); if options.yield then options.yield() end; check() end
        end
        for _i=1,M.WIDTH do
            local previous=document:getPrevVisibleChar(first)
            if not previous or Dom.fragment(previous)~=member.root then break end
            first=previous; pause()
        end
        local ended=false
        for _i=1,M.WIDTH do
            local next_point=document:getNextVisibleChar(last)
            if not next_point or Dom.fragment(next_point)~=member.root then ended=true; break end
            if next_point==last then return {error='context_unavailable'} end
            last=next_point; pause()
        end
        if ended then
            local prefix,edge_offset=last:match('^(.-)%.(%d+)$')
            if prefix and edge_offset then
                local after=document:getNormalizedXPointer(prefix..'.'..(tonumber(edge_offset)+1))
                if type(after)=='string' and Dom.fragment(after)==member.root then
                    local char=extract(last,after)
                    if #char<=4 and count(char)==1 then last=after end
                end
            end
        end
        local full,prefix=Dom.normalize(extract(first,last)),Dom.normalize(extract(first,xp))
        if not full or not prefix or full:sub(1,#prefix)~=prefix then return {error='context_unavailable'} end
        check()
        local again=Source.document_metadata(document,book_id,nil,member.render_path)
        if not again or again.metadata~=metadata.metadata then return {error='source_changed'} end
        return { file=document.file, book_id=tostring(book_id), chapter_uid=metadata.chapter_uid,
            identity=metadata.identity, metadata=metadata.metadata, render_path=member.render_path,
            text=full, point_offset=count(prefix) }
    end)
    if ok then return result end
    return {error=result=='source_context/cancelled' and 'cancelled' or 'context_unavailable'}
end
return M
