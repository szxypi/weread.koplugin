require('ffi').log=function() end
require('setupkoenv')
package.path=arg[1]..'/?.lua;'..package.path
local ffi=require('ffi')
local backend_calls=0
if arg[3]=='optimized' then
    local original=ffi.load
    ffi.load=function(name)
        local lib=original(name)
        return {crc32=function(...)
            backend_calls=backend_calls+1
            return lib.crc32(...)
        end}
    end
    require('weread.lib.native_crc32')
    ffi.load=original
end
local archive=require('weread.lib.native_chapter_archive')
local crypto=require('weread.lib.crypto')
local file=assert(io.open(arg[2],'rb'))
local data=file:read('*a');file:close()
local started=os.clock()
local value
for _=1,3 do value=archive.read(data,'vwSvXMONEDngLYTAXw3olg==','12345678',{chapter_uid='37'}) end
local elapsed=os.clock()-started
assert(#value.assets==1)
local json=require('json')
io.write('\nWEREAD_NATIVE_ARCHIVE_BENCHMARK='..json.encode({
    seconds=elapsed,body_sha256=crypto.sha256_hex(value.body),
    image_sha256=crypto.sha256_hex(value.assets[1].data),backend_calls=backend_calls,
})..'\n')
