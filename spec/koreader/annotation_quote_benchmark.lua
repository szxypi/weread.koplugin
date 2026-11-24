require('ffi').log=function() end
require('setupkoenv')
package.path=arg[1]..'/?.lua;'..package.path
local old=assert(loadfile(arg[2]))()
local new=require('weread.lib.annotation_source')
local samples={
    ('甲😀ab '):rep(1100),
    ('甲&amp;乙&#x41;丙'):rep(700),
    ('开头😀'):rep(800)..'&unfinished'..('汉字'):rep(1000),
    ('甲\240\159'):rep(1500),
}
math.randomseed(641523)
local comparisons=0
for _,raw in ipairs(samples) do
    for _,plain in ipairs({false,true}) do
        local before=plain and old.plain(raw) or old.index('<body>'..raw..'</body>',{body_only=true})
        local after=plain and new.plain(raw) or new.index('<body>'..raw..'</body>',{body_only=true})
        for _=1,3000 do
            local first=math.random(0,#raw+500)
            local last=first+math.random(0,200)
            local range=first..'-'..last
            assert(old.quote(before,range)==new.quote(after,range),'quote changed')
            comparisons=comparisons+1
        end
    end
end
local line='中文阅读内容甲乙丙丁'
local fixtures={plain='<p>'..line:rep(20000)..'</p>',
    entities='<p>'..(line:rep(1000)..'&amp;'):rep(20)..'</p>'}
local result={comparisons=comparisons,ranges=200,runs=3,fixtures={}}
for kind,raw in pairs(fixtures) do
    local reference=old.index(raw);local expected,accepted={},0
    for i=1,200 do
        local first=3+(i*997)%199950
        expected[i]=old.quote(reference,first..'-'..(first+10))
        if expected[i]~='' then accepted=accepted+1 end
    end
    assert(accepted>150,'benchmark targets did not select enough text')
    local measurements={bytes=#raw}
    for _,case in ipairs({{'baseline',old},{'optimized',new}}) do
        local rows={}
        for _=1,3 do
            local spans=case[2].index(raw)
            collectgarbage('collect')
            local started=os.clock()
            for i=1,200 do
                local first=3+(i*997)%199950
                assert(case[2].quote(spans,first..'-'..(first+10))==expected[i])
            end
            local elapsed=os.clock()-started
            rows[#rows+1]={seconds=elapsed}
        end
        measurements[case[1]]=rows
    end
    result.fixtures[kind]=measurements
end
io.write('\nWEREAD_ANNOTATION_QUOTE_BENCHMARK='..require('json').encode(result)..'\n')
