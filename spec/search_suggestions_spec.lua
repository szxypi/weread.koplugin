package.path='./?.lua;./?/init.lua;'..package.path
local Model=require('weread.lib.search_suggestions')
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
expect(Model.keyword('  科学  ')=='科学' and not Model.keyword(' \t '),'keyword trimming')
for _,bad in ipairs({'bad\ntext',string.char(255),string.rep('x',513)}) do
    expect(not Model.keyword(bad),'invalid query accepted')
end
local response={keyword='科学',records={{word='科学家'},{word='科学史'},{word='科学家'}},
    list={{word='科学书'},{bookId='synthetic'}},parts={'科学'}}
local words=Model.project(response,'科学')
expect(#words==3 and words[1]=='科学家' and words[2]=='科学史' and words[3]=='科学书','ordered unique projection')
for _,bad in ipairs({{}, {keyword='other',records={},list={},parts={}}, {records={[2]={word='x'}},list={},parts={}},
    {records={{word='x\ny'}},list={},parts={}}, {records={{word=string.char(255)}},list={},parts={}},
    {records={},list={},parts={},errcode=-1}}) do
    expect(not pcall(Model.project,bad,'科学'),'invalid response accepted')
end
local rows={};for i=1,15 do rows[i]={word='word'..i} end
expect(#Model.project({records=rows,list={},parts={}},'q')==10,'suggestion limit')
print('search_suggestions_spec: '..checks..' checks')
