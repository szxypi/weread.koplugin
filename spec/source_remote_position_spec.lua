package.path='./?.lua;'..package.path
local Resolve=require('weread.lib.source_remote_position').resolve
local n=0
local function eq(a,b) n=n+1;assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local catalog={{chapterUid=22,chapterIdx=7},{chapterUid=33,chapterIdx=10}}
local function raw(index) return {book={bookId='book',progress=25.4,chapterUid=22,chapterOffset=0,chapterIdx=index,summary='Synthetic'}} end
local function reject(value,chapters,reason)
    local p,why=Resolve(value,'book',chapters or catalog,'web');eq(p,nil);eq(why,reason or 'progress_source_incomplete')
end
local p=assert(Resolve(raw(7),'book',catalog,'web'))
eq(p.percent,25.4);eq(p.chapter_idx,7);eq(p.chapter_index_source,'response');eq(p.has_chapter_index,true)
for _i,rows in ipairs({catalog,{catalog[2],catalog[1]}}) do
    p=assert(Resolve(raw(),'book',rows,'web'));eq(p.chapter_idx,7);eq(p.chapter_index_source,'catalog')
end
for _i,fields in ipairs({{},{chapterIdx=0},{summary=''},{chapterIdx='0',summary=''}}) do
    local v={progress=0,chapterUid=0,chapterOffset=0};for k,x in pairs(fields) do v[k]=x end
    reject(v,nil,'progress_no_chapter')
end
for _i,fields in ipairs({{progress=1},{chapterOffset=1},{chapterIdx=7},{summary='nonempty'}}) do
    local v={progress=0,chapterUid=0,chapterOffset=0};for k,x in pairs(fields) do v[k]=x end;reject(v)
end
reject({progress=0,chapterUid=0});reject(raw(0))
local value=raw();value.book.chapterOffset=nil;reject(value)
for _i,rows in ipairs({{}, {catalog[1],catalog[1]}, {catalog[1],{chapterUid=33,chapterIdx=7}},
    {{chapterUid=22},catalog[2]},{{chapterUid=44,chapterIdx=7}}}) do reject(raw(),rows) end
for _i,fields in ipairs({{chapterIdx=true},{chapterIdx=-1},{chapterIdx=1.5},{chapterIdx='7'},
    {chapterIdx=0/0},{chapterIdx=math.huge},{chapterIdx=1000001},{chapterIndex=8},{chapterUid=0},{chapterUid=true},{chapterId=33}}) do
    local row={chapterUid=22,chapterIdx=7};for k,x in pairs(fields) do row[k]=x end;reject(raw(),{row,catalog[2]})
end
p=assert(Resolve(raw(),'book',{catalog[1],{chapterUid=33}},'web'));eq(p.chapter_idx,7)
p=assert(Resolve(raw(),'book',{{chapterUid='22',chapterId=22,chapterIdx=0,chapterIndex=0}},'web'));eq(p.chapter_idx,0)
reject({bookId='other',data=raw()},nil,'progress_book_mismatch')
reject({data={raw(),raw()}},nil,'progress_ambiguous')
eq(raw().book.chapterIdx,nil);eq(catalog[1].chapterIdx,7)
print('source_remote_position_spec: '..n..' checks')
