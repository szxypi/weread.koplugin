-- Native filtered UTF-16 boundaries -> raw HTML rune ranges. Independently
-- verified in Python against 52 real highlights in five source chapters.
-- No network, reader movement, persistence or permission to submit a thought.
local Coordinates=require('weread.lib.source_coordinates')
local Raw=require('weread.lib.annotation_source')
local Dom=require('weread.lib.source_dom')
local Crypto=require('weread.lib.crypto')
local Protocol=require('weread.lib.protocol')
local M={MAX_QUOTE=4096}
local function fail(reason) error('selection_quote/'..reason,0) end
local function integer(value) return type(value)=='number' and value>=0 and value%1==0 and value<=16*1024*1024 end
local function boundary(map,co)
    if not integer(co) then fail('boundary') end
    local candidates,interior,flat={},false,1
    for _i,segment in ipairs(map.segments) do
        local at,cursor,text=1,segment[1],segment[2]
        while at<=#text do
            local clean,next_at,width=map:_token(text,at)
            if co==cursor then candidates[flat]=candidates[flat] or clean~='' end
            if clean~='' and co==cursor+width then candidates[flat+#clean]=true end
            if cursor<co and co<cursor+width then interior=true end
            at,cursor,flat=next_at,cursor+width,flat+#clean
        end
    end
    local point,count,visible=nil,0,false
    for at,shown in pairs(candidates) do point,count,visible=at,count+1,visible or shown end
    if interior or count~=1 or not visible then fail('boundary') end
    return point
end
-- A unique visible boundary is sufficient when the native context already
-- identifies the text. It need not include a moved neighboring footnote.
function M.boundary(map,co)
    local ok,value=pcall(boundary,map,co);return ok and value or nil
end
local function trim(text)
    local first,last
    for at,char in text:gmatch('()([%z\1-\127\194-\244][\128-\191]*)') do
        if Dom.normalize(char)~='' then first=first or at;last=at+#char-1 end
    end
    return first and text:sub(first,last) or ''
end
function M.project(raw,first,last,text)
    local ok,value=pcall(function()
        if type(text)~='string' or #text==0 or #text>M.MAX_QUOTE or text:find('[%z\1-\8\11-\31\127]')
            or Protocol.utf8_substr(text,#text)~=text then fail('text') end
        local map=Coordinates.build(raw,{allow_multiple_bodies=true});if not map then fail('source') end
        local begin,ending=boundary(map,first),boundary(map,last)
        if begin>=ending or Dom.normalize(text)~=map.flat:sub(begin,ending-1) then fail('selection') end
        local flat,pieces,chunks,start,stop=1,{},{},nil,nil
        local spans=Raw.index(raw,{body_only=true})
        for _i,span in ipairs(spans) do
            local at,offset=1,span[1]
            while at<=#span[3] do
                local token=span[3]:match('^[%z\1-\127\194-\244][\128-\191]*',at)
                local decoded=token
                if token=='&' then
                    token=span[3]:match('^&[^%s<&]+;',at)
                    if not token then fail('entity') end
                    decoded=require('util').htmlEntitiesToUtf8(token)
                end
                if not token then fail('source') end
                local clean=assert(Dom.normalize(decoded));local runes=0
                for _char in token:gmatch('[%z\1-\127\194-\244][\128-\191]*') do runes=runes+1 end
                if clean~='' then
                    if flat==begin then start=offset end
                    if flat+#clean==ending then stop=offset+runes end
                    pieces[#pieces+1]=clean
                    if #pieces>=256 then chunks[#chunks+1]=table.concat(pieces);pieces={} end
                end
                flat,offset,at=flat+#clean,offset+runes,at+#token
            end
        end
        chunks[#chunks+1]=table.concat(pieces)
        if table.concat(chunks)~=map.flat then fail('source_text') end
        if not start or not stop then fail('entity') end
        local range=tostring(start)..'-'..tostring(stop)
        local quote=trim(Raw.quote(spans,range))
        if quote=='' or #quote>M.MAX_QUOTE or Dom.normalize(quote)~=map.flat:sub(begin,ending-1) then fail('entity') end
        return {range=range,abstract=quote,raw_sha256=Crypto.sha256_hex(raw),raw_bytes=#raw}
    end)
    if ok then return value end
    return nil,type(value)=='string' and value:match('^selection_quote/[a-z_]+$') and value or 'selection_quote/unavailable'
end
return M
