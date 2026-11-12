package.path='./?.lua;'..package.path
package.preload.util=function() return {htmlEntitiesToUtf8=function(value) return (value:gsub('&amp;','&')) end} end
local Target=require('weread.lib.my_thought_target')
local Mark=require('weread.lib.my_mark_target')
local checks=0;local function expect(v,label) checks=checks+1;assert(v,label) end
local function copy(value) local out={};for k,v in pairs(value) do out[k]=v end;return out end
local raw='<html><body><p>Prefix. Unique quoted &amp; <b>selected text</b> end.</p></body></html>'
local first=assert(raw:find('Unique',1,true))-1;local last=assert(raw:find('</b>',1,true))+3
local row={reviewId='synthetic-review',type=1,chapterUid=2,range=first..'-'..last,abstract='Unique quoted & selected text',content='My separate thought',isPrivate=1}
local expected=assert(Mark.project(raw,'41','2',{type=1,chapterUid=2,range=row.range,markText=row.abstract}))
local value=assert(Target.project(raw,'41','2',row));expect(Target.can_locate(row) and value.chapter_offset==expected.chapter_offset and value.upload_verified==false,'quote adapter changed source units')
for _i,bad in ipairs({{bookId='42'},{chapterUid=3},{chapterUid='2'},{chapterUid=true},{type=0},{type=true},{reviewId=''},{reviewId='bad id'},{reviewId='bad　id'},
    {abstract=''},{abstract='different'},{abstract='bad\255'},{range='1-2'},{range='1:2'},{range='2-1'},{range='0-99999999999'}}) do
    local changed=copy(row);for k,v in pairs(bad) do changed[k]=v end
    expect(not Target.project(raw,'41','2',changed),'invalid quote received a target')
end
local changed=copy(row);changed.abstract=nil;changed.content=row.abstract;changed.markText=row.abstract
expect(not Target.can_locate(changed) and not Target.project(raw,'41','2',changed),'thought prose substituted for quote')
for _i,privacy in ipairs({0,1,false}) do
    changed=copy(row);changed.isPrivate=privacy;changed.content=''
    expect(Target.project(raw,'41','2',changed).chapter_offset==value.chapter_offset,'read-only quote required write privacy')
end
local old=Mark.bind_file;Mark.bind_file=function(file,book,mark,request_id)
    expect(file=='/synthetic.epub' and book=='41' and request_id==7 and mark.markText==row.abstract and not mark.content and not mark.reviewId,'write text or identity leaked into source binding')
    return {position=expected}
end
expect(Target.bind_file('/synthetic.epub','41',row,7).position==expected,'archive binding bypassed shared validation');Mark.bind_file=old
local resolved=Mark.resolve;Mark.resolve=function(book,file,mark,request_id)
    expect(book.book_id=='41' and file=='/synthetic.epub' and mark.markText==row.abstract and request_id==8,'cached target lost reference');return {position=expected}
end
expect(Target.resolve({book_id='41'},'/synthetic.epub',row,8).position==expected,'cached resolution bypassed shared validation');Mark.resolve=resolved
changed=copy(row);changed.bookId='41'
expect(not Target.bind_file('/synthetic.epub','42',changed,9).position,'foreign book accepted')
print('PASS: own thought quotation, strict range and shared archive binding ('..checks..' checks)')
