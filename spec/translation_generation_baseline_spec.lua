package.path='./?.lua;'..package.path
local null=function() end
local array_mt={}
local codec={json_decode=function(_self,value)
    if value=='null' then return null elseif value=='[]' then return setmetatable({},array_mt) end
end}
local Baseline=require('weread.lib.translation_generation_baseline')
local function invalid(value,id,kind)
    return not pcall(Baseline.observe,codec,value,id or '456',kind or 'native')
end
local function unrecorded()
    return {bookId='456',book={bookId='456',title='Synthetic',details={readingTime=0}},canFreeRead=1,timestamp=100}
end
local a=unrecorded();local b=unrecorded();b.timestamp=101
local first=Baseline.observe(codec,a,'456','native')
assert(not first.present and #first.digest==64 and Baseline.observe(codec,b,'456','native').digest==first.digest,
    'unrecorded timestamp was confused with a position change')
b.book.details.readingTime=1
assert(Baseline.observe(codec,b,'456','native').digest~=first.digest,'nested time counter change ignored')
b=unrecorded();b.book.details.readingTime='0';assert(invalid(b),'invalid nested time accepted')
b=unrecorded();b.book.bookId='999';assert(invalid(b),'wrong book accepted')
b=unrecorded();b.book=setmetatable({1},array_mt);assert(invalid(b),'array accepted as book object')
b=unrecorded();b.extra=0;assert(invalid(b),'unknown absence envelope accepted')
b=unrecorded();b.book.extra=null;local with_null=Baseline.observe(codec,b,'456','native')
b.book.extra={};assert(Baseline.observe(codec,b,'456','native').digest~=with_null.digest,'JSON null confused with empty object')
b=unrecorded();b.book.extra=setmetatable({},array_mt);local with_array=Baseline.observe(codec,b,'456','native')
b.book.extra={};assert(Baseline.observe(codec,b,'456','native').digest~=with_array.digest,'empty array confused with object')
local function recorded()
    return {bookId='456',progress=20,chapterUid=7,chapterIdx=3,chapterOffset=12,summary='Synthetic',
        readingTime=11,recordReadingTime=10,ttsTime=0}
end
local p=recorded();local observation=Baseline.observe(codec,p,'456','native')
assert(observation.present and #observation.digest==64)
for _,field in ipairs({'chapterUid','chapterOffset','progress','summary','readingTime','recordReadingTime','ttsTime'}) do
    local changed=recorded();changed[field]=field=='summary' and 'Other' or changed[field]+1
    assert(Baseline.observe(codec,changed,'456','native').digest~=observation.digest,'changed '..field..' was ignored')
end
p=recorded();p.readingTime=nil;assert(invalid(p),'native recorded state without complete counters accepted')
p=recorded();p.readingTime=nil;assert(Baseline.observe(codec,p,'456','web').present,'web optional counter was invented')
p=recorded();p.chapterOffset=nil;assert(invalid(p),'incomplete position accepted')
p=recorded();p.errcode=1;assert(invalid(p),'error response accepted')
print('PASS: translation baseline presence, counters, identity, and stable observations')
