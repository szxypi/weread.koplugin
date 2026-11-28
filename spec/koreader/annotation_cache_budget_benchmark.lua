require('ffi').log=function() end
require('setupkoenv')
package.path=arg[1]..'/?.lua;'..package.path
local old=assert(loadfile(arg[2]))()
local new=require('weread.lib.annotation_source')
local function measure(module)
    local group={}
    for i=1,96 do group[i]=module.index(('&;'):rep(4000)..i) end
    collectgarbage('collect');collectgarbage('collect')
    local before=collectgarbage('count')
    local started=os.clock()
    for i=1,#group do
        assert(module.quote(group[i],'7990-7992')=='&;')
        assert(module.quote(group[i],'7990-7992')=='&;')
    end
    local elapsed=os.clock()-started
    collectgarbage('collect');collectgarbage('collect')
    local after=collectgarbage('count')
    assert(#group==96 and group[96][1][3]:sub(7991,7992)=='&;')
    return {retained_lua_kib=after-before,seconds=elapsed}
end
local result={spans=96,entity_intervals_per_span=4000,runs=3,cases={}}
for _,case in ipairs({{'baseline',old},{'optimized',new}}) do
    local rows={}
    for _=1,3 do rows[#rows+1]=measure(case[2]) end
    result.cases[case[1]]=rows
end
io.write('\nWEREAD_ANNOTATION_CACHE_BENCHMARK='..require('json').encode(result)..'\n')
