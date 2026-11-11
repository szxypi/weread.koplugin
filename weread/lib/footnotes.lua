-- Book-footnote conversion for downloaded WeRead XHTML.
--
-- The module is deliberately network-free. Callers scan every pristine chapter
-- before range-based user annotations mutate the markup, build one book-wide
-- anchor index, then transform the finalized chapter bodies cooperatively.

local logger = require("weread.lib.logger").scoped("Footnotes")
local BookLinks = require('weread.lib.book_link_paths')

local Footnotes = {}

-- Standard endnotes stay readable; the reading system controls their display.
Footnotes.FOOTNOTES_CSS = [[
.wr-fn-ref{font-size:0.75em;vertical-align:super;line-height:0;white-space:nowrap;}
.wr-fn-ref a{position:relative;text-decoration:none;color:#0366d6;}
.wr-fn-ref a::after{content:"";position:absolute;top:-0.5em;right:-0.3em;bottom:-0.5em;left:-0.3em;}
div.wr-footnotes>hr{display:none;}
.wr-fn-num{font-weight:bold;margin-right:0.3em;text-decoration:none;color:inherit;}
div.wr-footnotes{margin-top:1em;padding-top:0.5em;border-top:1px solid #ccc;}
aside.wr-book-footnote{font-size:0.85em;margin:0.5em 0;text-indent:0;}
]]

local function xml_escape(value)
    return (tostring(value or "")
        :gsub("&", "&amp;")
        :gsub("<", "&lt;")
        :gsub(">", "&gt;")
        :gsub('"', "&quot;"))
end

local function decode_entities(value)
    value = tostring(value or "")
    value = value:gsub("&nbsp;", " "):gsub("&#160;", " "):gsub("&#x[Aa]0;", " ")
    value = value:gsub("&amp;", "&"):gsub("&#38;", "&")
    value = value:gsub("&lt;", "<"):gsub("&gt;", ">")
    value = value:gsub("&quot;", '"'):gsub("&#34;", '"')
    value = value:gsub("&apos;", "'"):gsub("&#39;", "'")
    return value
end

local function get_attr(raw, name)
    raw = tostring(raw or "")
    local escaped = tostring(name or ""):gsub("([^%w])", "%%%1")
    return raw:match('^%s*' .. escaped .. '%s*=%s*"([^"]*)"')
        or raw:match('%s+' .. escaped .. '%s*=%s*"([^"]*)"')
        or raw:match("^%s*" .. escaped .. "%s*=%s*'([^']*)'")
        or raw:match("%s+" .. escaped .. "%s*=%s*'([^']*)'")
end

local function has_token(value, token)
    local padded = " " .. tostring(value or ""):lower():gsub("%s+", " ") .. " "
    return padded:find(" " .. tostring(token):lower() .. " ", 1, true) ~= nil
end

local function strip_tags(value)
    value = tostring(value or "")
    value = value:gsub("<[bB][rR]%s*/?>", " ")
    value = value:gsub("</[pP]%s*>", " "):gsub("</[dD][iI][vV]%s*>", " ")
    value = value:gsub("<[^>]+>", " ")
    value = decode_entities(value)
    value = value:gsub("\226\128\139", ""):gsub("\226\128\140", ""):gsub("\226\128\141", "")
    return value:gsub("%s+", " "):match("^%s*(.-)%s*$") or ""
end

local function clean_note_text(value)
    local text = strip_tags(value)
    text = text:gsub("^%[%s*%d+%s*%]%s*", "")
    text = text:gsub("^%(%s*%d+%s*%)%s*", "")
    text = text:gsub("^（%s*%d+%s*）%s*", "")
    text = text:gsub("^%*+%s*", "")
    for _i, marker in ipairs({ "†", "‡", "※" }) do
        if text:sub(1, #marker) == marker then
            text = text:sub(#marker + 1):gsub("^%s*", "")
            break
        end
    end
    return text:match("^%s*(.-)%s*$") or ""
end

local function is_symbol_marker(text)
    return text:match("^%*+$") ~= nil
        or text == "†" or text == "‡" or text == "※"
end

local function is_trivial_note(value)
    local text = strip_tags(value):gsub("%s+", "")
    if text == "" then return true end
    return text:match("^%[%d+%]$") ~= nil
        or text:match("^%d+$") ~= nil
        or text:match("^%(%d+%)$") ~= nil
        or text:match("^（%d+）$") ~= nil
        or is_symbol_marker(text)
end

-- Decode the UTF-8 codepoint starting at byte i; returns the codepoint (nil
-- for a malformed sequence) and the number of bytes consumed.
local function utf8_codepoint(text, i)
    local b = text:byte(i)
    if b < 0x80 then return b, 1 end
    local cp, len
    if b >= 0xC2 and b < 0xE0 then cp, len = b - 0xC0, 2
    elseif b >= 0xE0 and b < 0xF0 then cp, len = b - 0xE0, 3
    elseif b >= 0xF0 and b < 0xF5 then cp, len = b - 0xF0, 4
    else return nil, 1 end
    for j = 1, len - 1 do
        local cb = text:byte(i + j)
        if not cb or cb < 0x80 or cb > 0xBF then return nil, j end
        cp = cp * 64 + (cb - 0x80)
    end
    return cp, len
end

-- Backlink glyphs (↩ ↑ ← ⤴) are pure symbols, yet an element carrying one may
-- share the note target's id; such a capture can never be a definition.
-- Enumerating "known" text scripts instead (the old %w + CJK lead-byte check)
-- silently dropped notes written only in kana, hangul, Cyrillic or any other
-- non-ASCII script, so reject a candidate only when EVERY codepoint it holds
-- is a symbol or punctuation: arrows, dingbats and enclosed numbers
-- (U+2000-U+2FFF), CJK punctuation (U+3000-U+303F), Latin-1 symbols
-- (U+0080-U+00BF), variation selectors and the BOM. Any other codepoint
-- (Latin letters, kana, hangul, CJK, emoji …) counts as note text.
local function is_symbol_only(text)
    local i, n = 1, #text
    while i <= n do
        local cp, len = utf8_codepoint(text, i)
        if not cp then
            i = i + (len or 1)
        elseif cp < 128 then
            if text:sub(i, i):match("%w") then return false end
            i = i + 1
        elseif (cp >= 0x80 and cp <= 0xBF)
            or (cp >= 0x2000 and cp <= 0x2FFF)
            or (cp >= 0x3000 and cp <= 0x303F)
            or (cp >= 0xFE00 and cp <= 0xFE0F)
            or cp == 0xFEFF then
            i = i + len
        else
            return false
        end
    end
    return true
end

local function normalize_path(value)
    value = decode_entities(value):gsub("\\", "/")
    value = value:match("^%s*(.-)%s*$") or ""
    value = value:gsub("^/+", "")
    local parts = {}
    for part in value:gmatch("[^/]+") do
        if part == ".." then
            if #parts > 0 then table.remove(parts) end
        elseif part ~= "." and part ~= "" then
            parts[#parts + 1] = part
        end
    end
    return table.concat(parts, "/"):lower()
end

local function basename(value)
    return tostring(value or ""):gsub("\\", "/"):match("([^/]+)$") or ""
end

local function split_href(value)
    value = decode_entities(value):match("^%s*(.-)%s*$") or ""
    local file, anchor = value:match("^(.-)#(.+)$")
    if not anchor or anchor == "" then return nil, nil end
    anchor = anchor:gsub("%%([%x][%x])", function(hex)
        return string.char(tonumber(hex, 16))
    end)
    return normalize_path(file or ""), anchor
end

local function ref_key(file, anchor)
    file = normalize_path(file)
    if file == "" then return tostring(anchor or "") end
    return file .. "#" .. tostring(anchor or "")
end

local function safe_id(value)
    value = tostring(value or "chapter"):gsub("[^%w_.-]", "_")
    if value == "" then return "chapter" end
    return value
end

local function ref_display(inner)
    local text = strip_tags(inner)
    if text == "" then return "*" end
    return text
end

local function looks_like_ref(attrs, href, inner)
    local file, anchor = split_href(href)
    if not anchor then return false end
    local lower_anchor = anchor:lower()
    if lower_anchor:find("wrthought-", 1, true) == 1
        or lower_anchor:find("thought_", 1, true) == 1
        or lower_anchor:find("wrfn-", 1, true) == 1
        or lower_anchor:find("wrfnref-", 1, true) == 1 then
        return false
    end

    local epub_type = (get_attr(attrs, "epub:type") or ""):lower()
    local role = (get_attr(attrs, "role") or ""):lower()
    local class = (get_attr(attrs, "class") or ""):lower()
    if epub_type:find("backlink", 1, true) or role:find("doc-backlink", 1, true)
        or class:find("backlink", 1, true) or class:find("backref", 1, true)
        or class:find("footnote-back", 1, true) or class:find("note-back", 1, true) then
        return false
    end
    if epub_type:find("noteref", 1, true) or role:find("doc-noteref", 1, true)
        or class:find("noteref", 1, true) or class:find("footnote", 1, true)
        or class:find("fn-ref", 1, true) then
        return true
    end

    local compact = strip_tags(inner):gsub("%s+", "")
    local marker = compact:match("^%[?%d+%]?$")
        or compact:match("^%(%d+%)$")
        or compact:match("^（%d+）$")
        or is_symbol_marker(compact)
    local normalized_file = tostring(file or "")
    local file_hint = normalized_file:find("note", 1, true)
        or normalized_file:match("%.x?html$")
    local anchor_hint = lower_anchor:find("note", 1, true)
        or lower_anchor:find("foot", 1, true)
        or lower_anchor:match("^fn[_%-]?%d+")
        or lower_anchor:match("^n[_%-]?%d+")
        or lower_anchor:match("^ref[_%-]?%d+")
    return marker and (file == "" or file_hint or anchor_hint) and true or false
end

local source_blocks
local local_note_range

local function collect_refs(links)
    local refs = {}
    for _i, link in ipairs(links) do
        local attrs, inner = link.attrs, link.inner
        local href = get_attr(attrs, "href")
        if href and looks_like_ref(attrs, href, inner) then
            local file, anchor = split_href(href)
            refs[#refs + 1] = {
                href = href,
                file = file,
                anchor = anchor,
                key = ref_key(file, anchor),
                ref_id = get_attr(attrs, "id"),
                display = ref_display(inner),
            }
        end
    end
    return refs
end

local BLOCK_TAGS = { "aside", "li", "p", "div", "section", "blockquote", "dd", "td" }

-- Cap on cleaned note text length in bytes (#text counts bytes, so this is
-- ~2000 CJK chars); genuine notes are far smaller, whole-chapter captures are
-- far larger.
local MAX_NOTE_TEXT_BYTES = 6000

local function remember_definition(definitions, anchor, inner)
    if not anchor or anchor == "" then return end
    local text = clean_note_text(inner)
    if text == "" or is_trivial_note(text) then return end
    if is_symbol_only(text) then return end
    -- Ancestor blocks spanning most of the chapter poison the definition;
    -- reject oversized candidates outright instead of storing them.
    if #text > MAX_NOTE_TEXT_BYTES then
        logger.warn("dropping oversized note candidate:",
            "anchor=", tostring(anchor), "bytes=", tostring(#text))
        return
    end
    local current = definitions[anchor]
    -- The true note content is the smallest region describing the anchor,
    -- so keep whichever candidate has the shortest cleaned text.
    if not current or #text < #current.text then
        definitions[anchor] = { text = text }
    end
end

local function collect_definitions(html, blocks, anchors, links)
    local definitions = {}
    html = tostring(html or "")
    for anchor, points in pairs(anchors) do
        for _i, point in ipairs(points) do
            for _j, block in ipairs(blocks) do
                if block.first <= point.first and point.first < block.last then
                    remember_definition(definitions, anchor, html:sub(block.open_last + 1, block.close_first - 1))
                elseif point.tag == "a" and point.last and point.last < block.first and block.tag == "p"
                    and html:sub(point.last + 1, block.first - 1):match("^%s*$") then
                    remember_definition(definitions, anchor, html:sub(block.open_last + 1, block.close_first - 1))
                end
            end
        end
    end
    for _i, link in ipairs(links) do
        local attrs, inner = link.attrs, link.inner
        remember_definition(definitions,
            get_attr(attrs, "id") or get_attr(attrs, "name"), inner)
    end
    return definitions
end

local function collect_anchor_presence(points)
    local anchors = {}
    for anchor in pairs(points) do if anchor ~= "" then anchors[anchor] = true end end
    return anchors
end

local function collect_definition_backlinks(blocks, links)
    local backlinks = {}
    for _i, block in ipairs(blocks) do
        local attrs = block.attrs
        local class = get_attr(attrs, "class") or ""
        local lower = class:lower()
        if has_token(class, "note") or lower:find("fncontent", 1, true)
            or has_token(get_attr(attrs, "epub:type"), "footnote")
            or has_token(get_attr(attrs, "role"), "doc-footnote") then
            for _j, link in ipairs(links) do
                local link_attrs, link_inner = link.attrs, link.inner
                local href = get_attr(link_attrs, "href")
                if link.first > block.first and link.last < block.last
                    and href and looks_like_ref(link_attrs, href, link_inner) then
                    local _, anchor = split_href(href)
                    if anchor then backlinks[anchor] = true end
                end
            end
        end
    end
    return backlinks
end

local function chapter_uid(chapter)
    return tostring(chapter and (chapter.chapterUid or chapter.uid) or "")
end

local function chapter_aliases(chapter)
    local aliases, seen = {}, {}
    local function add(value)
        local path = normalize_path(value)
        if path ~= "" and not seen[path] then
            seen[path] = true
            aliases[#aliases + 1] = path
            local base = basename(path)
            if base ~= "" and not seen[base] then
                seen[base] = true
                aliases[#aliases + 1] = base
            end
        end
    end
    if type(chapter) ~= "table" then return aliases end
    for _i, key in ipairs({ "href", "file", "filename", "fileName", "path", "chapterPath" }) do
        add(chapter[key])
    end
    for _i, value in ipairs(chapter.files or {}) do add(value) end
    local idx = tonumber(chapter.chapterIdx or chapter.index)
    if idx then
        add(string.format("chapter%d.xhtml", idx))
        add(string.format("text/chapter%d.xhtml", idx))
    end
    return aliases
end

function Footnotes.scan_chapter(html, chapter)
    html = tostring(html or "")
    local blocks, anchors, links = source_blocks(html)
    local refs = collect_refs(links)
    local forward_ref_ids = {}
    for _i, ref in ipairs(refs) do
        if ref.ref_id and ref.ref_id ~= "" then
            forward_ref_ids[ref.ref_id] = true
        end
    end
    local scan = {
        chapter_uid = chapter_uid(chapter),
        chapter = chapter,
        definitions = collect_definitions(html, blocks, anchors, links),
        anchors = collect_anchor_presence(anchors),
        anchor_counts = {},
        definition_backlinks = collect_definition_backlinks(blocks, links),
        refs = refs,
        forward_ref_ids = forward_ref_ids,
    }
    for anchor,points in pairs(anchors) do scan.anchor_counts[anchor]=#points end
    -- Cross-chapter references must carry the same full-markup safety check
    -- as local references; cleaned text alone cannot prove media is absent.
    for anchor, content in pairs(scan.definitions) do
        content.plain_safe = local_note_range(html, blocks, anchors, anchor, content, scan) ~= nil
    end
    return scan
end

local function put_exact(index, key, content)
    local existing = index.exact[key]
    if existing == nil then
        index.exact[key] = content
    elseif existing ~= content then
        index.exact[key] = false
    end
end

function Footnotes.build_book_index(scans, chapters, chapter_hrefs)
    local index = {
        exact = {},
        local_by_uid = {},
        unique = {},
        ambiguous = {},
        book_links = BookLinks.build(scans,chapters,chapter_hrefs),
    }
    local chapter_by_uid = {}
    for _i, chapter in ipairs(chapters or {}) do
        chapter_by_uid[chapter_uid(chapter)] = chapter
    end
    for raw_uid, scan in pairs(scans or {}) do
        local uid = tostring(raw_uid)
        local chapter = scan.chapter or chapter_by_uid[uid]
        index.local_by_uid[uid] = scan.definitions or {}
        local aliases = chapter_aliases(chapter)
        for anchor, content in pairs(scan.definitions or {}) do
            for _i, alias in ipairs(aliases) do
                put_exact(index, ref_key(alias, anchor), content)
            end
            if index.unique[anchor] == nil and not index.ambiguous[anchor] then
                index.unique[anchor] = content
            elseif index.unique[anchor] ~= content then
                index.unique[anchor] = nil
                index.ambiguous[anchor] = true
            end
        end
    end
    return index
end

local function resolve_ref(index, uid, file, anchor)
    if file == "" then
        local local_defs = index.local_by_uid[tostring(uid)] or {}
        if local_defs[anchor] then return local_defs[anchor] end
    else
        local exact = index.exact[ref_key(file, anchor)]
        if exact then return exact end
        local base = basename(file)
        exact = index.exact[ref_key(base, anchor)]
        if exact then return exact end
    end
    return index.unique[anchor]
end

local function image_is_footnote(tag)
    local class = get_attr(tag, "class") or ""
    local lower = class:lower()
    return has_token(class, "qqreader-footnote")
        or has_token(class, "footnote-icon")
        or has_token(class, "footnote-ref")
        or has_token(class, "note-ref")
        or lower == "footnote"
end

local function append_before_body_close(html, fragment)
    if fragment == "" then return html end
    local lower = html:lower()
    -- WeRead may concatenate multiple complete XHTML documents for one
    -- catalog chapter. Append to the final body so all source content stays
    -- before the generated notes.
    local start_pos
    local search_from = 1
    while true do
        local found = lower:find("</body>", search_from, true)
        if not found then break end
        start_pos = found
        search_from = found + 7
    end
    if start_pos then
        return html:sub(1, start_pos - 1) .. fragment .. html:sub(start_pos)
    end
    return html .. fragment
end

local function build_section(notes)
    if #notes == 0 then return "" end
    local out = { '\n<div class="wr-footnotes">\n<hr/>\n' }
    for _i, note in ipairs(notes) do
        local backlinks, aliases, keys = {}, {}, {}
        for _j, ref in ipairs(note.refs or { note }) do
            backlinks[#backlinks + 1] = string.format('<a href="#%s" class="wr-fn-num">%s</a>',
                ref.ref_id, xml_escape(ref.display))
        end
        for anchor in pairs(note.aliases or {}) do keys[#keys + 1] = anchor end
        table.sort(keys)
        for _j, anchor in ipairs(keys) do aliases[#aliases + 1] = '<span id="' .. xml_escape(anchor) .. '"></span>' end
        out[#out + 1] = string.format(
            '<aside epub:type="footnote" id="%s" class="wr-book-footnote">%s<p>%s %s</p></aside>\n',
            note.target_id, table.concat(aliases), table.concat(backlinks, " "), xml_escape(note.text))
    end
    out[#out + 1] = "</div>\n"
    return table.concat(out)
end

local function replace_href(attrs, href)
    local escaped = xml_escape(href)
    local replaced, count = attrs:gsub('(href%s*=%s*)"[^"]*"', function(prefix)
        return prefix .. '"' .. escaped .. '"'
    end, 1)
    if count > 0 then return replaced end
    replaced, count = attrs:gsub("(href%s*=%s*)'[^']*'", function(prefix)
        return prefix .. "'" .. escaped:gsub("'",'&apos;') .. "'"
    end, 1)
    return count > 0 and replaced or attrs
end

local VOID_TAGS = { area=true, base=true, br=true, col=true, embed=true, hr=true, img=true,
    input=true, link=true, meta=true, param=true, source=true, track=true, wbr=true }
local NOTE_BLOCK_TAGS = {}
for _i, tag in ipairs(BLOCK_TAGS) do NOTE_BLOCK_TAGS[tag] = true end

-- Ranges must be balanced, even with quoted '>' or nested same-name tags.
-- A malformed fragment never authorizes deleting an enclosing body block.
source_blocks = function(html)
    local blocks, anchors, links, images, stack, pos = {}, {}, {}, {}, {}, 1
    local lower = html:lower()
    while true do
        local first = html:find("<", pos, true)
        if not first then break end
        if html:sub(first, first + 3) == "<!--" then
            local last = html:find("-->", first + 4, true)
            if not last then break end
            pos = last + 3
        elseif html:sub(first, first + 8) == "<![CDATA[" then
            local last = html:find("]]>", first + 9, true)
            if not last then break end
            pos = last + 3
        else
            local at, quote = first + 1, nil
            while at <= #html do
                local char = html:sub(at, at)
                if quote then if char == quote then quote = nil end
                elseif char == '"' or char == "'" then quote = char
                elseif char == ">" then break end
                at = at + 1
            end
            if at > #html then break end
            local raw = html:sub(first, at)
            local closing, tag = raw:match("^<%s*(/?)%s*([%w:_%-]+)")
            tag = tag and tag:lower()
            pos = at + 1
            if tag and closing == "/" then
                local node = stack[#stack]
                if node and node.tag == tag then
                    stack[#stack] = nil
                    node.close_first, node.last = first, at
                    if NOTE_BLOCK_TAGS[tag] then blocks[#blocks + 1] = node end
                    if tag == "a" then
                        node.inner = html:sub(node.open_last + 1, first - 1)
                        links[#links + 1] = node
                    end
                else stack = {} end
            elseif tag and (tag == "script" or tag == "style") then
                local _, last = lower:find("</" .. tag .. "%s*>", pos)
                if not last then break end
                pos = last + 1
            elseif tag then
                local node = { first = first, open_last = at, tag = tag,
                    attrs = raw:match("^<%s*[%w:_%-]+(.-)>$") or "" }
                local anchor = get_attr(raw, "id") or get_attr(raw, "name")
                if anchor then
                    anchors[anchor] = anchors[anchor] or {}
                    anchors[anchor][#anchors[anchor] + 1] = node
                end
                if VOID_TAGS[tag] or raw:match("/%s*>$") then node.last = at
                else stack[#stack + 1] = node end
                if tag == "img" then images[#images + 1] = node end
            end
        end
    end
    table.sort(links, function(a, b) return a.first < b.first end)
    return blocks, anchors, links, images
end

local function rewrite_nodes(html, nodes, transform)
    local rewritten, from = {}, 1
    for _i, node in ipairs(nodes) do
        if node.first >= from then
            rewritten[#rewritten + 1] = html:sub(from, node.first - 1)
            rewritten[#rewritten + 1] = transform(node)
            from = node.last + 1
        end
    end
    rewritten[#rewritten + 1] = html:sub(from)
    return table.concat(rewritten)
end

local_note_range = function(html, blocks, anchors, anchor, content, scan)
    local best
    for _i, point in ipairs(anchors[anchor] or {}) do
        for _j, block in ipairs(blocks) do
            local contains = block.first <= point.first and point.first < block.last
            local adjacent = point.tag == "a" and point.last and block.tag == "p" and point.last < block.first
                and html:sub(point.last + 1, block.first - 1):match("^%s*$")
            if (contains or adjacent) and block.last - block.first <= 128 * 1024 then
                local inner = html:sub(block.open_last + 1, block.close_first - 1)
                -- Plain-text conversion must not discard embedded media or
                -- citations. Those targets retain their original native link.
                local rich
                for _k, name in ipairs({ "img", "svg", "math", "table", "object", "audio", "video" }) do
                    if inner:lower():find("<%s*" .. name .. "[%s/>]") then rich = true; break end
                end
                for attrs, label in inner:gmatch("<[aA]([^>]*)>(.-)</[aA]%s*>") do
                    local href = get_attr(attrs, "href")
                    local file, target = split_href(href or "")
                    local glyph = strip_tags(label)
                    local backlink = target and (glyph == "↩" or glyph == "↑" or glyph == "←" or glyph == "⤴"
                        or (scan.forward_ref_ids or {})[target]
                        or (scan.definition_backlinks or {})[target]
                        or ((scan.anchors or {})[target] and not (scan.definitions or {})[target]))
                    if href and (not backlink or file ~= "") then rich = true end
                end
                if not rich and clean_note_text(inner) == content.text then
                    local first = adjacent and point.first or block.first
                    if not best or block.last - first < best.last - best.first then
                        best = { first = first, last = block.last, aliases = {} }
                        for key, points in pairs(anchors) do
                            for _k, candidate in ipairs(points) do
                                if candidate.first >= first and candidate.first <= block.last then best.aliases[key] = true end
                            end
                        end
                    end
                end
            end
        end
    end
    if best then
        for _i, point in ipairs(anchors[anchor] or {}) do
            if point.first < best.first or point.first > best.last then return nil end
        end
    end
    return best
end

local function strip_consumed_note_blocks(html, notes)
    local ranges, seen = {}, {}
    for _i, note in ipairs(notes) do
        if note.range and not seen[note.range.first] then
            seen[note.range.first] = true
            ranges[#ranges + 1] = note.range
        end
    end
    table.sort(ranges, function(a, b) return a.first > b.first end)
    for _i, range in ipairs(ranges) do html = html:sub(1, range.first - 1) .. html:sub(range.last + 1) end
    return html, #ranges
end

function Footnotes.transform_chapter(html, scan, index)
    local stats = {
        candidates = 0,
        converted = 0,
        image_notes = 0,
        backlinks = 0,
        removed_note_blocks = 0,
        native_links = 0,
        unresolved = 0,
    }
    if type(html) ~= "string" or html == "" then return html, stats end
    local original = html
    scan = scan or { chapter_uid = "chapter", refs = {}, definitions = {} }
    index = index or Footnotes.build_book_index({ [scan.chapter_uid] = scan }, { scan.chapter })
    local uid = safe_id(scan.chapter_uid)
    local ordinal, notes = 0, {}
    local by_definition, by_range = {}, {}

    local _, _, _, images = source_blocks(html)
    html = rewrite_nodes(html, images, function(node)
        local tag = html:sub(node.first, node.last)
        if not image_is_footnote(tag) then return tag end
        local text = clean_note_text(get_attr(tag, "alt") or get_attr(tag, "title")
            or get_attr(tag, "data-content") or get_attr(tag, "data-note") or "")
        if text == "" then return tag end
        ordinal = ordinal + 1
        local target_id = string.format("wrfn-%s-%d", uid, ordinal)
        local ref_id = string.format("wrfnref-%s-%d", uid, ordinal)
        notes[#notes + 1] = {
            target_id = target_id, ref_id = ref_id,
            display = "[" .. tostring(ordinal) .. "]", text = text,
        }
        stats.image_notes = stats.image_notes + 1
        return string.format(
            '<span class="wr-fn-ref"><a epub:type="noteref" role="doc-noteref" href="#%s" id="%s">[%d]</a></span>',
            target_id, ref_id, ordinal)
    end)

    local blocks, anchors, links = source_blocks(html)
    local function transform_ref(attrs, inner)
        local href = get_attr(attrs, "href")
        local native,reason
        if href and index.book_links then native,reason=BookLinks.resolve(index.book_links,scan.chapter_uid,href) end
        local function keep(fallback)
            local target=native and native.href or fallback
            if target and target~=BookLinks.attribute(href) then
                stats.native_links=stats.native_links+1
                return '<a' .. replace_href(attrs,target) .. '>' .. inner .. '</a>'
            end
            return '<a' .. attrs .. '>' .. inner .. '</a>'
        end
        if not href or reason=='external' or reason=='invalid' or not looks_like_ref(attrs, href, inner) then
            return keep()
        end
        stats.candidates = stats.candidates + 1
        local file, anchor = split_href(href)
        local local_target=file=='' or native and native.uid==tostring(scan.chapter_uid)
        if native and native.forward_ref then stats.backlinks=stats.backlinks+1;return keep() end
        if local_target and ((scan.definition_backlinks and scan.definition_backlinks[anchor])
            or (scan.forward_ref_ids and scan.forward_ref_ids[anchor])
            or (scan.anchors and scan.anchors[anchor]
                and not (scan.definitions and scan.definitions[anchor]))) then
            stats.backlinks = stats.backlinks + 1
            return keep('#' .. anchor)
        end
        if file~='' and not native and index.book_links and index.book_links.packaged then
            stats.unresolved=stats.unresolved+1;return keep()
        end
        local content = resolve_ref(index, scan.chapter_uid, file or "", anchor)
        if content and file~='' and not local_target and content==(scan.definitions or {})[anchor] then
            stats.unresolved=stats.unresolved+1;return keep()
        end
        if not content or is_trivial_note(content.text) then
            if native then return keep() end
            if local_target and scan.anchors and scan.anchors[anchor] then
                stats.backlinks = stats.backlinks + 1
                return keep('#' .. anchor)
            end
            stats.unresolved = stats.unresolved + 1
            return "<a" .. attrs .. ">" .. inner .. "</a>"
        end
        local range, range_key
        if content ~= (scan.definitions or {})[anchor] and content.plain_safe ~= true then
            if native then return keep() end
            stats.unresolved = stats.unresolved + 1
            return '<a' .. attrs .. '>' .. inner .. '</a>'
        end
        if content == (scan.definitions or {})[anchor] then
            range = local_note_range(html, blocks, anchors, anchor, content, scan)
            if not range then
                stats.unresolved = stats.unresolved + 1
                return "<a" .. attrs .. ">" .. inner .. "</a>"
            end
            range_key = range.first .. ":" .. range.last
        end
        ordinal = ordinal + 1
        local ref_id = string.format("wrfnref-%s-%d", uid, ordinal)
        local display = ref_display(inner)
        local note = by_definition[content] or (range_key and by_range[range_key])
        if not note and range then
            for _i, existing in ipairs(notes) do
                if existing.range and existing.text == content.text
                    and range.first <= existing.range.last and existing.range.first <= range.last then
                    note = existing
                    if range.last - range.first > existing.range.last - existing.range.first then
                        note.range, note.source_anchor = range, anchor
                    end
                    for key in pairs(range.aliases) do note.aliases[key] = true end
                    break
                end
            end
        end
        if not note then
            note = { target_id = string.format("wrfn-%s-%d", uid, ordinal), text = content.text,
                refs = {}, range = range, aliases = range and range.aliases, source_anchor = range and anchor }
            notes[#notes + 1] = note
        end
        by_definition[content] = note
        if range_key then by_range[range_key] = note end
        note.refs[#note.refs + 1] = { ref_id = ref_id, display = display }
        stats.converted = stats.converted + 1
        local old_id = get_attr(attrs, "id") or get_attr(attrs, "name")
        return string.format(
            '<span class="wr-fn-ref"%s><a epub:type="noteref" role="doc-noteref" href="#%s" id="%s">%s</a></span>',
            old_id and ' id="' .. xml_escape(old_id) .. '"' or "", note.target_id, ref_id, xml_escape(display))
    end
    html = rewrite_nodes(html, links, function(link) return transform_ref(link.attrs, link.inner) end)

    -- Link rewriting changes byte offsets; resolve each consumed target again.
    blocks, anchors = source_blocks(html)
    for _i, note in ipairs(notes) do
        if note.source_anchor then
            note.range = local_note_range(html, blocks, anchors, note.source_anchor,
                { text = note.text }, scan)
            if not note.range then
                return original, { converted = 0, image_notes = 0, removed_note_blocks = 0,
                    candidates = stats.candidates, backlinks = 0, unresolved = #scan.refs, fallback = 1 }
            end
        end
    end
    for i, note in ipairs(notes) do
        for j = i + 1, #notes do
            local other = notes[j]
            if note.range and other.range and note.range.first <= other.range.last and other.range.first <= note.range.last then
                return original, { converted = 0, image_notes = 0, removed_note_blocks = 0,
                    candidates = stats.candidates, backlinks = 0, unresolved = #scan.refs, fallback = 1 }
            end
        end
    end
    html, stats.removed_note_blocks = strip_consumed_note_blocks(html, notes)
    return append_before_body_close(html, build_section(notes)), stats
end

function Footnotes.validate(html)
    if type(html) ~= "string" then return false, "chapter body is not a string" end
    local ids = {}
    for raw in html:gmatch("<[^>]+>") do
        if not raw:match("^<%s*/") then
            local id = get_attr(raw, "id")
            if id and (id:find("wrfn-", 1, true) == 1 or id:find("wrfnref-", 1, true) == 1) then
                if ids[id] then return false, "duplicate generated footnote id: " .. id end
                ids[id] = true
            end
        end
    end
    for attrs in html:gmatch("<[aA]([^>]*)>") do
        local href = get_attr(attrs, "href")
        local target = href and href:match("^#(wrfn[%w_.-]+)$")
        if target and not ids[target] then
            return false, "missing generated footnote target: " .. target
        end
    end
    return true
end

function Footnotes.has_converted(stats)
    return type(stats) == "table"
        and ((tonumber(stats.converted) or 0) + (tonumber(stats.image_notes) or 0) > 0)
end

function Footnotes.log_stats(stats)
    logger.info("processed:",
        "candidates=", tostring(stats and stats.candidates or 0),
        "converted=", tostring(stats and stats.converted or 0),
        "images=", tostring(stats and stats.image_notes or 0),
        "backlinks=", tostring(stats and stats.backlinks or 0),
        "removed_note_blocks=", tostring(stats and stats.removed_note_blocks or 0),
        "unresolved=", tostring(stats and stats.unresolved or 0))
end

return Footnotes
