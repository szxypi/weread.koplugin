-- Bound image dimensions before handing untrusted image data to a decoder.
local M={MAX_BYTES=3*1024*1024,MAX_SIDE=5000,MAX_PIXELS=16000000}
local function be16(s,i) local a,b=s:byte(i,i+1);return b and a*256+b end
local function le16(s,i) local a,b=s:byte(i,i+1);return b and a+b*256 end
local function be32(s,i) local a,b,c,d=s:byte(i,i+3);return d and ((a*256+b)*256+c)*256+d end
local function le24(s,i) local a,b,c=s:byte(i,i+2);return c and a+b*256+c*65536 end
function M.dimensions(data)
    if type(data)~='string' or #data<16 or #data>M.MAX_BYTES then return nil end
    local width,height,kind
    if data:sub(1,8)=='\137PNG\r\n\26\n' and data:sub(13,16)=='IHDR' then
        width,height,kind=be32(data,17),be32(data,21),'png'
    elseif data:sub(1,6)=='GIF87a' or data:sub(1,6)=='GIF89a' then
        width,height,kind=le16(data,7),le16(data,9),'gif'
    elseif data:sub(1,3)=='\255\216\255' then
        local index=3
        while index<#data do
            if data:byte(index)~=255 then return nil end
            while data:byte(index)==255 do index=index+1 end
            local marker=data:byte(index);index=index+1
            if not marker or marker==0 or marker==217 or marker==218 then break end
            if marker~=1 and not (marker>=208 and marker<=215) then
                local size=be16(data,index)
                if not size or size<2 or index+size-1>#data then return nil end
                if marker>=192 and marker<=207 and marker~=196 and marker~=200 and marker~=204 then
                    if size<8 then return nil end
                    height,width,kind=be16(data,index+3),be16(data,index+5),'jpeg';break
                end
                index=index+size
            end
        end
    elseif data:sub(1,4)=='RIFF' and data:sub(9,12)=='WEBP' then
        local variant=data:sub(13,16)
        if variant=='VP8X' then
            local w,h=le24(data,25),le24(data,28)
            if w and h then width,height,kind=w+1,h+1,'webp' end
        elseif variant=='VP8L' and data:byte(21)==47 then
            local a,b,c,d=data:byte(22,25)
            if d then width,height,kind=1+a+(b%64)*256,1+math.floor(b/64)+c*4+(d%16)*1024,'webp' end
        elseif variant=='VP8 ' and data:sub(24,26)=='\157\1\42' then
            local w,h=le16(data,27),le16(data,29)
            if w and h then width,height,kind=w%16384,h%16384,'webp' end
        end
    end
    if not width or not height or width<1 or height<1 or width>M.MAX_SIDE or height>M.MAX_SIDE
        or width*height>M.MAX_PIXELS then return nil end
    return width,height,kind
end
return M
