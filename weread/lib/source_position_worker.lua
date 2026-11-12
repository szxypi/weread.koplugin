-- Pure source-position work plus independent bounded archive I/O. No native
-- document, UI, network or settings writes. Capture results are metadata-only;
-- target preparation returns one bounded quote transiently through the pipe.
-- XHTML upload preparation returns a separate twenty-scalar summary. Native
-- TXT excerpts remain exact raw slices, unverified and memory-only.
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
    local function attempt(first,last)
        local quote = text:sub(points[first], points[last] - 1)
        local point = map:locate_point(quote, target - first)
        if point then
            local anchor = map:anchor(point.co,{segment_only=true}) or map:anchor(point.co)
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
    local windows={}
    for _i, width in ipairs({24, 48, 96, 192}) do
        local first,last=math.max(1,target-width),math.min(#points,target+width)
        local found=attempt(first,last)
        if found~=nil then return found end
        windows[#windows+1]={target,last};windows[#windows+1]={first,target}
    end
    -- Moving footnotes can change one adjacent block. A one-sided quote must
    -- still be unique and reversible; conflicting exact results are refused.
    local resolved
    for _i,window in ipairs(windows) do
        local found=attempt(window[1],window[2])
        if found~=nil then
            if resolved~=nil and found~=resolved then return end
            resolved=found
        end
    end
    return resolved
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
local function verified_source(input, read_archive)
    if type(input) ~= 'table' or type(input.identity) ~= 'table' then return nil, 'source_unavailable' end
    local record = Source.decode_metadata(input.metadata)
    if not record or record.book_id ~= input.book_id or record.chapter_uid ~= input.chapter_uid
        or record.render_path ~= input.render_path or record.file_id ~= input.identity.file_id
        or record.book_version ~= input.identity.book_version then return nil, 'source_unavailable' end
    if not Source.coordinate_basis(record.format) then return nil, 'source_unsupported' end
    local alias, raw_path = Source.path_meta_path(record.render_path), Source.raw_path(record.raw_sha256)
    local members = (read_archive or Archive.read)(input.file, {
        [Identity.PATH]=Identity.MAX_BYTES, [alias]=Source.MAX_META_BYTES,
        [raw_path]=Source.MAX_BYTES, [record.render_path]=Source.MAX_RENDERED_BYTES,
    })
    if not members or members[alias] ~= input.metadata then return nil, 'source_changed' end
    local identity = Identity.decode(members[Identity.PATH])
    if not identity or identity.file_id ~= input.identity.file_id or identity.book_id ~= input.book_id then
        return nil, 'source_changed'
    end
    local verified = Source.verify_snapshot({ metadata=members[alias], identity=identity,
        book_id=input.book_id, chapter_uid=input.chapter_uid, raw=members[raw_path], rendered=members[record.render_path] })
    if not verified then return nil, 'source_changed' end
    local map = Coordinates.build(verified.raw,{format=record.format,allow_multiple_bodies=true})
    if not map then return nil, 'source_unsupported' end
    return { record=record, map=map, title=chapter_title(members[record.render_path]) }
end
local function position(prepared, co)
    local record = prepared.record
    return { book_id=record.book_id, chapter_uid=record.chapter_uid, chapter_offset=co,
        file_id=record.file_id, book_version=record.book_version, raw_sha256=record.raw_sha256,
        chapter_title=prepared.title, render_path=record.render_path,
        basis=prepared.map.basis, upload_verified=false }
end
function M.capture(input, read_archive)
    local ok, result = pcall(function()
        if type(input) ~= 'table' or type(input.text) ~= 'string'
            or #input.text > M.MAX_CONTEXT_BYTES or type(input.point_offset) ~= 'number'
            or input.point_offset < 0 or input.point_offset % 1 ~= 0 then return {error='context_invalid'} end
        local text = Dom.normalize(input.text)
        if text ~= input.text then return {error='context_invalid'} end
        local points = boundaries(text)
        if input.point_offset > #points - 1 then return {error='context_invalid'} end
        local prepared, why = verified_source(input, read_archive)
        if not prepared then return {error=why} end
        local co = match(prepared.map, text, input.point_offset)
        if co == nil then return {error='context_unmatched'} end
        return { position=position(prepared, co), request_id=input.request_id }
    end)
    return ok and result or {error='position_unavailable'}
end

-- Navigation needs one bounded quote in the memory pipe, never an entire
-- source chapter. It stays transient and must be checked against the live DOM.
local function target_source(input,read_archive)
    local target = type(input) == 'table' and input.target
    if type(target) ~= 'table' or not Source.is_coordinate_basis(target.basis)
        or target.upload_verified ~= false or type(target.chapter_offset) ~= 'number'
        or target.chapter_offset < 0 or target.chapter_offset % 1 ~= 0
        or target.chapter_offset > Source.MAX_BYTES * 8 then return {error='target_invalid'} end
    local prepared, why = verified_source(input, read_archive)
    if not prepared then return {error=why} end
    if target.basis ~= prepared.map.basis then return {error='target_changed'} end
    for _i, key in ipairs({'book_id','chapter_uid','file_id','book_version','raw_sha256','render_path'}) do
        if target[key] ~= prepared.record[key] then return {error='target_changed'} end
    end
    return prepared,target
end
function M.prepare_target(input, read_archive)
    local ok, result = pcall(function()
        local prepared,target=target_source(input,read_archive)
        if not target then return prepared end
        local anchor = prepared.map:anchor(target.chapter_offset,{segment_only=true}) or prepared.map:anchor(target.chapter_offset)
        if not anchor or #anchor.text > M.MAX_CONTEXT_BYTES then return {error='target_unavailable'} end
        return {position=position(prepared, target.chapter_offset), anchor=anchor, request_id=input.request_id}
    end)
    return ok and result or {error='position_unavailable'}
end

function M.prepare_upload(input,read_archive)
    local ok,result=pcall(function()
        local prepared,target=target_source(input,read_archive)
        if not target then return prepared end
        if prepared.record.format~='web_xhtml' then return {error='source_unsupported'} end
        local anchor=prepared.map:anchor(target.chapter_offset)
        if not anchor then return {error='target_unavailable'} end
        local chars,summary={},{}
        for char in anchor.text:gmatch('[%z\1-\127\194-\244][\128-\191]*') do chars[#chars+1]=char end
        for index=anchor.point_offset+1,math.min(#chars,anchor.point_offset+20) do summary[#summary+1]=chars[index] end
        local point=position(prepared,target.chapter_offset)
        local candidate,why=require('weread.lib.source_upload_candidate').project(point,table.concat(summary),input.chapters,input.percent)
        if not candidate then return {error=why} end
        return {request_id=input.request_id,position=point,candidate=candidate}
    end)
    return ok and result or {error='position_unavailable'}
end

-- No API, percent extrapolation or upload permission. The caller must still
-- bind a live reader point and independently validate any future cloud plan.
function M.prepare_native_excerpt(input,read_archive)
    local ok,result=pcall(function()
        local prepared,target=target_source(input,read_archive)
        if not target then return prepared end
        if prepared.record.format~='web_txt' then return {error='source_unsupported'} end
        local excerpt=prepared.map:literal_excerpt(target.chapter_offset)
        if not excerpt then return {error='target_unavailable'} end
        return {request_id=input.request_id,position=position(prepared,target.chapter_offset),excerpt=excerpt}
    end)
    return ok and result or {error='position_unavailable'}
end
return M
