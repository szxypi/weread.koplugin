package.path='./?.lua;'..package.path
local Data=require('weread.lib.thought_image_data')
local function be32(n) return string.char(math.floor(n/16777216)%256,math.floor(n/65536)%256,math.floor(n/256)%256,n%256) end
local function be16(n) return string.char(math.floor(n/256)%256,n%256) end
local png='\137PNG\r\n\26\n'..be32(13)..'IHDR'..be32(1400)..be32(1440)..string.rep('\0',10)
local w,h,kind=Data.dimensions(png);assert(w==1400 and h==1440 and kind=='png')
local jpeg='\255\216\255\224'..be16(4)..'xx'..'\255\192'..be16(8)..'\8'..be16(1440)..be16(1400)..'\1'
w,h,kind=Data.dimensions(jpeg);assert(w==1400 and h==1440 and kind=='jpeg')
local gif='GIF89a'..string.char(120,0,160,0)..string.rep('\0',12)
w,h,kind=Data.dimensions(gif);assert(w==120 and h==160 and kind=='gif')
local webp='RIFF'..string.rep('\0',4)..'WEBPVP8X'..string.rep('\0',8)..string.char(99,0,0,199,0,0)
w,h,kind=Data.dimensions(webp);assert(w==100 and h==200 and kind=='webp')
assert(not Data.dimensions(png:sub(1,19)) and not Data.dimensions('not an image'))
assert(not Data.dimensions('\137PNG\r\n\26\n'..be32(13)..'IHDR'..be32(5001)..be32(1)..string.rep('\0',10)))
assert(not Data.dimensions('\137PNG\r\n\26\n'..be32(13)..'IHDR'..be32(5000)..be32(5000)..string.rep('\0',10)))
assert(not Data.dimensions(jpeg:sub(1,12)) and not Data.dimensions(string.rep('x',Data.MAX_BYTES+1)))
print('PASS: thought images reject oversized and malformed dimensions')
