package.path='./?.lua;'..package.path

local original_preload=package.preload['ffi/sha2']
local original_sha=package.loaded['ffi/sha2']
local original_crypto=package.loaded['weread.lib.crypto']
local function load(loader)
    package.loaded['ffi/sha2']=nil
    package.preload['ffi/sha2']=loader
    package.loaded['weread.lib.crypto']=nil
    return require('weread.lib.crypto')
end
local vectors={
    {'','d41d8cd98f00b204e9800998ecf8427e'},
    {'abc','900150983cd24fb0d6963f7d28e17f72'},
    {'\0\255\128lua','e882b923c7fc317d9da8a73d05ef2ab7'},
    {string.rep('a',55),'ef1772b6dff9a122358552954ad0df65'},
    {string.rep('a',56),'3b0c8ac703f828b04c6c197006d17218'},
    {string.rep('a',63),'b06521f39153d618550606be297466d5'},
    {string.rep('a',64),'014842d480b571495a4a0363793f7367'},
    {string.rep('a',65),'c743a45e0d2e6a95cb859adae0248435'},
    {string.rep('a',1000),'cabe45dcc9ae5b66ba86600cca6b8ba8'},
}
local attempts=0
local fallback=load(function() attempts=attempts+1;error('not available') end)
for _,vector in ipairs(vectors) do assert(fallback.md5_hex(vector[1])==vector[2],'fallback digest changed') end
assert(attempts==1,'unavailable backend was repeatedly loaded')
assert(fallback.md5_hex(nil)==vectors[1][2] and fallback.md5_hex(false)==vectors[1][2])
assert(fallback.md5_hex(123)==fallback.md5_hex('123'),'input conversion changed')

local calls=0
local accelerated=load(function() return {md5=function(value) calls=calls+1;return fallback.md5_hex(value) end} end)
for _,vector in ipairs(vectors) do assert(accelerated.md5_hex(vector[1])==vector[2],'optimized digest changed') end
assert(calls==#vectors+3,'compatible backend was not used for every digest')

local bad_calls=0
local rejected=load(function() return {md5=function() bad_calls=bad_calls+1;return string.rep('0',32) end} end)
assert(rejected.md5_hex('abc')==vectors[2][2] and rejected.md5_hex('abc')==vectors[2][2])
assert(bad_calls==1,'incompatible backend was reused')

for _,bad in ipairs({'invalid',string.rep('A',32),'error'}) do
    local count=0
    local unstable=load(function() return {md5=function(value)
        count=count+1
        if value=='after self-test' then if bad=='error' then error('failed') else return bad end end
        return fallback.md5_hex(value)
    end} end)
    assert(unstable.md5_hex('after self-test')==fallback.md5_hex('after self-test'))
    assert(unstable.md5_hex('abc')==vectors[2][2] and count==4,'failed backend was retried')
end
package.preload['ffi/sha2']=original_preload
package.loaded['ffi/sha2']=original_sha
package.loaded['weread.lib.crypto']=original_crypto
print('crypto_md5_spec: vectors, backend selection, input compatibility and fallback passed')
