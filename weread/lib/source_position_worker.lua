-- Pure source-position work plus independent bounded archive I/O. No native
-- document, UI, network, settings writes, or body data in the result pipe.
local Archive = require('weread.lib.source_archive')
local Coordinates = require('weread.lib.source_coordinates')
local Dom = require('weread.lib.source_dom')
local Identity = require('weread.lib.book_file_identity')
local Source = require('weread.lib.position_source')
local M = { MAX_CONTEXT_BYTES = 8192 }
local function boundaries(text)
    local points, at = {}, 1
    for char in text:gmatch('[%z\1-\127\194-\244][\128-\191]*') do points[#points + 1] = at; at = at + #char end
    points[#points + 1] = at
    return points
end
local function match(map, text, offset)
    local points = boundaries(text)
    local target = offset + 1
    for _, width in ipairs({24, 48, 96, 192}) do
        local first, last = math.max(1, target - width), math.min(#points, target + width)
        local quote = text:sub(points[first], points[last] - 1)
        local point = map:locate_point(quote, target - first)
        if point then
            local anchor = map:anchor(point.co)
            if anchor then
                local start = text:find(anchor.text, 1, true)
                if start and not text:find(anchor.text, start + 1, true) then
                    local reverse = boundaries(anchor.text)
                    if reverse[anchor.point_offset + 1]
                        and start + reverse[anchor.point_offset + 1] - 1 == points[target] then return point.co end
                end
            end
        end
    end
end
local function chapter_title(rendered)
    local title=rendered:match('<title>(.-)</title>')
    if not title then return nil end
    local entities={amp='&',lt='<',gt='>',quot='"',apos="'"}
    title=title:gsub('&(%a+);',function(name) return entities[name] or '&'..name..';' end):gsub('[%z%c]',' ')
    local chars={}
    for char in title:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
        if #chars>=80 then chars[#chars+1]='…';break end
        chars[#chars+1]=char
    end
    return table.concat(chars)
end
function M.capture(input, read_archive)
    local ok, result = pcall(function()
        if type(input) ~= 'table' or type(input.identity) ~= 'table' or type(input.text) ~= 'string'
            or #input.text > M.MAX_CONTEXT_BYTES or type(input.point_offset) ~= 'number'
            or input.point_offset < 0 or input.point_offset % 1 ~= 0 then return {error='context_invalid'} end
        local record = Source.decode_metadata(input.metadata)
        if not record or record.book_id ~= input.book_id
            or record.chapter_uid ~= input.chapter_uid or record.render_path ~= input.render_path
            or record.file_id ~= input.identity.file_id or record.book_version ~= input.identity.book_version then
            return {error='source_unavailable'}
        end
        if record.format ~= 'web_xhtml' then return {error='source_unsupported'} end
        local text = Dom.normalize(input.text)
        if text ~= input.text then return {error='context_invalid'} end
        local points = boundaries(text)
        if input.point_offset > #points - 1 then return {error='context_invalid'} end
        local alias = Source.path_meta_path(record.render_path)
        local raw_path = Source.raw_path(record.raw_sha256)
        local members = (read_archive or Archive.read)(input.file, {
            [Identity.PATH]=Identity.MAX_BYTES, [alias]=Source.MAX_META_BYTES,
            [raw_path]=Source.MAX_BYTES, [record.render_path]=Source.MAX_RENDERED_BYTES,
        })
        if not members or members[alias] ~= input.metadata then return {error='source_changed'} end
        local identity = Identity.decode(members[Identity.PATH])
        if not identity or identity.file_id ~= input.identity.file_id or identity.book_id ~= input.book_id then
            return {error='source_changed'}
        end
        local verified = Source.verify_snapshot({ metadata=members[alias], identity=identity,
            book_id=input.book_id, chapter_uid=input.chapter_uid, raw=members[raw_path], rendered=members[record.render_path] })
        if not verified then return {error='source_changed'} end
        local map = Coordinates.build(verified.raw)
        if not map then return {error='source_unsupported'} end
        local co = match(map, text, input.point_offset)
        if co == nil then return {error='context_unmatched'} end
        return { position={ book_id=record.book_id, chapter_uid=record.chapter_uid, chapter_offset=co,
            file_id=record.file_id, book_version=record.book_version, raw_sha256=record.raw_sha256,
            chapter_title=chapter_title(members[record.render_path]),
            render_path=record.render_path, basis='filtered_xhtml_utf16', upload_verified=false }, request_id=input.request_id }
    end)
    return ok and result or {error='position_unavailable'}
end
return M
