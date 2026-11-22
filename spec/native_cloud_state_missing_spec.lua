package.path='./?.lua;'..package.path
local S=require('weread.lib.native_cloud_state')
local C=require('weread.lib.native_position_contract')
local function raw()
    return {bookId='41',chapterUid=2,chapterIdx=3,chapterOffset=12,progress=17,
        readingTime=10,recordReadingTime=20,ttsTime=0}
end
local original=raw();local missing=assert(S.from_missing_summary(original,'41'))
assert(S.valid(missing) and S.missing_summary(missing) and missing.summary==nil)
assert(not pcall(S.snapshot,original,'41'))
assert(S.equal(S.snapshot(original,'41',{allow_missing_summary=true}).position,missing))
for _,field in ipairs({'chapterUid','chapterIdx','chapterOffset','progress'}) do
    local value=raw();value[field]=nil;assert(not S.from_missing_summary(value,'41'),field)
end
for _,value in ipairs({'',false,'present'}) do
    local node=raw();node.summary=value;assert(not S.from_missing_summary(node,'41'))
    node=raw();node.chapterTitle=value;assert(not S.from_missing_summary(node,'41'))
end
local changed=raw();changed.chapterOffset=13;assert(not S.equal(missing,assert(S.from_missing_summary(changed,'41'))))
local extra={};for key,value in pairs(missing) do extra[key]=value end;extra.summary='';assert(not S.valid(extra))
local desired={book_id='41',chapter_uid='2',chapter_idx=3,chapter_offset=13,raw_percent=17,summary='new excerpt'}
local meta={book_id='41',before=missing,desired=desired,counts={readingTime=10,recordReadingTime=20,ttsTime=0},
    version=0,shelf_sha256=string.rep('a',64),source_sha256=string.rep('b',64),file_id='synthetic',basis='filtered_xhtml_utf16'}
assert(C.valid(meta));meta.basis='raw_txt_utf16';assert(not C.valid(meta))
print('PASS: native XHTML missing-summary state remains explicit and source-scoped')
