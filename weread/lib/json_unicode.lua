-- KOReader's Lua JSON decoder can emit UTF-8 encoded surrogate halves for a
-- valid JSON escape pair. Decode only actual pairs inside JSON strings before
-- passing the text to it; preserve escaped backslashes and malformed input.
local M={}
local function scalar(code)
    return string.char(240+math.floor(code/262144),128+math.floor(code/4096)%64,
        128+math.floor(code/64)%64,128+code%64)
end
function M.normalize(text)
    if type(text)~='string' then return text end
    -- Most responses contain no surrogate escapes; keep the full scan in C.
    if not text:find('\\u[dD][89aAbB]') then return text end
    local at,first,inside,parts,chunks=1,1,false,nil,nil
    while at<=#text do
        local char=text:byte(at)
        if char==34 then inside=not inside;at=at+1
        elseif inside and char==92 then
            local high,low
            if text:sub(at+1,at+1)=='u' and text:sub(at+6,at+7)=='\\u' then
                local a,b=text:sub(at+2,at+5),text:sub(at+8,at+11)
                if #a==4 and #b==4 and a:match('^%x%x%x%x$') and b:match('^%x%x%x%x$') then
                    high,low=tonumber(a,16),tonumber(b,16)
                end
            end
            if high and high>=0xD800 and high<=0xDBFF and low>=0xDC00 and low<=0xDFFF then
                parts=parts or {};parts[#parts+1]=text:sub(first,at-1)
                parts[#parts+1]=scalar(0x10000+(high-0xD800)*1024+(low-0xDC00))
                if #parts>=512 then
                    chunks=chunks or {};chunks[#chunks+1]=table.concat(parts);parts={}
                end
                at=at+12;first=at
            else at=at+2 end
        else at=at+1 end
    end
    if not parts then return text end
    parts[#parts+1]=text:sub(first)
    if not chunks then return table.concat(parts) end
    chunks[#chunks+1]=table.concat(parts);return table.concat(chunks)
end
return M
