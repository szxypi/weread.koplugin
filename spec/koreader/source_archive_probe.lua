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
    passed=passed+1
end
assert(Archive.verify_members(request.warm.path,{['body.txt']={maximum=64,bytes='safe synthetic body'}}))
assert(not Archive.verify_members(request.warm.path,{['body.txt']={maximum=64,bytes='different'}}))
assert(not Archive.verify_members(request.warm.path,{['body.txt']={maximum=64,sha256=string.rep('0',64)}}))
assert(not Archive.verify_members(request.warm.path,{['body.txt']={maximum=64,bytes='safe synthetic body',size=1}}))
assert(not Archive.verify_members(request.warm.path,{['body.txt']={maximum=0,bytes=''}}))
assert(not Archive.verify_members(request.warm.path,{['body.txt']={maximum=64,sha256='not a hash'}}))
assert(not Archive.verify_members(request.warm.path,{['body.txt']={maximum=64,bytes='x',sha256=string.rep('0',64)}}))
local discovered=0
for _,case in ipairs(request.metadata_cases or {}) do
    local rows=Archive.position_metadata(case.path)
    if case.success then
        assert(type(rows)=='table' and #rows==case.count,'metadata discovery returned an invalid count')
        for _i,row in ipairs(rows) do
            assert(case.hashes[row.name]==Crypto.sha256_hex(row.metadata),'discovered metadata changed')
        end
    else assert(not rows,'invalid metadata archive accepted') end
    discovered=discovered+1
end
for _i=1,20 do
    assert(Archive.read(request.warm.path,request.warm.wanted))
    assert(Archive.verify_members(request.warm.path,{['body.txt']={maximum=64,bytes='safe synthetic body'}}))
end
collectgarbage('collect')
local after=descriptors()
assert(after==before,'archive descriptor leaked')
io.stdout:write(json.encode({cases=passed,passed=passed,repeated_reads=20,descriptors_before=before,descriptors_after=after,
    metadata_cases=discovered,bulk_cases=passed,public_network_used=false,files_extracted=0}))
