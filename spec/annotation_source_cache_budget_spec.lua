package.path = './?.lua;' .. package.path
package.preload.util = function() return {htmlEntitiesToUtf8=function(value) return value end} end
local Source=require('weread.lib.annotation_source')
local weak=setmetatable({}, {__mode='v'})
do
    local spans={}
    for i=1,96 do
        spans[i]=Source.index(('&;'):rep(4000)..i)
    end
    collectgarbage('collect');collectgarbage('collect')
    local before=collectgarbage('count')
    for i=1,#spans do
        assert(Source.quote(spans[i],'7990-7992')=='&;', 'initial quote changed')
        assert(Source.quote(spans[i],'7990-7992')=='&;', 'cached quote changed')
    end
    collectgarbage('collect');collectgarbage('collect')
    assert(collectgarbage('count')-before < 4096, 'live quote caches exceeded the memory budget')
    for i=1,#spans do
        assert(Source.quote(spans[i],'7990-7992')=='&;', 'evicted or cached quote changed')
        assert(Source.quote(spans[i],'7990-7992')=='&;', 'recreated quote changed')
    end
    for i=1,#spans do weak[i]=spans[i][1] end
end
collectgarbage('collect');collectgarbage('collect')
for i=1,96 do assert(weak[i]==nil, 'cache retained an unused source span') end
print('annotation_source_cache_budget_spec: evictions, rebuilds and collection passed')
