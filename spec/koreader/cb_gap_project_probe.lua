-- Only bounded booleans leave this read-only in-memory projection check.
require('setupkoenv')
package.path=assert(arg[1])..'/?.lua;'..package.path
local json=require('json')
local ok,result=pcall(function()
    local raw=io.stdin:read(8*1024*1024+1);assert(#raw<=8*1024*1024)
    local input=json.decode(raw)
    assert(type(input)=='table' and type(input.source)=='string' and type(input.book)=='string'
        and type(input.chapter)=='string' and type(input.offset)=='number' and type(input.target_offset)=='number')
    local point={bookId=input.book,chapterUid=input.chapter,chapterOffset=input.offset,progress=input.percent}
    local before={book=point};local reader={bookInfo={bookId=input.book},currentChapter={chapterUid=input.chapter},progress=before}
    local target=require('weread.lib.source_cloud').project(input.book,before,reader,input.source,before)
    return {projected=true,original=target.chapter_offset==input.offset,following=target.chapter_offset==input.target_offset,
        upload_disabled=target.upload_verified==false}
end)
print('\nWEREAD_CB_GAP_PROJECT='..json.encode(ok and result or {projected=false}))
os.exit(ok and 0 or 1)
