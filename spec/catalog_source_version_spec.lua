package.path='./?.lua;'..package.path
local V=require('weread.lib.catalog_source_version')
local n=0;local function eq(actual,expected) n=n+1;assert(actual==expected,tostring(actual)..' ~= '..expected) end
for _i,raw in ipairs({{data={{bookId='42',bookVersion=7}}},{books={{bookId=42,version=7}}},
    {bookId='42',book={bookId='42',version=7}},{data={bookId='42',bookVersion=7,book={bookId=42,bookVersion=7,version=7}}}}) do eq(V.read(raw,'42'),7) end
for _i,raw in ipairs({{}, {data={}}, {data={{bookId='43',version=7}}}, {data={{bookId='42'}}},
    {data={{bookId='42',bookVersion=7,version=8}}}, {data={{bookId='42',bookVersion=7,book={bookId='43',version=7}}}},
    {data={{bookId='42',version=7},{bookId='42',version=7}}}, {data={{bookId='42',version=7},false}},
    {bookId='42',bookVersion=7,book={version=8}}}) do eq(V.read(raw,'42'),0) end
for _i,version in ipairs({0,-1,true,'7',1.5,0/0,math.huge,2147483648}) do eq(V.read({bookId='42',version=version},'42'),0) end
eq(V.read({bookId='CB_Synthetic',book={bookVersion=7}},'CB_Synthetic'),7)
eq(V.read({bookId='42',version=7},42),0);eq(V.read(false,'42'),0)
print('catalog_source_version_spec: '..n..' checks')
