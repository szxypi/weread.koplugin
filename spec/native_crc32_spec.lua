package.path='./?.lua;'..package.path
local bit=require('bit')
local ffi=require('ffi')
local original_load=ffi.load
local original_module=package.loaded['weread.lib.native_crc32']
local function load(loader)
    ffi.load=loader
    package.loaded['weread.lib.native_crc32']=nil
    local result=require('weread.lib.native_crc32')
    ffi.load=original_load
    return result
end
local vectors={{'',0},{'123456789',0xcbf43926},{'abc',0x352441c2},
    {'\0\255\128lua',0xbfcf3e2d}}
local fallback=load(function() error('unavailable') end)
for _,v in ipairs(vectors) do
    assert(fallback(v[1])==bit.tobit(v[2]),'fallback CRC mismatch')
end
local accelerated=load(original_load)
for _,v in ipairs(vectors) do
    assert(accelerated(v[1])==bit.tobit(v[2]),'native CRC mismatch')
end
for n=0,4097 do
    local bytes={}
    for i=1,n do bytes[i]=string.char((i*73+n*31)%256) end
    local data=table.concat(bytes)
    assert(accelerated(data)==fallback(data),'native and fallback differ')
end
local calls_native=0
local simulated=load(function() return {crc32=function(_,data,size)
    calls_native=calls_native+1
    return bit.band(fallback(ffi.string(data,size)),0xffffffff)
end} end)
assert(simulated('abc')==bit.tobit(0x352441c2) and calls_native==4,'compatible library not used')
local unstable_calls=0
local unstable=load(function() return {crc32=function(_,data,size)
    unstable_calls=unstable_calls+1
    if unstable_calls>3 then error('backend stopped working') end
    return bit.band(fallback(ffi.string(data,size)),0xffffffff)
end} end)
assert(unstable('abc')==bit.tobit(0x352441c2) and unstable('abc')==bit.tobit(0x352441c2)
    and unstable_calls==4,'failed library was retried or fallback changed')
local calls=0
local broken=load(function() return {crc32=function() calls=calls+1;return 0 end} end)
assert(broken('123456789')==bit.tobit(0xcbf43926) and calls==2,'invalid library not rejected')
package.loaded['weread.lib.native_crc32']=original_module
print('native_crc32_spec: binary vectors, native selection, fallback and invalid library passed')
