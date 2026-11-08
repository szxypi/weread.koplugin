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
    passed=passed+1
end
for _i=1,20 do assert(Archive.read(request.warm.path,request.warm.wanted)) end
collectgarbage('collect')
local after=descriptors()
assert(after==before,'archive descriptor leaked')
io.stdout:write(json.encode({cases=passed,passed=passed,repeated_reads=20,descriptors_before=before,descriptors_after=after,
    public_network_used=false,files_extracted=0}))
