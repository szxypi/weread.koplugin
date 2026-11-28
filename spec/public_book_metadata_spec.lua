package.path='./?.lua;./?/init.lua;'..package.path
local Metadata=require('weread.lib.book_metadata')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local calls=0
local data={data={{bookId='900001',title='Public',intro='Introduction',totalWords=12345,
    publisher='Publisher',version=77,progress=88,secret=1,token='private'}}}
local client={get_public_book_metadata=function(_self,id) calls=calls+1;expect(id=='900001','wrong identity sent');return data end}
local value=Metadata.fetch_public(client,'900001')
expect(value.source=='public' and value.metadata.title=='Public' and value.metadata.wordCount==12345
    and not value.metadata.version and not value.metadata.progress and not value.metadata.secret and not value.metadata.token,
    'public details escaped the display-only projection')
for _,invalid in ipairs({{}, {data={}}, {data={{bookId='900002',title='Wrong'}}},
    {data={{bookId='900001',title='One'},{bookId='900001',title='Two'}}},
    {errCode=401,data={{bookId='900001',title='Rejected'}}}, {data={bad=true}}}) do
    data=invalid;expect(not pcall(Metadata.fetch_public,client,'900001'),'malformed or wrong-book response accepted')
end
local before=calls
for _,id in ipairs({'0','CB_Synthetic','1?bad',false}) do
    expect(not pcall(Metadata.fetch_public,client,id),'invalid public metadata identity accepted')
end
expect(calls==before,'invalid identity triggered public metadata request')
print('public_book_metadata_spec: '..checks..' checks')
