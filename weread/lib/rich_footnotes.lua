-- Preserve media and interactive citations by following the original note.
-- KOReader's MuPDF footnote panel has no book-resource resolver or link handler.
local M = {}
local BookLinks = require('weread.lib.book_link_paths')
local media = {img=true, image=true, svg=true, math=true, table=true, object=true,
    audio=true, video=true, embed=true, iframe=true}
local methods = {'getHTMLFromXPointer', 'getHTMLFromXPointers'}
local function pack(...) return {n=select('#', ...), ...} end

-- The input is CREngine's balanced XHTML, not the publisher's unparsed source.
function M.requires_original(html)
    if type(html)~='string' then return false end
    local pos = 1
    while true do
        local first = html:find('<', pos, true)
        if not first then return false end
        local comment = html:sub(first, first+3)=='<!--'
        local cdata = html:sub(first, first+8)=='<![CDATA['
        if comment or cdata then
            local last = html:find(comment and '-->' or ']]>', first+1, true)
            if not last then return false end
            pos=last+3
        else
            local at, quote = first+1, nil
            while at<=#html do
                local char = html:sub(at, at)
                if quote then if char==quote then quote=nil end
                elseif char=='"' or char=="'" then quote=char
                elseif char=='>' then break end
                at=at+1
            end
            if at>#html then return false end
            local raw = html:sub(first, at)
            local tag = raw:match('^<%s*([%w:_%-]+)')
            tag=tag and tag:lower():gsub('^.-:', '')
            if media[tag] then return true end
            if tag=='a' then
                local attr='[%s][hH][rR][eE][fF]%s*=%s*'
                local href = raw:match(attr .. '"([^"]*)"') or raw:match(attr .. "'([^']*)'")
                -- Generated return links must keep ordinary text popups working.
                local generated=href and (href:match('#wrfnref%-')
                    or href:match('#_doc_fragment_%d+_%s*wrfnref%-'))
                if href and not generated then
                    local last = html:find('</[aA]%s*>', at+1)
                    local label = last and html:sub(at+1, last-1):gsub('<[^>]*>', ''):gsub('%s', '')
                    if label~='↩' and label~='↑' and label~='←' and label~='⤴' then return true end
                end
            end
            pos=at+1
        end
    end
end

function M.detach(host)
    local state=host._rich_footnote_guard
    if not state then return end
    if state.link.showAsFootnotePopup==state.wrapper then
        state.link.showAsFootnotePopup=state.original
    end
    if state.goto_wrapper and state.link.onGotoLink==state.goto_wrapper then
        state.link.onGotoLink=state.goto_original
    end
    host._rich_footnote_guard=nil
end

function M.attach(host)
    M.detach(host)
    local ui=host.ui
    local link, document=ui and ui.link, ui and ui.document
    if not host._current_weread_book_id or not link or not document
        or type(link.showAsFootnotePopup)~='function' then return false end
    local state={link=link, original=link.showAsFootnotePopup}
    local rich={} -- private sentinel; no partial popup/highlight is created
    state.wrapper=function(link_self, ...)
        if host._rich_footnote_guard~=state or host.ui~=ui or ui.document~=document or ui.link~=link then
            return state.original(link_self, ...)
        end
        local saved={}
        for _i, name in ipairs(methods) do
            local original=document[name]
            if type(original)=='function' then
                saved[name]={raw=rawget(document, name)}
                document[name]=function(doc_self, ...)
                    local values=pack(original(doc_self, ...))
                    if M.requires_original(values[1]) then error(rich, 0) end
                    return unpack(values, 1, values.n)
                end
            end
        end
        -- Inspect exactly the native heuristic's chosen range, including an
        -- extended sibling range. Do not extract a second, different target.
        local result=pack(pcall(state.original, link_self, ...))
        for name, value in pairs(saved) do document[name]=value.raw end
        if not result[1] then
            if result[2]==rich then return false end -- ReaderLink follows original
            error(result[2], 0)
        end
        return unpack(result, 2, result.n)
    end
    host._rich_footnote_guard=state
    link.showAsFootnotePopup=state.wrapper
    if type(link.onGotoLink)=='function' then
        state.goto_original=link.onGotoLink
        state.goto_wrapper=function(link_self,target,...)
            if host._rich_footnote_guard==state and host.ui==ui and ui.document==document
                and ui.link==link and type(target)=='table' then
                local pointer=BookLinks.native_xpointer(document,target.xpointer)
                local mt=getmetatable(target)
                if pointer~=target.xpointer and (mt==nil or type(mt)=='table') then
                    local copy={}
                    for key,value in pairs(target) do copy[key]=value end
                    copy.xpointer=pointer
                    copy.marker_xpointer=BookLinks.native_xpointer(document,target.marker_xpointer)
                    target=setmetatable(copy,mt)
                end
            end
            return state.goto_original(link_self,target,...)
        end
        link.onGotoLink=state.goto_wrapper
    end
    return true
end
return M
