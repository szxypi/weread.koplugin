package.path='./?.lua;'..package.path
local Guard=require('weread.lib.cb_sync_guard')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message or ('check '..checks)) end
local function copy(value) if type(value)~='table' then return value end;local out={};for k,v in pairs(value) do out[k]=copy(v) end;return out end
local book='CB_Synthetic'
local expected={book_id=book,source='web',chapter_uid='11',chapter_idx=0,chapter_offset=25,raw_percent=37,
    updated_at=123,has_chapter_index=true,has_chapter_offset=true}
local value={book={bookId=book,chapterUid=11,chapterIdx=0,chapterOffset=25,progress=37,updateTime=123}}
local checked=Guard.expected(expected,book)
expect(checked and Guard.matches(value,checked),'valid cloud state rejected')
local changes={{chapterUid=12},{chapterIdx=1},{chapterOffset=26},{progress=38},{updateTime=124},{bookId='CB_Other'}}
for _i,change in ipairs(changes) do
    local changed=copy(value);for key,item in pairs(change) do changed.book[key]=item end
    expect(not Guard.matches(changed,checked),'changed cloud state accepted')
end
local noindex=copy(value);noindex.book.chapterIdx=nil
expect(Guard.matches(noindex,checked),'catalog-resolved explicit index rejected')
for _i,change in ipairs({{source='gateway'},{has_chapter_index=false},{has_chapter_offset=false},
    {book_id='CB_Other'},{chapter_uid='CB_x'},{chapter_idx=0.5},{chapter_offset=-1},{raw_percent=0/0},{updated_at=-1}}) do
    local changed=copy(expected);for k,v in pairs(change) do changed[k]=v end
    expect(not Guard.expected(changed,book),'invalid expected cloud state accepted')
end
expect(not Guard.expected(expected,nil) and not Guard.expected(expected,'123'),'invalid book accepted')
expect(not Guard.matches({},checked) and not Guard.matches(value,nil),'invalid observation accepted')
print('cb_sync_guard_spec: '..checks..' checks')
