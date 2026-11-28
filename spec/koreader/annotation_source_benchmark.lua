require('ffi').log=function() end
require('setupkoenv')
package.path=arg[1]..'/?.lua;'..package.path
local old=assert(loadfile(arg[2]))()
local new=require('weread.lib.annotation_source')
local function equal(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~='table' then return a==b end
    for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
local tokens={'甲','😀','a',' ','\n','<p>','</p>','<body>','</body>','<script>',
    '</script>','<style>','</style>','<b x="a > b">','<b x=\'a > b\'>','<!-- hidden -->',
    '<!-- unfinished','<3','&amp;','&unknown;','&bad','>','"',"'",'\239\187\191','\240\159'}
math.randomseed(452391)
local count=0
for _=1,5000 do
    local pieces={}
    for _=1,math.random(1,45) do pieces[#pieces+1]=tokens[math.random(#tokens)] end
    local raw=table.concat(pieces)
    for _,body_only in ipairs({false,true}) do
        local before=old.index(raw,{body_only=body_only})
        local after=new.index(raw,{body_only=body_only})
        assert(equal(before,after),'source spans changed')
        for _=1,4 do
            local from=math.random(0,#raw)
            local to=math.random(from,#raw+1)
            local range=from..'-'..to
            assert(old.quote(before,range)==new.quote(after,range),'source quote changed')
        end
        count=count+1
    end
end
local line='微信阅读原文测试内容，abcdefgh 123 &amp; 更多文字'
local fixtures={
    long='<body><p>'..line:rep(15000)..'</p></body>',
    paragraphs='<body>'..('<p>'..line..'</p>'):rep(10000)..'</body>',
}
local result={comparisons=count,runs=3,cases={}}
for name,raw in pairs(fixtures) do
    local measurements={bytes=#raw}
    do
        local reference=old.index(raw,{body_only=true})
        assert(equal(reference,new.index(raw,{body_only=true})),'large fixture mismatch')
        measurements.spans=#reference
    end
    for _,mode in ipairs({{'baseline',old},{'optimized',new}}) do
        local rows={}
        for _=1,3 do
            collectgarbage('collect');collectgarbage('stop')
            local memory=collectgarbage('count');local started=os.clock()
            local index=mode[2].index(raw,{body_only=true})
            local elapsed=os.clock()-started;local used=collectgarbage('count')-memory
            assert(#index==measurements.spans,'unexpected span count')
            rows[#rows+1]={seconds=elapsed,lua_allocated_kib=used}
            collectgarbage('restart')
        end
        measurements[mode[1]]=rows
    end
    result.cases[name]=measurements
end
io.write('\nWEREAD_ANNOTATION_SOURCE_BENCHMARK='..require('json').encode(result)..'\n')
