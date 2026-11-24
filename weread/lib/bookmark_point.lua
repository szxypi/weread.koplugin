-- Exact source-bound point bookmarks. The type-0 native endpoint and CRLF
-- preview were independently verified before this Lua implementation.
local Coordinates=require('weread.lib.source_coordinates')
local Quote=require('weread.lib.selection_quote')
local Raw=require('weread.lib.annotation_source')
local Dom=require('weread.lib.source_dom')
local Marks=require('weread.lib.my_cloud_marks')
local Crypto=require('weread.lib.crypto')
local Protocol=require('weread.lib.protocol')
local M={MAX_BATCH=8}
local function fail(reason) error('bookmark_point/'..reason,0) end
function M.point(value)
    if type(value)~='string' or #value>10 or not value:match('^%d+$') then return nil end
    local at=tonumber(value)
    return at<=2147483647 and tostring(at)==value and at or nil
end
local function imported_preview(row)
    if type(row)~='table' or type(row.markText)~='string' or #row.markText>131072
        or row.markText:find('[%z\1-\8\11\12\14-\31\127]')
        or Protocol.utf8_substr(row.markText,#row.markText)~=row.markText then return nil end
    local text=Dom.normalize(row.markText)
    if not text then return nil end
    local count=0
    for _char in text:gmatch('[%z\1-\127\194-\244][\128-\191]*') do count=count+1 end
    if count<12 then return nil end
    return text
end
function M.can_locate(row,require_preview)
    return type(row)=='table' and row.type==0 and type(row.chapterUid)=='number'
        and row.chapterUid>=1 and row.chapterUid<=2147483647 and row.chapterUid%1==0 and M.point(row.range)~=nil
        and (not require_preview or imported_preview(row)~=nil)
end
local function trim(text)
    local first,last
    for at,char in text:gmatch('()([%z\1-\127\194-\244][\128-\191]*)') do
        if Dom.normalize(char)~='' then first=first or at;last=at+#char-1 end
    end
    return first and text:sub(first,last) or ''
end
local function finish_scan(raw,map,found,point,byte,preview)
    if found~=1 or not byte then fail('point') end
    local co=map:_point(byte)
    if Quote.boundary(map,co)~=byte then fail('boundary') end
    local text=trim(table.concat(preview))
    if text=='' or #text>4096 or text:find('[%z\1-\8\11\12\14-\31\127]') then fail('preview') end
    return {range=tostring(point),markText=text,chapter_offset=co,raw_sha256=Crypto.sha256_hex(raw),raw_bytes=#raw},byte
end
local function scan(raw,map,wanted_raw,wanted_flat,spans_provider)
    local flat,found,point,byte=1,0,nil,nil
    local chunks,pieces,preview={}, {}, {};local count=0
    local spans=spans_provider and spans_provider() or Raw.index(raw,{body_only=true})
    for _i,span in ipairs(spans) do
        local at,offset=1,span[1]
        while at<=#span[3] do
            local token=span[3]:match('^[%z\1-\127\194-\244][\128-\191]*',at);local decoded=token
            if token=='&' then
                token=span[3]:match('^&[^%s<&]+;',at);if not token then fail('entity') end
                decoded=require('util').htmlEntitiesToUtf8(token)
            end
            if not token then fail('source') end
            local clean=assert(Dom.normalize(decoded));local runes=0
            for _char in token:gmatch('[%z\1-\127\194-\244][\128-\191]*') do runes=runes+1 end
            if clean~='' then
                if wanted_raw==offset or wanted_flat==flat then
                    local n=0;for _char in clean:gmatch('[%z\1-\127\194-\244][\128-\191]*') do n=n+1 end
                    if n~=1 then fail('entity') end
                    found,point,byte=found+1,offset,flat
                end
                pieces[#pieces+1]=clean
                if #pieces>=256 then chunks[#chunks+1]=table.concat(pieces);pieces={} end
            end
            if point~=nil and count<140 then
                for char in decoded:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
                    if count>=140 then break end;preview[#preview+1]=char;count=count+1
                end
            end
            at,offset,flat=at+#token,offset+runes,flat+#clean
        end
    end
    chunks[#chunks+1]=table.concat(pieces)
    if table.concat(chunks)~=map.flat then fail('point') end
    return finish_scan(raw,map,found,point,byte,preview)
end
-- Calculate up to eight requested point previews in one pass. A malformed
-- target does not invalidate neighboring targets; source errors still do.
local function scan_batch(raw,map,spans,states)
    local flat=1;local chunks,pieces,active={},{},{}
    for _i,span in ipairs(spans) do
        local at,offset=1,span[1]
        while at<=#span[3] do
            local token=span[3]:match('^[%z\1-\127\194-\244][\128-\191]*',at);local decoded=token
            if token=='&' then
                token=span[3]:match('^&[^%s<&]+;',at);if not token then fail('entity') end
                decoded=require('util').htmlEntitiesToUtf8(token)
            end
            if not token then fail('source') end
            local clean=assert(Dom.normalize(decoded));local runes=0
            for _char in token:gmatch('[%z\1-\127\194-\244][\128-\191]*') do runes=runes+1 end
            if clean~='' then
                local state=states[offset]
                if state then
                    local n=0;for _char in clean:gmatch('[%z\1-\127\194-\244][\128-\191]*') do n=n+1 end
                    if n~=1 then state.entity=true
                    else
                        state.found=state.found+1;state.point,state.byte=offset,flat
                        if state.found==1 then active[#active+1]=state end
                    end
                end
                pieces[#pieces+1]=clean
                if #pieces>=256 then chunks[#chunks+1]=table.concat(pieces);pieces={} end
            end
            for i=#active,1,-1 do
                local state=active[i]
                for char in decoded:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
                    if state.count>=140 then break end
                    state.preview[#state.preview+1]=char;state.count=state.count+1
                end
                if state.count>=140 then table.remove(active,i) end
            end
            at,offset,flat=at+#token,offset+runes,flat+#clean
        end
    end
    chunks[#chunks+1]=table.concat(pieces)
    if table.concat(chunks)~=map.flat then fail('point') end
end
local function guarded(task)
    local ok,value=pcall(task)
    if ok then return value end
    return nil,type(value)=='string' and value:match('^bookmark_point/[a-z_]+$') and value or 'bookmark_point/unavailable'
end
local function source_map(raw,format,provider)
    if provider then return provider() end
    return Coordinates.build(raw,{format=format,allow_multiple_bodies=true})
end
local function txt_project(raw,co)
    local map=Coordinates.build(raw,{format='web_txt'});if not map then fail('source') end
    map:_index()
    local byte=Quote.boundary(map,co);if not byte or byte>#map.flat then fail('boundary') end
    local canonical=map:_point(byte)
    local bom=raw:sub(1,3)=='\239\187\191' and 1 or 0
    local source=raw:gsub('^\239\187\191','');local point=canonical-bom
    if point<0 then fail('boundary') end
    local units,start,ending,count=0,nil,nil,0
    for at,char in source:gmatch('()([%z\1-\127\194-\244][\128-\191]*)') do
        if units==point then start=at end
        if start then
            count=count+1;ending=at+#char-1
            if count>=140 then break end
        end
        units=units+(#char==4 and 2 or 1)
    end
    if not start or not ending then fail('boundary') end
    local text=trim(source:sub(start,ending));local preview=imported_preview({markText=text})
    if not preview or #text>4096 or map.flat:sub(byte,byte+#preview-1)~=preview
        or map.flat:find(preview,1,true)~=byte or map.flat:find(preview,byte+1,true) then fail('preview') end
    if not (map:anchor(canonical,{segment_only=true}) or map:anchor(canonical)) then fail('anchor') end
    return {range=tostring(point),markText=text,chapter_offset=canonical,raw_sha256=Crypto.sha256_hex(raw),raw_bytes=#raw}
end
function M.project(raw,co,format)
    return guarded(function()
        format=format or 'web_xhtml'
        if format=='web_txt' then return txt_project(raw,co) end
        if format~='web_xhtml' then fail('source') end
        local map=Coordinates.build(raw,{allow_multiple_bodies=true});if not map then fail('source') end
        local byte=Quote.boundary(map,co);if not byte or byte>#map.flat then fail('boundary') end
        return scan(raw,map,nil,byte)
    end)
end
local function txt_point(raw,book,chapter,row,map_provider)
    local preview=imported_preview(row)
    if not preview then fail('preview') end
    local map=source_map(raw,'web_txt',map_provider);if not map then fail('source') end
    map:_index()
    local marker=M.point(row.range);local source=raw:gsub('^\239\187\191','')
    local bom=raw:sub(1,3)=='\239\187\191' and 1 or 0
    local units,runes,scalar=0,0,nil
    for _at,char in source:gmatch('()([%z\1-\127\194-\244][\128-\191]*)') do
        if runes==marker then scalar=units end
        units=units+(#char==4 and 2 or 1);runes=runes+1
    end
    if runes==marker then scalar=units end
    local candidates={}
    local function attempt(co)
        if not co then return end
        local byte=Quote.boundary(map,co)
        if byte and map.flat:sub(byte,byte+#preview-1)==preview and map.flat:find(preview,1,true)==byte
            and not map.flat:find(preview,byte+1,true) then
            -- Adjacent whitespace can make two raw boundaries identify the
            -- same visible start. Canonicalize to the actual next character.
            local canonical=map:_point(byte)
            if map:anchor(canonical,{segment_only=true}) or map:anchor(canonical) then candidates[canonical]=true end
        end
    end
    attempt(marker+bom);if scalar then attempt(scalar+bom) end
    local co,count=nil,0;for point in pairs(candidates) do co,count=point,count+1 end
    if count~=1 then fail(count==0 and 'preview' or 'ambiguous') end
    return {book_id=book,chapter_uid=chapter,chapter_offset=co,raw_sha256=Crypto.sha256_hex(raw),
        raw_bytes=#raw,basis='raw_txt_utf16',upload_verified=false}
end
local function from_mark(raw,book,chapter,row,format,map_provider,spans_provider,point_provider)
    return guarded(function()
        local imported=not Marks.id(book)
        if not Marks.display_id(book) or not Marks.id(chapter) or not M.can_locate(row,imported) or tostring(row.chapterUid)~=chapter
            or row.bookId~=nil and tostring(row.bookId)~=book or row.book_id~=nil and tostring(row.book_id)~=book then fail('scope') end
        format=format or 'web_xhtml'
        if format=='web_txt' then return txt_point(raw,book,chapter,row,map_provider) end
        if format~='web_xhtml' then fail('source') end
        local map=source_map(raw,'web_xhtml',map_provider);if not map then fail('source') end
        local value,byte
        if point_provider then value,byte=point_provider(M.point(row.range),map)
        else value,byte=scan(raw,map,M.point(row.range),nil,spans_provider) end
        if value.range~=row.range then fail('point') end
        if row.markText~=nil and row.markText~='' then
            if type(row.markText)~='string' or #row.markText>131072 or Protocol.utf8_substr(row.markText,#row.markText)~=row.markText then fail('preview') end
            local text=Dom.normalize(row.markText)
            if not text or text=='' or map.flat:sub(byte,byte+#text-1)~=text then fail('preview') end
            if imported and (not imported_preview(row) or map.flat:find(text,1,true)~=byte
                or map.flat:find(text,byte+1,true)) then fail('preview') end
        end
        if not (map:anchor(value.chapter_offset,{segment_only=true}) or map:anchor(value.chapter_offset)) then fail('anchor') end
        return {book_id=book,chapter_uid=chapter,chapter_offset=value.chapter_offset,raw_sha256=value.raw_sha256,
            raw_bytes=value.raw_bytes,basis='filtered_xhtml_utf16',upload_verified=false}
    end)
end
function M.from_mark(raw,book,chapter,row,format)
    return from_mark(raw,book,chapter,row,format)
end
-- A reversible unique anchor is also used by the independent reader layer.
-- No text range is invented for a point bookmark.
local function prepare(raw,book,chapter,row,format,map_provider,spans_provider,point_provider)
    return guarded(function()
        local point=from_mark(raw,book,chapter,row,format,map_provider,spans_provider,point_provider);if not point then fail('point') end
        local map=map_provider();if not map then fail('source') end
        local anchor=map:anchor(point.chapter_offset,{segment_only=true}) or map:anchor(point.chapter_offset)
        if not anchor then fail('anchor') end
        return {anchor=anchor}
    end)
end
local function source_providers(raw,format)
    local map,attempted,spans
    return function()
        if not attempted then
            attempted=true;map=Coordinates.build(raw,{format=format or 'web_xhtml',allow_multiple_bodies=true})
        end
        return map
    end,function()
        if not spans then spans=Raw.index(raw,{body_only=true}) end
        return spans
    end
end
function M.prepare(raw,book,chapter,row,format)
    local map,spans=source_providers(raw,format)
    return prepare(raw,book,chapter,row,format,map,spans)
end
-- Batch resources are limited to the one verified source supplied by the worker.
function M.prepare_batch(raw,book,chapter,rows,format)
    if type(rows)~='table' or #rows>M.MAX_BATCH then return nil,'bookmark_point/batch' end
    local map,spans=source_providers(raw,format);local values,reasons={},{}
    local wanted,ready={}
    for _i,row in ipairs(rows) do
        if type(row)=='table' and row.type==0 then
            local marker=M.point(row.range)
            if marker and not wanted[marker] then wanted[marker]={found=0,count=0,preview={}} end
        end
    end
    local function get_point(marker,source_map_value)
        if not ready then
            -- Clear partial state if a previous source scan failed.
            for _marker,state in pairs(wanted) do
                state.found,state.count,state.preview,state.entity=0,0,{},nil
                state.point,state.byte=nil,nil
            end
            scan_batch(raw,source_map_value,spans(),wanted);ready=true
        end
        local state=wanted[marker];if not state then fail('point') end
        if state.entity then fail('entity') end
        return finish_scan(raw,source_map_value,state.found,state.point,state.byte,state.preview)
    end
    for i,row in ipairs(rows) do
        if type(row)=='table' and row.type==0 then values[i],reasons[i]=prepare(raw,book,chapter,row,format,map,spans,get_point) end
    end
    return values,reasons
end
return M
