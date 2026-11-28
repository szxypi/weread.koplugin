package.path='./?.lua;'..package.path

local ffi=require('ffi')
local original_loadlib=ffi.loadlib
local original_preload=package.preload['ffi/sha2']
local original_sha=package.loaded['ffi/sha2']
local original_crypto=package.loaded['weread.lib.crypto']
local function load(loader,loadlib)
    ffi.loadlib=loadlib
    package.loaded['ffi/sha2']=nil
    package.preload['ffi/sha2']=loader
    package.loaded['weread.lib.crypto']=nil
    return require('weread.lib.crypto')
end
local vectors={
    {'','e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'},
    {'abc','ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'},
    {'\0\255\128lua','7813f4b3246ec2c76bb2a1752cb5dab7d39e77cf48b7b88a551674b6eb43844e'},
    {string.rep('a',55),'9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318'},
    {string.rep('a',56),'b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a'},
    {string.rep('a',63),'7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34'},
    {string.rep('a',64),'ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb'},
    {string.rep('a',65),'635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0'},
    {string.rep('a',1000),'41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3'},
}
local attempts=0
local fallback=load(function() attempts=attempts+1;error('not available') end)
for _,vector in ipairs(vectors) do assert(fallback.sha256_hex(vector[1])==vector[2],'fallback digest changed') end
assert(attempts==1,'unavailable backend was repeatedly loaded')
assert(fallback.sha256_hex(nil)==vectors[1][2] and fallback.sha256_hex(false)==vectors[1][2])
assert(fallback.sha256_hex(123)==fallback.sha256_hex('123'),'input conversion changed')

local calls=0
local accelerated=load(function() return {sha256=function(value) calls=calls+1;return fallback.sha256_hex(value) end} end)
for _,vector in ipairs(vectors) do assert(accelerated.sha256_hex(vector[1])==vector[2],'optimized digest changed') end
assert(calls==#vectors+3,'compatible backend was not used for every digest')

local bad_calls=0
local rejected=load(function() return {sha256=function() bad_calls=bad_calls+1;return string.rep('0',64) end} end)
assert(rejected.sha256_hex('abc')==vectors[2][2] and rejected.sha256_hex('abc')==vectors[2][2])
assert(bad_calls==1,'incompatible backend was reused')

for _,bad in ipairs({'invalid',string.rep('A',64),'error'}) do
    local count=0
    local unstable=load(function() return {sha256=function(value)
        count=count+1
        if value=='after self-test' then if bad=='error' then error('failed') else return bad end end
        return fallback.sha256_hex(value)
    end} end)
    assert(unstable.sha256_hex('after self-test')==fallback.sha256_hex('after self-test'))
    assert(unstable.sha256_hex('abc')==vectors[2][2] and count==4,'failed backend was retried')
end

local function native_library(calculate)
    return function(name,version)
        assert(name=='crypto' and version=='57','did not use the bundled library loader')
        return {SHA256=function(value,length,output)
            assert(#value==length,'native input length was changed')
            local digest=calculate(value)
            if not digest then return nil end
            local bytes=digest:gsub('%x%x',function(pair) return string.char(tonumber(pair,16)) end)
            ffi.copy(output,bytes,#bytes)
            return output
        end}
    end
end
local native_calls,bundled_calls=0,0
local function bundled()
    bundled_calls=bundled_calls+1;return {sha256=fallback.sha256_hex}
end
local native=load(bundled,native_library(function(value)
    native_calls=native_calls+1;return fallback.sha256_hex(value)
end))
for _,vector in ipairs(vectors) do assert(native.sha256_hex(vector[1])==vector[2],'native digest changed') end
assert(native_calls==#vectors+3 and bundled_calls==0,'native backend was not preferred')

native_calls=0
local native_retry=load(bundled,native_library(function(value)
    native_calls=native_calls+1
    if value~='after self-test' then return fallback.sha256_hex(value) end
end))
assert(native_retry.sha256_hex('after self-test')==fallback.sha256_hex('after self-test'))
assert(native_retry.sha256_hex('abc')==vectors[2][2] and native_calls==4 and bundled_calls==1,
    'failed native digest did not switch to the bundled implementation once')

local bad_libraries={
    function() error('unavailable') end,
    function() return {} end,
    native_library(function() return string.rep('0',64) end),
}
for _,loadlib in ipairs(bad_libraries) do
    local rejected_native=load(bundled,loadlib)
    assert(rejected_native.sha256_hex('abc')==vectors[2][2], 'incompatible native backend changed the digest')
end
assert(bundled_calls==4,'native failures did not use the bundled fallback')
local unavailable_calls=0
local pure_fallback=load(function() error('bundled backend unavailable') end,function()
    unavailable_calls=unavailable_calls+1;error('native backend unavailable')
end)
assert(pure_fallback.sha256_hex('abc')==vectors[2][2] and pure_fallback.sha256_hex('')==vectors[1][2]
    and unavailable_calls==1,'both unavailable backends must fall back without reloading')
ffi.loadlib=original_loadlib
package.preload['ffi/sha2']=original_preload
package.loaded['ffi/sha2']=original_sha
package.loaded['weread.lib.crypto']=original_crypto
print('crypto_sha256_spec: vectors, backend selection, input compatibility and fallback passed')
