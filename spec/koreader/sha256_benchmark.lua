-- Compare both plugin paths against deterministic binary inputs in KOReader.
require('ffi').log=function() end
require('setupkoenv')
local json=require('json');local report={result='UNVERIFIED'}
local ok,reason=pcall(function()
    local home=assert(os.getenv('KO_HOME'))
    package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
    local original=package.loaded['ffi/sha2'];local preload=package.preload['ffi/sha2']
    package.loaded['ffi/sha2']=nil;package.preload['ffi/sha2']=function() error('forced unavailable') end
    package.loaded['weread.lib.crypto']=nil;local fallback=require('weread.lib.crypto')
    assert(fallback.sha256_hex('')=='e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855')
    package.loaded['ffi/sha2']=original;package.preload['ffi/sha2']=preload
    package.loaded['weread.lib.crypto']=nil;local fast=require('weread.lib.crypto')
    local backend=assert(require('ffi/sha2'));local fn=backend.sha256;local calls=0
    backend.sha256=function(value) calls=calls+1;return fn(value) end
    local function bytes(n,seed)
        local pattern={};for i=0,255 do pattern[#pattern+1]=string.char((i*73+19+(seed or 0)*31)%256) end
        pattern=table.concat(pattern)
        return string.rep(pattern,math.ceil(n/#pattern)):sub(1,n)
    end
    local results={}
    local function verify(size,seed)
        local value=bytes(size,seed);local expected=fallback.sha256_hex(value);local actual=fast.sha256_hex(value)
        assert(expected==actual,'backend differs from fallback at size '..size)
        results[#results+1]={bytes=size,seed=seed,digest=actual}
    end
    for _,size in ipairs({0,1,55,56,63,64,65,255,256,1023,1024,65535,1048576,2097152,8388608}) do verify(size,0) end
    for seed=1,48 do verify((seed*7919)%8192,seed) end
    assert(calls==#results+3,('KOReader SHA-256 backend calls: %d expected: %d'):format(calls,#results+3))
    local socket=require('socket')
    local function benchmark(hash,value,n)
        local start=socket.gettime();local cpu=os.clock();local digest
        for _=1,n do digest=hash(value) end
        return {wall_ms=math.floor((socket.gettime()-start)*1000+.5),
            cpu_ms=math.floor((os.clock()-cpu)*1000+.5),digest=digest}
    end
    local sizes={{bytes=1024,iterations=1000},{bytes=1048576,iterations=8}}
    for _,item in ipairs(sizes) do
        local value=bytes(item.bytes)
        item.fallback=benchmark(fallback.sha256_hex,value,item.iterations)
        item.optimized=benchmark(fast.sha256_hex,value,item.iterations)
        assert(item.fallback.digest==item.optimized.digest)
    end
    backend.sha256=fn
    report={result='PASS',vectors=results,measurements=sizes,backend_selected=true}
end)
if not ok then report.reason=tostring(reason):gsub('[\r\n]',' '):sub(1,200) end
io.write('\nWEREAD_SHA256_BENCHMARK='..json.encode(report)..'\n');io.flush()
os.exit(ok and 0 or 1)
