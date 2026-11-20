-- An on-screen estimate only: neither a source coordinate nor cloud progress.
local M={}
local function finite(value)
    return type(value)=='number' and value==value and value~=math.huge and value~=-math.huge
end
local function id(value)
    if type(value)~='number' and type(value)~='string' then return nil end
    if type(value)=='number' and (not finite(value) or value%1~=0 or value<0 or value>9007199254740991) then return nil end
    local text=tostring(value)
    if text=='' or #text>256 or text:find('[%z%c]') then return nil end
    return text
end

function M.estimate(chapters,index,uid,percent)
    if type(chapters)~='table' or not finite(index) or index%1~=0 or index<1
        or not finite(percent) or percent<0 or percent>100 then return nil end
    local count=#chapters
    if count<1 or count>10000 or index>count or not id(uid) then return nil end
    local keys=0
    for key in pairs(chapters) do
        if type(key)~='number' or key%1~=0 or key<1 or key>count then return nil end
        keys=keys+1
    end
    if keys~=count then return nil end
    local seen,total,before,current={},0,0,nil
    for i=1,count do
        local chapter=chapters[i]
        if type(chapter)~='table' then return nil end
        local chapter_id=id(chapter.chapterUid or chapter.chapterId)
        if chapter.chapterUid~=nil and chapter.chapterId~=nil
            and id(chapter.chapterUid)~=id(chapter.chapterId) then return nil end
        local raw_weight=chapter.wordCount
        if type(raw_weight)~='string' and type(raw_weight)~='number' then return nil end
        local weight=tonumber(raw_weight)
        if not chapter_id or seen[chapter_id] or not finite(weight)
            or weight%1~=0 or weight<=0 or weight>1000000000 then return nil end
        seen[chapter_id]=true
        total=total+weight
        if i<index then before=before+weight end
        if i==index then
            if chapter_id~=id(uid) then return nil end
            current=weight
        end
    end
    return (before+current*percent/100)/total*100
end

function M.for_document(document,book,chapters,index,uid,percent)
    local book_id=type(book)=='table' and id(book.book_id or book.bookId)
    if not book_id or not id(uid) then return nil end
    local ok,source=pcall(require,'weread.lib.position_source')
    if not ok then return nil end
    local read_ok,metadata=pcall(source.document_metadata,document,book_id,uid)
    if not read_ok or type(metadata)~='table' or type(metadata.identity)~='table'
        or metadata.identity.chapter_count~=1 then return nil end
    local version=require('weread.lib.book_file_identity').version(book.bookVersion)
    local file_version=metadata.identity.book_version
    if not finite(file_version) or file_version<0 then return nil end
    if version>0 and file_version>0 and version~=file_version then return nil end
    return M.estimate(chapters,index,uid,percent)
end
return M
