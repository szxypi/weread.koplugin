-- Exact raw HTML rune ranges -> both source boundaries. No guessed lengths,
-- whole-book text search, reader movement, persistence or network calls.
local Coordinates=require('weread.lib.source_coordinates')
local Raw=require('weread.lib.annotation_source')
local Dom=require('weread.lib.source_dom')
local Quote=require('weread.lib.selection_quote')
local Marks=require('weread.lib.my_cloud_marks')
local Crypto=require('weread.lib.crypto')
local Protocol=require('weread.lib.protocol')
local M={}
local function fail(reason) error('my_mark_span/'..reason,0) end
local function trim(text)
    local first,last
    for at,char in text:gmatch('()([%z\1-\127\194-\244][\128-\191]*)') do
        if Dom.normalize(char)~='' then first=first or at;last=at+#char-1 end
    end
    return first and text:sub(first,last) or ''
end
function M.project(raw,book,chapter,row)
    local ok,value=pcall(function()
        if not Marks.id(book) or not Marks.id(chapter) or type(row)~='table' or row.type~=1
            or type(row.chapterUid)~='number' or tostring(row.chapterUid)~=chapter
            or type(row.markText)~='string' or #row.markText==0 or #row.markText>131072
            or row.bookId~=nil and tostring(row.bookId)~=book or row.book_id~=nil and tostring(row.book_id)~=book
            or row.markText:find('[%z\1-\8\11-\31\127]') or Protocol.utf8_substr(row.markText,#row.markText)~=row.markText then fail('scope') end
        local a,b
        if type(row.range)=='string' then a,b=row.range:match('^(%d+)%-(%d+)$') end
        if not a or #a>10 or #b>10 or tonumber(a)>=tonumber(b) or tonumber(b)>2147483647 then fail('range') end
        a,b=tonumber(a),tonumber(b)
        local map=Coordinates.build(raw,{allow_multiple_bodies=true});if not map then fail('source') end
        local length=0;for _char in raw:gsub('^\239\187\191',''):gmatch('[%z\1-\127\194-\244][\128-\191]*') do length=length+1 end
        if b>length then fail('range') end
        local spans=Raw.index(raw,{body_only=true});local quoted=Raw.quote(spans,row.range)
        local clean=Dom.normalize(row.markText)
        if not clean or clean=='' or trim(quoted)~=trim(row.markText) then fail('quote') end
        local flat,start,stop=1,nil,nil;local parts,chunks={},{}
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
                    if a<=offset and offset+runes<=b then start=start or flat;stop=flat+#text end
                    parts[#parts+1]=text
                    if #parts>=256 then chunks[#chunks+1]=table.concat(parts);parts={} end
                end
                flat,at,offset=flat+#text,at+#token,offset+runes
            end
        end
        chunks[#chunks+1]=table.concat(parts)
        if table.concat(chunks)~=map.flat or not start or not stop or map.flat:sub(start,stop-1)~=clean then fail('quote') end
        local first,last=map:_point(start),map:_point(stop-1,true)
        if Quote.boundary(map,first)~=start or Quote.boundary(map,last)~=stop then fail('boundary') end
        return {first=first,last=last,normalized_sha256=Crypto.sha256_hex(clean),normalized_bytes=#clean,
            raw_sha256=Crypto.sha256_hex(raw),raw_bytes=#raw},map
    end)
    if ok then return value end
    return nil,type(value)=='string' and value:match('^my_mark_span/[a-z_]+$') and value or 'my_mark_span/unavailable'
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
function M.prepare(raw,book,chapter,row)
    local span,reason=M.project(raw,book,chapter,row);if not span then return nil,reason end
    local map=Coordinates.build(raw,{allow_multiple_bodies=true});if not map then return nil,'my_mark_span/source' end
    local first=inside_anchor(map,span,false) or map:anchor(span.first,{segment_only=true}) or map:anchor(span.first)
    local last=inside_anchor(map,span,true) or map:anchor(span.last,{segment_only=true}) or map:anchor(span.last)
    if not first or not last then return nil,'my_mark_span/anchor' end
    span.first_anchor,span.last_anchor=first,last;return span
end
return M
