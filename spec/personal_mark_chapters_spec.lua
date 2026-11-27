package.path='./?.lua;'..package.path
local Chapters=require('weread.lib.personal_mark_chapters')
local reads=0
local function row(chapter,id)
    return setmetatable({id=id},{__index=function(_,key)
        if key=='chapterUid' then reads=reads+1;return chapter end
    end})
end
local marks,thoughts={},{}
for i=1,5000 do
    marks[i]=row(i%100,i)
    thoughts[i]=row((i*7)%100,i)
end
local state={snapshot={updated=marks},thought_snapshot={reviews=thoughts}}
local function original(rows,uid)
    local found={}
    for _,item in ipairs(rows) do
        if tostring(item.chapterUid)==uid then found[#found+1]=item end
    end
    return found
end
local function equal(a,b)
    assert(#a==#b)
    for i,value in ipairs(a) do assert(value==b[i],'chapter order or identity changed') end
end
local expected={}
for i=0,99 do
    local uid=tostring(i)
    expected[i]={original(marks,uid),original(thoughts,uid)}
end
local baseline_reads=reads;reads=0
for i=0,99 do
    local uid=tostring(i)
    equal(Chapters.rows(state,'snapshot',uid),expected[i][1])
    equal(Chapters.rows(state,'thought_snapshot',uid),expected[i][2])
end
assert(baseline_reads==1000000 and reads==10000,'chapter lookup did not reuse both indexes')
equal(Chapters.rows(state,'snapshot','missing'),{})
equal(Chapters.rows(state,'snapshot',1),{}) -- Original comparison uses a string chapter ID.
local replacement=row(1,'replacement')
state.snapshot={updated={replacement}}
equal(Chapters.rows(state,'snapshot','1'),{replacement})
equal(Chapters.rows(state,'thought_snapshot','1'),expected[1][2])
local single_a,single_b=row(11,'a'),row(12,'b')
state.snapshot={updated={single_a,single_b}}
local a=Chapters.rows(state,'snapshot','11')
assert(a==Chapters.rows(state,'snapshot','11'),'repeated singleton lookup was not reused')
equal(Chapters.rows(state,'snapshot','12'),{single_b})
equal(a,{single_a})
equal(Chapters.rows(state,'snapshot','11'),{single_a})
state.thought_snapshot=nil
equal(Chapters.rows(state,'thought_snapshot','1'),{})
assert(not state._thought_chapters,'missing snapshot retained old records')
state.snapshot=nil
equal(Chapters.rows(state,'snapshot','1'),{})
assert(not state._mark_chapters,'missing snapshot retained old records')
print('personal_mark_chapters_spec: 100 chapters matched; chapter reads 1000000 -> 10000')
