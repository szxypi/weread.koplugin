-- Catalog and identity arrive over a private pipe. Only fixed booleans and
-- aggregate chapter counts may leave this process.
require('setupkoenv')
local json=require('json')
local raw=assert(io.stdin:read('*a'));assert(#raw<=8*1024*1024)
local input=json.decode(raw)
local Reader=require('weread.lib.readtime_source')
local Current=require('weread.lib.source_currentness')
local Content=require('weread.lib.content')
local C=require('weread.lib.readtime_transfer_contract')
assert(C.cb_id(input.book) and C.integer(input.version,1,2147483647))
assert(Reader.version(input.catalog,input.book)==input.version and not Reader.unversioned_cb(input.catalog,input.book))
local rows=Content.normalize_chapters(input.catalog,input.book)
local chapters=Content.readable_chapters(rows)
assert(#chapters>1 and #chapters==#rows)
for _i,chapter in ipairs(chapters) do
    local uid=tostring(chapter.chapterUid or chapter.chapterId or chapter.chapter_uid or '')
    local index=Current.catalog_cb(input.catalog,input.book,uid)
    assert(C.integer(chapter.chapterIdx,0,1000000) and index==chapter.chapterIdx)
end
io.stdout:write('\nWEREAD_CB_TXT_CATALOG_FIXTURE='..json.encode({chapters=#chapters,
    matching_version=true,chapter_indexes_valid=true,unversioned_rejected=true})..'\n')
