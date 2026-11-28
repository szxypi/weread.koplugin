-- Packaged chapter decoder benchmark on synthetic data only.
require('ffi').log=function() end
require('setupkoenv')
local json=require('json');local result={result='UNVERIFIED'}
local ok,reason=pcall(function()
    local home=assert(os.getenv('KO_HOME'))
    package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
    local root=assert(os.getenv('WEREAD_DECODE_FIXTURE'))
    local function read(path)
        local f=assert(io.open(path,'rb'));local data=assert(f:read('*a'));assert(f:close());return data
    end
    local e0,e1,e3=read(root..'/e0'),read(root..'/e1'),read(root..'/e3')
    local content=require('weread.lib.content');local hash=require('ffi/sha2').sha256
    local socket=require('socket')
    local iterations=assert(tonumber(os.getenv('WEREAD_DECODE_ITERATIONS')))
    collectgarbage('collect')
    local cpu=os.clock();local start=socket.gettime();local output
    for _=1,iterations do output=content.decode_content_shards(e0,e1,e3) end
    local wall=math.floor((socket.gettime()-start)*1000+.5)
    local cpu_ms=math.floor((os.clock()-cpu)*1000+.5)
    local status=read('/proc/self/status')
    local peak=tonumber(status:match('\nVmHWM:%s+(%d+)%s+kB'))
    result={result='PASS',iterations=iterations,input_bytes=#e0+#e1+#e3,
        output_bytes=#output,digest=hash(output),cpu_ms=cpu_ms,wall_ms=wall,peak_rss_kib=peak}
end)
if not ok then result.reason=tostring(reason):gsub('[\r\n]',' '):sub(1,200) end
io.write('\nWEREAD_CHAPTER_DECODE_BENCHMARK='..json.encode(result)..'\n');io.flush()
os.exit(ok and 0 or 1)
