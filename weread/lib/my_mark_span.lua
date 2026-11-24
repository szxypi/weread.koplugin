-- Exact raw HTML rune ranges -> both source boundaries. No guessed lengths,
-- whole-book text search, reader movement, persistence or network calls.
local Coordinates=require('weread.lib.source_coordinates')
local Raw=require('weread.lib.annotation_source')
local Dom=require('weread.lib.source_dom')
local Quote=require('weread.lib.selection_quote')
local Marks=require('weread.lib.my_cloud_marks')
local Crypto=require('weread.lib.crypto')
local Protocol=require('weread.lib.protocol')
local M={MAX_BATCH=8}
local function fail(reason) error('my_mark_span/'..reason,0) end
local function trim(text)
    local first,last
    for at,char in text:gmatch('()([%z\1-\127\194-\244][\128-\191]*)') do
        if Dom.normalize(char)~='' then first=first or at;last=at+#char-1 end
    end
    return first and text:sub(first,last) or ''
end
local function coordinate_map(raw,format,provider)
    if provider then return provider() end
    return Coordinates.build(raw,{format=format,allow_multiple_bodies=true})
end
local function source_length(raw)
    local length=0;for _char in raw:gsub('^\239\187\191',''):gmatch('[%z\1-\127\194-\244][\128-\191]*') do length=length+1 end
    return length
end
local function project_ranges(spans,ranges,expected)
    local flat=1;local parts,chunks={},{}
    for _i,span in ipairs(spans) do
        local at,offset=1,span[1]
        while at<=#span[3] do
            local token=span[3]:match('^[%z\1-\127\194-\244][\128-\191]*',at);local decoded=token
            if token=='&' then
                token=span[3]:match('^&[^%s<&]+;',at);if not token then fail('entity') end
                decoded=require('util').htmlEntitiesToUtf8(token)
            end
            if not token then fail('source') end
            local text=assert(Dom.normalize(decoded));local runes=0
            for _char in token:gmatch('[%z\1-\127\194-\244][\128-\191]*') do runes=runes+1 end
            if text~='' then
                for _j,range in ipairs(ranges) do
                    if range.first<=offset and offset+runes<=range.last then
                        range.start=range.start or flat;range.stop=flat+#text
                    end
                end
                parts[#parts+1]=text
                if #parts>=256 then chunks[#chunks+1]=table.concat(parts);parts={} end
            end
            flat,at,offset=flat+#text,at+#token,offset+runes
        end
    end
    chunks[#chunks+1]=table.concat(parts)
    if table.concat(chunks)~=expected then fail('quote') end
end
local function project(raw,book,chapter,row,format,map_provider,source_cache)
    local ok,value,prepared_map=pcall(function()
        if not Marks.display_id(book) or not Marks.id(chapter) or type(row)~='table' or row.type~=1
            or type(row.chapterUid)~='number' or tostring(row.chapterUid)~=chapter
            or type(row.markText)~='string' or #row.markText==0 or #row.markText>131072
            or row.bookId~=nil and tostring(row.bookId)~=book or row.book_id~=nil and tostring(row.book_id)~=book
            or row.markText:find('[%z\1-\8\11-\31\127]') or Protocol.utf8_substr(row.markText,#row.markText)~=row.markText then fail('scope') end
        local a,b
        if type(row.range)=='string' then a,b=row.range:match('^(%d+)%-(%d+)$') end
        if not a or #a>10 or #b>10 or tonumber(a)>=tonumber(b) or tonumber(b)>2147483647 then fail('range') end
        a,b=tonumber(a),tonumber(b)
        format=format or 'web_xhtml'
        if format=='web_txt' then
            local target=require('weread.lib.my_mark_target').project(raw,book,chapter,row,format)
            local map=coordinate_map(raw,format,map_provider)
            local clean=Dom.normalize(row.markText)
            if not target or not map or not clean or clean=='' then fail('quote') end
            map:_index()
            local start=Quote.boundary(map,target.chapter_offset)
            local stop=start and start+#clean
            if not start or map.flat:sub(start,stop-1)~=clean then fail('quote') end
            local last=map:_point(stop-1,true)
            if Quote.boundary(map,last)~=stop then fail('boundary') end
            return {first=target.chapter_offset,last=last,normalized_sha256=Crypto.sha256_hex(clean),
                normalized_bytes=#clean,raw_sha256=target.raw_sha256,raw_bytes=target.raw_bytes},map
        elseif format~='web_xhtml' then fail('source') end
        local map=coordinate_map(raw,format,map_provider);if not map then fail('source') end
        local length=source_cache and source_cache.length() or source_length(raw)
        if b>length then fail('range') end
        local spans=source_cache and source_cache.spans() or Raw.index(raw,{body_only=true})
        local quoted=Raw.quote(spans,row.range)
        local clean=Dom.normalize(row.markText)
        if not clean or clean=='' or trim(quoted)~=trim(row.markText) then fail('quote') end
        local bounds
        if source_cache then bounds=source_cache.bounds(row.range,map.flat)
        else bounds={first=a,last=b};project_ranges(spans,{bounds},map.flat) end
        local start,stop=bounds.start,bounds.stop
        if not start or not stop or map.flat:sub(start,stop-1)~=clean then fail('quote') end
        local first,last=map:_point(start),map:_point(stop-1,true)
        if Quote.boundary(map,first)~=start or Quote.boundary(map,last)~=stop then fail('boundary') end
        return {first=first,last=last,normalized_sha256=Crypto.sha256_hex(clean),normalized_bytes=#clean,
            raw_sha256=Crypto.sha256_hex(raw),raw_bytes=#raw},map
    end)
    if ok then return value,nil,prepared_map end
    return nil,type(value)=='string' and value:match('^my_mark_span/[a-z_]+$') and value or 'my_mark_span/unavailable'
end
function M.project(raw,book,chapter,row,format)
    local value,reason=project(raw,book,chapter,row,format)
    if value then return value end
    return nil,reason
end
local function inside_anchor(map,span,ending)
    local first,last=Quote.boundary(map,span.first),Quote.boundary(map,span.last)
    local text=map.flat:sub(first,last-1);local points={}
    for at in text:gmatch('()[%z\1-\127\194-\244][\128-\191]*') do points[#points+1]=at end
    points[#points+1]=#text+1
    for _i,width in ipairs({24,48,96,192}) do
        local a,b=ending and math.max(1,#points-width) or 1,ending and #points or math.min(#points,width+1)
        local quote=text:sub(points[a],points[b]-1)
        local found=map.flat:find(quote,1,true)
        if b-a>=12 and found==first+points[a]-1 and not map.flat:find(quote,found+1,true) then
            return {co=ending and span.last or span.first,text=quote,point_offset=ending and b-a or 0,
                point_unit='unicode_scalars',basis=map.basis}
        end
    end
end
local function prepare(raw,book,chapter,row,format,map_provider,source_cache)
    local span,reason,map=project(raw,book,chapter,row,format,map_provider,source_cache);if not span then return nil,reason end
    local first=inside_anchor(map,span,false) or map:anchor(span.first,{segment_only=true}) or map:anchor(span.first)
    local last=inside_anchor(map,span,true) or map:anchor(span.last,{segment_only=true}) or map:anchor(span.last)
    if not first or not last then return nil,'my_mark_span/anchor' end
    span.first_anchor,span.last_anchor=first,last;return span
end
function M.prepare(raw,book,chapter,row,format)
    return prepare(raw,book,chapter,row,format)
end
-- A batch is bound to one immutable source string and remains in the worker.
-- Invalid rows are kept separate; no caller-supplied coordinate map is trusted.
function M.prepare_batch(raw,book,chapter,rows,format)
    if type(rows)~='table' or #rows>M.MAX_BATCH then return nil,'my_mark_span/batch' end
    local map,attempted,raw_length,raw_spans,bounds_ready
    local ranges,by_range={},{}
    for _i,row in ipairs(rows) do
        local first,last
        if type(row)=='table' and row.type==1 and type(row.range)=='string' then
            first,last=row.range:match('^(%d+)%-(%d+)$')
            if first and #first<=10 and #last<=10 and tonumber(first)<tonumber(last)
                and tonumber(last)<=2147483647 and not by_range[row.range] then
                local range={first=tonumber(first),last=tonumber(last)}
                ranges[#ranges+1]=range;by_range[row.range]=range
            end
        end
    end
    local function get_map()
        if not attempted then
            attempted=true
            map=Coordinates.build(raw,{format=format or 'web_xhtml',allow_multiple_bodies=true})
        end
        return map
    end
    local source_cache={
        length=function()
            if not raw_length then raw_length=source_length(raw) end
            return raw_length
        end,
        spans=function()
            if not raw_spans then raw_spans=Raw.index(raw,{body_only=true}) end
            return raw_spans
        end,
        bounds=function(range,expected)
            if not bounds_ready then
                -- A failed projection must not leave partially computed ranges.
                for _i,item in ipairs(ranges) do item.start,item.stop=nil,nil end
                project_ranges(raw_spans,ranges,expected);bounds_ready=true
            end
            return by_range[range]
        end,
    }
    local result,reasons={},{}
    for index,row in ipairs(rows) do
        if type(row)=='table' and row.type==1 then
            result[index],reasons[index]=prepare(raw,book,chapter,row,format,get_map,source_cache)
        end
    end
    return result,reasons
end
return M
