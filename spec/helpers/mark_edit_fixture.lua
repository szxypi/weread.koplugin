local F=require('spec.helpers.thought_edit_fixture')
local M={clone=F.clone,codec=F.codec,access=F.access}
function M.reference()
    local hash=string.rep('a',64)
    return {selection=true,type=1,bookmarkId='selection:2:200-240:'..hash,range='200-240',chapterUid=2,chapterIdx=3,
        markText='合成新划线 😀',source={book_id='900001',chapter_uid='2',chapter_idx=3,raw_sha256=hash,raw_bytes=1000}}
end
function M.snapshot(codec)
    local marks=require('weread.lib.my_cloud_marks').project(codec,F.marks(codec),'900001','900000',1000)
    return {book_id='900001',marks=marks,thoughts=F.snapshot(codec)}
end
function M.created(codec,snapshot)
    local value=F.clone(snapshot);local row=M.reference()
    value.marks.updated[#value.marks.updated+1]={bookmarkId='synthetic-new-highlight',chapterUid=2,type=1,style=1,colorStyle=0,
        range=row.range,markText=row.markText,createTime=1001}
    return value
end
return M
