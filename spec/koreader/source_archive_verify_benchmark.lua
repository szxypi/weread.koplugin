require('ffi').log=function() end
require('setupkoenv')
package.path=arg[1]..'/?.lua;'..package.path
local archive=arg[4]=='baseline' and assert(loadfile(arg[2]))() or require('weread.lib.source_archive')
local size=assert(tonumber(arg[5]))
local fixture=assert(io.open(arg[6],'rb'))
local bytes=fixture:read('*a');assert(fixture:close() and #bytes==size)
local start=os.clock()
local ok=archive.verify_members(arg[3],{['body.bin']={maximum=8*1024*1024,bytes=bytes}})
local elapsed=os.clock()-start
assert(ok,'synthetic archive verification failed')
local status=assert(io.open('/proc/self/status','r'))
local contents=status:read('*a');status:close()
local peak=assert(tonumber(contents:match('VmHWM:%s*(%d+)')))
io.write('\nWEREAD_VERIFY_BENCHMARK='..require('json').encode({cpu_seconds=elapsed,peak_rss_kib=peak})..'\n')
