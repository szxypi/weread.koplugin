-- Independent native libarchive boundary checks; input/output metadata only.
require('ffi').log=function() end
require('setupkoenv')
package.path=assert(arg[1])..'/?.lua;'..package.path
local Archive=require('weread.lib.source_archive')
local Crypto=require('weread.lib.crypto')
local json=require('rapidjson')
local lfs=require('libs/libkoreader-lfs')
local request=json.decode(assert(io.stdin:read(1024*1024)))
local function descriptors()
    local count=0
    for name in lfs.dir('/proc/self/fd') do if name~='.' and name~='..' then count=count+1 end end
    return count
end
local warm=assert(Archive.read(request.warm.path,request.warm.wanted))
assert(warm['body.txt']=='safe synthetic body')
local batch=assert(Archive.read_batch(request.warm.path,{['body.txt']=64,['absent']=64}))
assert(batch['body.txt']==warm['body.txt'] and not batch.absent)
for _,case in ipairs(request.cases) do
    if case.path:match('/duplicate%.zip$') then
        assert(not Archive.read_batch(case.path,{['body.txt']=64}),'batch accepted duplicate source bytes')
    end
end
collectgarbage('collect')
local before=descriptors()
local passed=0
for _,case in ipairs(request.cases) do
    local result,err=Archive.read(case.path,case.wanted)
    if case.success then
        assert(result,'valid bounded archive failed')
        for name,sha in pairs(case.hashes) do assert(Crypto.sha256_hex(result[name])==sha,'archive member changed') end
    else
        assert(not result and type(err)=='string' and err:match('^source_archive/'),'invalid archive accepted')
    end
    local wanted={}
    for name,maximum in pairs(case.wanted) do
        wanted[name]={maximum=maximum,sha256=case.hashes[name] or string.rep('0',64)}
    end
    assert(Archive.verify_members(case.path,wanted)==case.success,'bulk member verification differed')
    if wanted['meta.txt'] then
        local meta=wanted['meta.txt']
        wanted['meta.txt']={maximum=meta.maximum,validate=function(raw) return Crypto.sha256_hex(raw)==meta.sha256 end}
        assert(Archive.verify_members(case.path,wanted)==case.success,'mixed metadata verification differed')
    end
    passed=passed+1
end
assert(Archive.verify_members(request.warm.path,{['body.txt']={maximum=64,bytes='safe synthetic body'}}))
assert(not Archive.verify_members(request.warm.path,{['body.txt']={maximum=64,bytes='different'}}))
assert(not Archive.verify_members(request.warm.path,{['body.txt']={maximum=64,sha256=string.rep('0',64)}}))
assert(not Archive.verify_members(request.warm.path,{['body.txt']={maximum=64,bytes='safe synthetic body',size=1}}))
assert(not Archive.verify_members(request.warm.path,{['body.txt']={maximum=0,bytes=''}}))
assert(not Archive.verify_members(request.warm.path,{['body.txt']={maximum=64,sha256='not a hash'}}))
assert(not Archive.verify_members(request.warm.path,{['body.txt']={maximum=64,bytes='x',sha256=string.rep('0',64)}}))
assert(not Archive.verify_members(request.warm.path,{['meta.txt']={maximum=64,validate=function() return false end}}))
assert(not Archive.verify_members(request.warm.path,{['meta.txt']={maximum=64,validate=function() error('synthetic validator failure') end}}))
assert(not Archive.verify_members(request.warm.path,{['meta.txt']={maximum=64,validate=true}}))
assert(not Archive.verify_members(request.warm.path,{['meta.txt']={maximum=64,validate=function() return true end,bytes='safe metadata'}}))
local pattern={}
for i=0,255 do pattern[#pattern+1]=string.char((i*73+19)%256) end
pattern=table.concat(pattern)
for _,case in ipairs(request.byte_cases or {}) do
    local value=pattern:rep(math.ceil(case.size/256)):sub(1,case.size)
    if case.mismatch>0 then
        local at=case.mismatch
        value=value:sub(1,at-1)..string.char((value:byte(at)+1)%256)..value:sub(at+1)
    end
    assert(Archive.verify_members(case.path,{['body.bin']={maximum=8*1024*1024,bytes=value}})==case.success,
        'streaming byte verification changed')
    if case.success then
        assert(Archive.verify_members(case.path,{['body.bin']={maximum=8*1024*1024,sha256=case.valid_hash}}),
            'digest verification changed')
    end
    if case.size==65537 then
        assert(Archive.verify_members(case.path,{['body.bin']={maximum=65537,validate=function(raw) return raw==value end}})==case.success,
            'bounded validator accepted duplicate, corrupt or mismatched content')
    end
end
-- A runtime without the C byte comparator must retain the bounded Lua
-- comparison and the same duplicate and CRC rejection behavior.
local ffi=require('ffi')
local attempts=0
package.loaded.ffi=setmetatable({cdef=function() attempts=attempts+1;error('simulated unavailable comparator') end},
    {__index=ffi})
local fallback=assert(loadfile(arg[1]..'/weread/lib/source_archive.lua'))()
local exercised=0
for _,case in ipairs(request.byte_cases or {}) do
    if case.size==65537 then
        local value=pattern:rep(math.ceil(case.size/256)):sub(1,case.size)
        if case.mismatch>0 then
            local at=case.mismatch
            value=value:sub(1,at-1)..string.char((value:byte(at)+1)%256)..value:sub(at+1)
        end
        assert(fallback.verify_members(case.path,{['body.bin']={maximum=8*1024*1024,bytes=value}})==case.success)
        exercised=exercised+1
    end
end
package.loaded.ffi=ffi
assert(exercised==4 and attempts==1,'comparator fallback was not exercised')
local native_calls=0
local libc=setmetatable({memcmp=function(...)
    native_calls=native_calls+1
    return ffi.C.memcmp(...)
end},{__index=function(_,key) return ffi.C[key] end})
package.loaded.ffi=setmetatable({C=libc},{__index=ffi})
local accelerated=assert(loadfile(arg[1]..'/weread/lib/source_archive.lua'))()
local valid
for _,case in ipairs(request.byte_cases or {}) do if case.size==65537 and case.success then valid=case;break end end
assert(valid)
assert(accelerated.verify_members(valid.path,{['body.bin']={maximum=8*1024*1024,
    bytes=pattern:rep(math.ceil(valid.size/256)):sub(1,valid.size)}}))
package.loaded.ffi=ffi
assert(native_calls>2,'native comparator was not selected')
local discovered=0
for _,case in ipairs(request.metadata_cases or {}) do
    local count=0
    local found=Archive.position_metadata(case.path,function(name,metadata)
        count=count+1
        if case.success then
            local expected=case.uniform_hash~='' and case.uniform_hash or case.hashes[name]
            assert(expected==Crypto.sha256_hex(metadata),'discovered metadata changed')
        end
    end)
    if case.success then
        assert(found==true and count==case.count,'metadata discovery returned an invalid count')
    else assert(not found,'invalid metadata archive accepted') end
    discovered=discovered+1
end
for _i=1,20 do
    assert(Archive.read(request.warm.path,request.warm.wanted))
    assert(Archive.verify_members(request.warm.path,{['body.txt']={maximum=64,bytes='safe synthetic body'}}))
end
local package_data=assert(Archive.read(request.package.path,{['OEBPS/content.opf']=32*1024*1024}))
assert(Crypto.sha256_hex(package_data['OEBPS/content.opf'])==request.package.hash)
assert(not Archive.read(request.package.path,{['OEBPS/text/other.xhtml']=32*1024*1024}),
    'the larger package allowance was applied to a different member')
collectgarbage('collect')
local after=descriptors()
assert(after==before,'archive descriptor leaked')
io.stdout:write(json.encode({cases=passed,passed=passed,repeated_reads=20,descriptors_before=before,descriptors_after=after,
    metadata_cases=discovered,bulk_cases=passed,byte_cases=#(request.byte_cases or {}),public_network_used=false,files_extracted=0}))
