-- Encode into memory and exclusively create the destination. Never overwrite
-- an existing user file or rely on writePNG's unchecked return value.
local ffi=require('ffi')
require('ffi/lodepng_h')
ffi.cdef[[unsigned lodepng_encode_memory(unsigned char **out, size_t *outsize,
    const unsigned char *image, unsigned w, unsigned h, LodePNGColorType colortype, unsigned bitdepth);]]
local png=ffi.loadlib('lodepng')
local BB=require('ffi/blitbuffer')
local Output=require('weread.lib.notes_export_file')
local M={}

function M.encode(image)
    if not image or image:getType()~=BB.TYPE_BBRGB32 then return nil,'invalid_image' end
    local w,h=image:getWidth(),image:getHeight()
    if w<1 or h<1 or w>4096 or h>12000 then return nil,'invalid_size' end
    local buffer=BB.new(w,h,BB.TYPE_BBRGB32,nil,w*4,w)
    local ptr=ffi.new('unsigned char *[1]')
    local size=ffi.new('size_t[1]')
    local ok,value=pcall(function()
        buffer:blitFrom(image)
        local code=png.lodepng_encode_memory(ptr,size,ffi.cast('const unsigned char *',buffer.data),w,h,png.LCT_RGBA,8)
        if code~=0 or ptr[0]==nil or tonumber(size[0])>32*1024*1024 then return nil end
        return ffi.string(ptr[0],size[0])
    end)
    if ptr[0]~=nil then ffi.C.free(ptr[0]) end
    buffer:free()
    if not ok or not value then return nil,'encode_failed' end
    return value
end

function M.write(image,directory,title)
    local value,reason=M.encode(image)
    if not value then return nil,reason end
    local output=Output.create(directory,title,'png')
    if not output then return nil,'create_failed' end
    if not output:write(value) or not output:sync() or not output:accept(#value) then
        output:abort();return nil,'save_failed'
    end
    return output.path
end
return M
