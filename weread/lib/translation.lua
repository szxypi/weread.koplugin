-- Adapted from MiuRead translation.lua, c1893562aa25a870b8dd076d7be062a3348f823e.
-- Copyright (C) 2026 MiuRead contributors. AGPL-3.0-only; see NOTICE.
-- Display and native-position migration for official WeRead XHTML. Display
-- changes use CSS only; generated refreshes verify unchanged original blocks
-- before migrating highlights. Only paired blocks may hide their source text.
local M = { MAX_HTML_BYTES=2*1024*1024, MAX_NODES=100000, MAX_DEPTH=256 }

local INLINE = {span=true, a=true, em=true, strong=true, b=true, i=true, small=true}
local DISPLAY = {li="list-item", table="table", tr="table-row", td="table-cell", th="table-cell"}
local VOID = {area=true, base=true, br=true, col=true, embed=true, hr=true, img=true,
    input=true, link=true, meta=true, param=true, source=true, track=true, wbr=true}


local function utf8_char(n)
    if n < 0 or n > 0x10ffff or (n >= 0xd800 and n <= 0xdfff) then return "" end
    if n < 128 then return string.char(n) end
    if n < 2048 then return string.char(192+math.floor(n/64), 128+n%64) end
    if n < 65536 then return string.char(224+math.floor(n/4096), 128+math.floor(n/64)%64, 128+n%64) end
    return string.char(240+math.floor(n/262144), 128+math.floor(n/4096)%64, 128+math.floor(n/64)%64, 128+n%64)
end

local function unescape(s)
    local named = {amp="&", lt="<", gt=">", quot='"', apos="'"}
    return tostring(s or ""):gsub("&([^;]+);", function(entity)
        if named[entity] then return named[entity] end
        local n = entity:match("^#(%d+)$")
        n = n and tonumber(n) or tonumber(entity:match("^#[xX](%x+)$") or "", 16)
        return n and utf8_char(n) or ("&"..entity..";")
    end)
end

local function attribute(tag, name)
    for key, quote, value in tag:gmatch("([%w:_-]+)%s*=%s*(['\"])(.-)%2") do
        if key == name then return unescape(value) end
    end
end

local function has_class(value, class)
    for word in tostring(value or ""):gmatch("%S+") do if word == class then return true end end
    return false
end

local function inline_font_rem(style, inherited)
    local value, important
    for declaration in tostring(style or ""):lower():gmatch("[^;]+") do
        local property,candidate=declaration:match("^%s*([%w-]+)%s*:%s*(.-)%s*$")
        if property=="font-size" or property=="font" then
            local is_important=candidate:match("!%s*important%s*$")~=nil
            if not important or is_important then
                value=candidate:gsub("%s*!%s*important%s*$","")
                if property=="font" and value~="inherit" then value="unsupported" end
                important=is_important
            end
        end
    end
    if not value or value=="inherit" then return inherited end
    local size=tonumber(value:match("^([%d.]+)rem$"))
    -- Other units cannot be inferred from a sibling's nested inline style.
    return size and size>0 and size<=10 and size or false
end

local function tag_end(html, start_at)
    local quote
    for i = start_at + 1, #html do
        local c = html:sub(i, i)
        if quote then
            if c == quote then quote = nil end
        elseif c == '"' or c == "'" then quote = c
        elseif c == ">" then return i end
    end
end

local function notice_text(stack, value)
    value=unescape(value):gsub("\r\n","\n"):gsub("\r","\n")
    local node=stack[#stack]
    if node and node.dom_parts and value~="" then
        local last=node.dom_parts[#node.dom_parts]
        if type(last)=="table" then last.text=last.text..value
        else node.dom_parts[#node.dom_parts+1]={text=value} end
    end
    local text=value:gsub(utf8_char(160), " "):gsub("%s+", "")
    if text=="" then return end
    if node and node.last_child then node.gap_after_child=true end
    local font=node and node.font_rem or false
    for _, ancestor in ipairs(stack) do
        if ancestor.translation then ancestor.readable = true end
        if ancestor.font_counts then
            ancestor.font_counts[font]=(ancestor.font_counts[font] or 0)+#text
            ancestor.font_text_bytes=ancestor.font_text_bytes+#text
        end
    end
end

local function finish_node(node)
    if not node.dom_parts then return end
    local parts={node.name,":"..tostring(node.image_source or "")}
    for _,part in ipairs(node.dom_parts) do
        parts[#parts+1]=type(part)=="table" and ("t"..#part.text..":"..part.text) or ("e"..part)
    end
    node.signature=require("weread.lib.crypto").sha256_hex(table.concat(parts,"\0"))
    node.dom_parts=nil
    if node.parent and node.parent.dom_parts then
        node.parent.dom_parts[#node.parent.dom_parts+1]=node.signature
    end
end

function M.normalize_mode(mode)
    return (mode == "bilingual" or mode == "translation") and mode or "original"
end

function M.normalize_font_scale(value)
    value=tonumber(value) or 100
    if value~=value then value=100 end
    return math.max(80,math.min(180,math.floor(value/10+.5)*10))
end

function M.label(mode)
    local tr=require("weread.lib.i18n").tr
    return tr(({original="Original", bilingual="Bilingual", translation="Translation only"})[M.normalize_mode(mode)])
end

-- Shared unique IDs establish explicit pairs. Current Web chapters also emit
-- adjacent id-less paragraphs, verified against actual responses. Only clean
-- text-only paragraph boundaries qualify for that path. Conflicting IDs,
-- containers, illustrations and links must not hide unverified original text.
-- Native migration collects DOM signatures instead of font statistics; it
-- never retains copies of the source markup for nested original nodes.
function M.analyze(html, chapter_uid, fragment_index, collect_positions)
    if type(html)~="string" or #html>M.MAX_HTML_BYTES then return nil,"html_limit" end
    if fragment_index==nil then fragment_index=1 end
    if type(fragment_index)~="number" or fragment_index<1 or fragment_index>20000 or fragment_index%1~=0 then return nil,"fragment_identity" end
    local lower=html:lower()
    local nodes=0
    local out = {blocks=0, pairs={}, typography={}, tags={}, recoveries=0,
        relations={same_tag=0,source_id=0,translation_id=0,same_id=0,previous_missing=0},
        chapter_uid=tostring(chapter_uid or ""), fragment_index=fragment_index or 1}
    if collect_positions then out.original_nodes={} end
    local stack, ids, pending, translated_nodes, font_pending = {}, {}, {}, {}, {}
    local cursor, body = 1, nil
    while true do
        local start_at = html:find("<", cursor, true)
        if not start_at then break end
        notice_text(stack, html:sub(cursor, start_at-1))
        local finish
        if html:sub(start_at, start_at+3) == "<!--" then
            finish = html:find("-->", start_at+4, true)
            if not finish then return nil, "unterminated_comment" end
            cursor = finish + 3
        elseif html:sub(start_at, start_at+8) == "<![CDATA[" then
            finish = html:find("]]>", start_at+9, true)
            if not finish then return nil, "unterminated_cdata" end
            notice_text(stack, html:sub(start_at+9, finish-1))
            cursor = finish + 3
        else
            finish = tag_end(html, start_at)
            if not finish then return nil, "unterminated_tag" end
            local raw = html:sub(start_at, finish)
            local closing, full_name = raw:match("^<%s*(/?)%s*([%w:_-]+)")
            local name=full_name and full_name:match("([^:]+)$")
            -- CRE's ReadIdent rejects an empty local name, then skips through
            -- '>'. Unescaped SPARQL IRIs such as <http://example.org/type>
            -- take this path. Skip the token without inventing a DOM element
            -- or changing any source bytes/native text offsets.
            -- https://github.com/koreader/crengine/blob/60a5fbc1531f76a47c54699d487390e2e2cb1c14/crengine/src/lvxml.cpp#L5807-L5834
            if full_name and not name then out.recoveries=out.recoveries+1 end
            if name then
                name=name:lower()
                if closing == "/" then
                    -- Imported HTML sometimes spells a void tag as <br></br>.
                    -- It has no children and must not pop its enclosing block.
                    if not VOID[name] then
                        local match
                        for index=#stack,1,-1 do
                            if stack[index].name==name then match=index; break end
                        end
                        -- Match CRE's XHTML DOM writer (ldomDocumentWriter::pop):
                        -- an unmatched end tag closes nothing; an ancestor end
                        -- tag closes intervening children first. Imported text
                        -- can contain <English>...</Chinese>; no source bytes
                        -- are rewritten, and pairing still requires verified
                        -- adjacent siblings with a unique original/translated id.
                        -- https://github.com/koreader/crengine/blob/60a5fbc1531f76a47c54699d487390e2e2cb1c14/crengine/src/lvtinydom.cpp
                        if not match then out.recoveries=out.recoveries+1
                        else
                            while #stack>match do
                                local node=table.remove(stack)
                                finish_node(node)
                                out.recoveries=out.recoveries+1
                            end
                            local node=table.remove(stack)
                            finish_node(node)
                        end
                    end
                else
                    nodes=nodes+1
                    if nodes>M.MAX_NODES or #stack>=M.MAX_DEPTH then return nil,"node_limit" end
                    local parent = stack[#stack]
                    local is_body = name == "body"
                    local in_body = is_body or (parent and parent.in_body) or false
                    local node = {name=name, parent=parent, in_body=in_body, counts={}}
                    -- Keep original illustrations, formulae and link controls.
                    if name=="img" or name=="svg" or name=="math" or name=="audio" or name=="video" or name=="table" or name=="a" then
                        for _,ancestor in ipairs(stack) do ancestor.preserve_content=true end
                    end
                    if collect_positions and in_body then
                        node.dom_parts={}
                        if name=="img" then node.image_source=attribute(raw,"src") end
                    end
                    if is_body then
                        if body then return nil, "multiple_bodies" end
                        body = node
                        node.path = "/body"
                        out.scope_uid = attribute(raw, "data-weread-chapter")
                        out.chapter_uid = out.scope_uid or out.chapter_uid
                    elseif parent and parent.path then
                        parent.counts[name] = (parent.counts[name] or 0) + 1
                        node.path = parent.path.."/"..name.."["..parent.counts[name].."]"
                    end
                    if in_body then
                        node.id = attribute(raw, "id")
                        if node.id=="" then node.id=nil end
                        node.translation = has_class(attribute(raw, "class"), "wr-translation")
                        node.in_translation = node.translation or (parent and parent.in_translation) or false
                        if not collect_positions then
                            node.font_rem=inline_font_rem(attribute(raw,"style"),parent and parent.font_rem)
                            if not node.in_translation then node.font_counts={}; node.font_text_bytes=0 end
                        end
                        if collect_positions and node.path and not node.in_translation then
                            out.original_nodes[#out.original_nodes+1]=node
                        end
                        if node.id then ids[node.id] = (ids[node.id] or 0) + 1 end
                        if node.translation and not (parent and parent.in_translation) then
                            translated_nodes[#translated_nodes+1] = node
                            out.tags[name] = true
                            local previous = parent and not parent.gap_after_child and parent.last_child
                            if not previous then out.relations.previous_missing=out.relations.previous_missing+1
                            else
                                if previous.name==name then out.relations.same_tag=out.relations.same_tag+1 end
                                if previous.id then out.relations.source_id=out.relations.source_id+1 end
                                if node.id then out.relations.translation_id=out.relations.translation_id+1 end
                                if previous.id and previous.id==node.id then out.relations.same_id=out.relations.same_id+1 end
                            end
                            if not collect_positions and previous and not previous.in_translation and not previous.has_translation
                                and previous.name==name then
                                font_pending[#font_pending+1]={source=previous,node=node,tag=name,
                                    original_path=previous.path,translation_path=node.path}
                            end
                            if previous and not previous.in_translation and not previous.has_translation
                                and not previous.preserve_content and previous.name==name then
                                if previous.id and previous.id==node.id then
                                    pending[#pending+1]={id=node.id,tag=name,original_path=previous.path,
                                        translation_path=node.path,node=node,kind="id"}
                                elseif name=="p" and not previous.id and not node.id and (previous.font_text_bytes or 0)>0 then
                                    -- Actual Web chapters also emit adjacent id-less paragraphs.
                                    -- Use exact paths only when their boundary is unambiguous;
                                    -- do not infer a pairing across conflicting explicit IDs.
                                    pending[#pending+1]={tag=name,original_path=previous.path,
                                        translation_path=node.path,node=node,kind="adjacent"}
                                end
                            end
                            for _, ancestor in ipairs(stack) do ancestor.has_translation = true end
                        end
                    end
                    if parent then parent.last_child = node;parent.gap_after_child=false end
                    local self_closing=VOID[name] or raw:match("/%s*>$")
                    if not self_closing and (name=="style" or name=="script" or (name=="title" and not in_body)) then
                        -- CSS, scripts and head titles are raw text, not nested
                        -- chapter tags. A '<' in them cannot break the body scan.
                        local raw_start,raw_finish=lower:find("</"..name.."%s*>",finish+1)
                        if not raw_finish then return nil,"unterminated_raw_text tag="..name end
                        notice_text({node},html:sub(finish+1,raw_start-1))
                        finish=raw_finish
                        finish_node(node)
                    elseif not self_closing then stack[#stack+1] = node
                    else finish_node(node) end
                end
            end
            cursor = finish + 1
        end
    end
    if #stack > 0 or not body then return nil, "incomplete_document" end
    for _, node in ipairs(translated_nodes) do if node.readable then out.blocks = out.blocks + 1 end end
    for _, pair in ipairs(pending) do
        if ((pair.kind=="id" and ids[pair.id]==2) or (pair.kind=="adjacent" and out.recoveries==0)) and pair.node.readable then
            pair.node = nil
            out.pairs[#out.pairs+1] = pair
        end
    end
    for _, pair in ipairs(font_pending) do
        local source,node=pair.source,pair.node
        local font,weight,smallest,largest
        for size,count in pairs(source.font_counts or {}) do
            if size then
                if not weight or count>weight or (count==weight and size>font) then font,weight=size,count end
                smallest=math.min(smallest or size,size)
                largest=math.max(largest or size,size)
            end
        end
        -- Converted PDFs put reader-relative sizes on English spans but leave
        -- Chinese paragraphs unstyled. CRE resolves rem against its default
        -- reader font, while percentages inherit the book's fixed html size.
        -- Copy the dominant source size using CSS only, including id-less
        -- paragraphs. This never makes an unverified source block hideable.
        local uniform_rem=smallest and (source.font_counts[false] or 0)==0 and largest/smallest<=1.1
        if node.readable and font and (weight>=(source.font_text_bytes or 0)*.8 or uniform_rem) then
            pair.font_rem=font
            pair.id=node.id and (ids[node.id]==1 or (ids[node.id]==2 and source.id==node.id)) and node.id or nil
            pair.source=nil; pair.node=nil
            out.typography[#out.typography+1]=pair
        end
    end
    out.separable = out.blocks > 0 and #out.pairs == out.blocks
    if collect_positions then
        for index,node in ipairs(out.original_nodes) do
            out.original_nodes[index]={id=node.id,tag=node.name,path=node.path,signature=node.signature}
        end
    end
    return out
end

local function normalize_path(path)
    return path:gsub("/([^/]+)",function(segment)
        return "/"..(segment:match("^[%w_-]+$") and segment.."[1]" or segment)
    end):gsub("^/body%[1%]", "/body")
end

local function display(tag)
    return INLINE[tag] and "inline" or DISPLAY[tag] or "block"
end

local function block_selector(scope, pair, translated)
    local id = tostring(pair.id or "")
    -- CRE prefixes EPUB ids with "_doc_fragment_N_ ". Its #id selector
    -- understands that prefix, whereas [id="source-id"] in older versions
    -- compares the rewritten attribute verbatim and never matches.
    -- CRE also lacks identifier escapes: address unusual/long ids by the
    -- already verified block path instead of emitting an unsupported #id.
    if #id < 512 and (id:match("^[A-Za-z_][A-Za-z0-9_-]*$")
        or id:match("^%-[A-Za-z_-][A-Za-z0-9_-]*$")) then
        return scope.."#"..id
    end
    local path = translated and pair.translation_path or pair.original_path
    return scope:gsub(" $", "")..path:gsub("^/body", "")
        :gsub("/([%w_-]+)%[(%d+)%]", " > %1:nth-of-type(%2)")
end

-- A single unpaired translation must not disable verified pairs elsewhere.
-- Only pairs with a verified native fragment ordinal are usable by CSS.
-- Keep `separable` as the stricter full-coverage diagnostic for old callers.
function M.translation_only_status(profile)
    if not profile then return {available=false,reason="inspection",blocks=0,pairs=0,unpaired=0} end
    local blocks=tonumber(profile.blocks) or 0
    local paired=0
    for _,chapter in ipairs(profile.chapters or {}) do
        if type(chapter.fragment_index)=="number" and chapter.fragment_index>=1 and chapter.fragment_index%1==0 then
            paired=paired+#(chapter.pairs or {})
        end
    end
    local unpaired=math.max(0,blocks-paired)
    return {available=paired>0,blocks=blocks,pairs=paired,unpaired=unpaired,
        reason=blocks==0 and "missing" or (paired==0 and "unpaired" or (unpaired>0 and "partial" or "ready"))}
end

function M.css(profile, mode, font_scale)
    mode = M.normalize_mode(mode)
    font_scale=M.normalize_font_scale(font_scale)
    if not profile or (profile.blocks or 0) == 0 then return nil end
    if mode == "translation" and not M.translation_only_status(profile).available then return nil end
    local lines = {"/* WeRead translation display */"}
    for _, chapter in ipairs(profile.chapters or {}) do
        if chapter.blocks > 0 and type(chapter.fragment_index)=="number" and chapter.fragment_index>=1 and chapter.fragment_index%1==0 then
            local scope = "DocFragment:nth-of-type("..chapter.fragment_index..") body "
            if mode == "original" then
                lines[#lines+1] = scope..".wr-translation { display: none !important; }"
            else
                if mode == "translation" then
                    for _, pair in ipairs(chapter.pairs) do
                        lines[#lines+1] = block_selector(scope, pair, false).." { display: none !important; }"
                        lines[#lines+1] = block_selector(scope, pair, true)..".wr-translation { display: "..display(pair.tag).." !important; }"
                    end
                end
                local tags = {}
                for tag in pairs(chapter.tags) do tags[#tags+1] = tag end
                table.sort(tags) -- Stable stylesheet text keeps CRE caches reusable.
                for _, tag in ipairs(tags) do
                    lines[#lines+1] = scope..tag..".wr-translation { display: "..display(tag).." !important; }"
                    -- Imported translation styles may shrink body text. Use
                    -- a reader-controlled percentage of the surrounding body
                    -- size; keep the book's heading hierarchy intact.
                    if not tag:match("^h[1-6]$") then
                        lines[#lines+1]=scope..tag..".wr-translation { font-size: "..font_scale.."% !important; }"
                    end
                end
                for _,pair in ipairs(chapter.pairs) do
                    if not pair.tag:match("^h[1-6]$") then
                        lines[#lines+1]=block_selector(scope,pair,true)..".wr-translation { font-size: "..font_scale.."% !important; }"
                    end
                end
                for _,pair in ipairs(chapter.typography or {}) do
                    local size=pair.font_rem*(pair.tag:match("^h[1-6]$") and 1 or font_scale/100)
                    local value=string.format("%.4f",size):gsub("0+$",""):gsub("%.$","")
                    lines[#lines+1]=block_selector(scope,pair,true)..".wr-translation { font-size: "..value.."rem !important; }"
                end
            end
        end
    end
    return table.concat(lines, "\n")
end

-- Restore the corresponding paragraph, rather than a page percentage that
-- changes when bilingual text doubles the number of pages. Text offsets in
-- two different languages cannot be copied; use the paired block's start.
function M.remap_xpointer(profile, xp, mode)
    if type(xp) ~= "string" or mode == "bilingual" then return nil end
    local fragment, tail = xp:match("^/body/DocFragment%[(%d+)%](/body.*)")
    if not fragment then
        tail=xp:match("^/body/DocFragment(/body.*)")
        if tail then fragment="1" end
    end
    if not fragment then return nil end
    local normalized = normalize_path(tail)
    for _, chapter in ipairs(profile.chapters or {}) do
        if chapter.fragment_index == tonumber(fragment) then
            for _, pair in ipairs(chapter.pairs) do
                local from = mode == "translation" and pair.original_path or pair.translation_path
                local to = mode == "translation" and pair.translation_path or pair.original_path
                if normalized:sub(1, #from) == from and (normalized:sub(#from+1, #from+1) == "/" or normalized:sub(#from+1,#from+1)=="." or normalized == from) then
                    return "/body/DocFragment["..fragment.."]"..to
                end
            end
        end
    end
end


return M
