-- Read-only TXT selection projection using the official web reader's observed
-- UTF-16 unit. Its candidate grants no authority for cloud writes.
local Coordinates=require('weread.lib.source_coordinates')
local Quote=require('weread.lib.selection_quote')
local Dom=require('weread.lib.source_dom')
local Raw=require('weread.lib.annotation_source')
local Crypto=require('weread.lib.crypto')
local Protocol=require('weread.lib.protocol')
local M={}
local function fail(reason) error('selection_txt_quote/'..reason,0) end
local function integer(value)
    return type(value)=='number' and value==value and value%1==0 and value>=0 and value<=Coordinates.MAX_BYTES*2
end
local function trim(text)
    local first,last,first_index,last_index,total=nil,nil,nil,nil,0
    for at,char in text:gmatch('()([%z\1-\127\194-\244][\128-\191]*)') do
        total=total+1
        if Dom.normalize(char)~='' then
            first=first or at;first_index=first_index or total;last=at+#char-1;last_index=total
        end
    end
    return first and text:sub(first,last) or '',first_index and first_index-1 or 0,last_index and total-last_index or 0
end
local function positions(raw,first,last)
    local units,runes,first_rune,last_rune=0,0,nil,nil
    local bom=raw:sub(1,3)=='\239\187\191'
    for at,char in raw:gmatch('()([%z\1-\127\194-\244][\128-\191]*)') do
        if units==first and not (bom and at==1) then first_rune=runes end
        if units==last and not (bom and at==1) then last_rune=runes end
        local width=#char==4 and 2 or 1
        if first>units and first<units+width or last>units and last<units+width then fail('boundary') end
        units=units+width
        if not (bom and at==1) then runes=runes+1 end
    end
    if units==first then first_rune=runes end
    if units==last then last_rune=runes end
    if not first_rune or not last_rune or first_rune>=last_rune then fail('boundary') end
    return first_rune,last_rune
end
function M.project(raw,first,last,text)
    local ok,value=pcall(function()
        if not integer(first) or not integer(last) or first>=last then fail('boundary') end
        if type(text)~='string' or #text==0 or #text>Quote.MAX_QUOTE
            or text:find('[%z\1-\8\11\12\14-\31\127]') or Protocol.utf8_substr(text,#text)~=text then fail('text') end
        local map=Coordinates.build(raw,{format='web_txt'});if not map then fail('source') end
        local begin,ending=Quote.boundary(map,first),Quote.boundary(map,last)
        if not begin or not ending or begin>=ending or Dom.normalize(text)~=map.flat:sub(begin,ending-1) then fail('selection') end
        local start,stop=positions(raw,first,last)
        local spans=Raw.plain(raw)
        local quote,leading,trailing=trim(Raw.quote(spans,tostring(start)..'-'..tostring(stop)))
        if quote=='' or #quote>Quote.MAX_QUOTE or Dom.normalize(quote)~=map.flat:sub(begin,ending-1) then fail('selection') end
        start,stop=start+leading,stop-trailing
        if Raw.quote(spans,tostring(start)..'-'..tostring(stop))~=quote then fail('selection') end
        -- Native TXT coordinates include a leading BOM; official range
        -- candidates exclude it. Trimmed whitespace is always BMP.
        local bom=raw:sub(1,3)=='\239\187\191' and 1 or 0
        local range=tostring(first-bom+leading)..'-'..tostring(last-bom-trailing)
        return {range=range,abstract=quote,raw_sha256=Crypto.sha256_hex(raw),raw_bytes=#raw}
    end)
    if ok then return value end
    return nil,type(value)=='string' and value:match('^selection_txt_quote/[a-z_]+$') or 'selection_txt_quote/unavailable'
end

-- Reconstruct a draft from its canonical official UTF-16 range. The source
-- record, book identity and digest must be independently verified by callers.
function M.extract(raw,range)
    local ok,value=pcall(function()
        local a,b
        if type(range)=='string' then a,b=range:match('^(%d+)%-(%d+)$') end
        if not a or #a>10 or #b>10 or tostring(tonumber(a))~=a or tostring(tonumber(b))~=b then fail('boundary') end
        a,b=tonumber(a),tonumber(b)
        if not integer(a) or not integer(b) or a>=b then fail('boundary') end
        if not Coordinates.build(raw,{format='web_txt'}) then fail('source') end
        local source=raw:gsub('^\239\187\191','');local units,start,ending=0,nil,nil
        for at,char in source:gmatch('()([%z\1-\127\194-\244][\128-\191]*)') do
            if units==a then start=at end
            if units==b then ending=at end
            units=units+(#char==4 and 2 or 1)
        end
        if units==a then start=#source+1 end
        if units==b then ending=#source+1 end
        if not start or not ending or start>=ending then fail('boundary') end
        local text=source:sub(start,ending-1)
        if #text==0 or #text>Quote.MAX_QUOTE then fail('text') end
        return text
    end)
    if ok then return value end
    return nil,type(value)=='string' and value:match('^selection_txt_quote/[a-z_]+$') or 'selection_txt_quote/unavailable'
end

-- Resolve native endpoint contexts against one raw TXT source. This helper is
-- intentionally unbound to a book or archive; callers must establish those
-- identities separately before considering its result for any operation.
function M.project_context(raw,first,last,text,omit_initial_bom)
    local ok,value=pcall(function()
        local map=Coordinates.build(raw,{format='web_txt',omit_initial_bom=omit_initial_bom});if not map then fail('source') end
        local normalized=Dom.normalize(text)
        if type(normalized)~='string' or normalized=='' or type(text)~='string' or #text>Quote.MAX_QUOTE then fail('text') end
        local function endpoint(context)
            if type(context)~='table' then fail('selection') end
            local anchor,offset=context.text,context.point_offset
            if type(anchor)~='string' or #anchor>8192 or Dom.normalize(anchor)~=anchor
                or not integer(offset) then fail('selection') end
            local points={};for at in anchor:gmatch('()[%z\1-\127\194-\244][\128-\191]*') do points[#points+1]=at end
            points[#points+1]=#anchor+1
            if offset>=#points then fail('selection') end
            local found={};local target=offset+1
            local function attempt(a,b)
                local sample=anchor:sub(points[a],points[b]-1)
                local located=map:locate(sample)
                if not located then return end
                local point=map:locate_point(sample,target-a)
                local byte=point and Quote.boundary(map,point.co)
                if byte and byte==located.first+points[target]-points[a] then found[byte]=point.co end
            end
            for _i,width in ipairs({24,48,96,192}) do
                local a,b=math.max(1,target-width),math.min(#points,target+width)
                attempt(a,b);attempt(target,b);attempt(a,target)
            end
            if not next(found) then fail('selection') end
            return found
        end
        local starts,ends=endpoint(first),endpoint(last);local choices={}
        for first_byte,start in pairs(starts) do
            for last_byte,stop in pairs(ends) do
                if first_byte<last_byte and map.flat:sub(first_byte,last_byte-1)==normalized then
                    local result=M.project(raw,start,stop,text)
                    if result then choices[result.range]=result end
                end
            end
        end
        local result,count=nil,0;for _range,row in pairs(choices) do result,count=row,count+1 end
        if count~=1 then fail(count==0 and 'selection' or 'ambiguous') end
        return result
    end)
    if ok then return value end
    return nil,type(value)=='string' and value:match('^selection_txt_quote/[a-z_]+$') or 'selection_txt_quote/unavailable'
end
return M
