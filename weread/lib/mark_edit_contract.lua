-- Source-bound highlights, verified by the two-write Python real-account
-- prototype. No guessed native chapter index; linked thoughts block deletion.
local Base=require('weread.lib.thought_edit_contract')
local Marks=require('weread.lib.my_cloud_marks')
local Data=require('weread.lib.mark_edit_data')
local Reference=require('weread.lib.selection_reference')
local M={}
local ROW={'bookmarkId','markText','abstract','range','chapterUid','chapterIdx','type','style','colorStyle','createTime'}
local MATCH={'markText','range','chapterUid','type','style','colorStyle'}
local META={'book_id','operation','target_id','before_hash','after_hash','reference_hash','match_hash','request_hash',
    'thoughts_hash','chapters_hash','chapter_without_hash','chapter_uid','chapter_present'}
local function fail(reason) error('mark_edit/'..reason,0) end
local function integer(v,max) return type(v)=='number' and v>=0 and v%1==0 and v<=max end
local function hash_fields(row,fields)
    local values={};for _i,k in ipairs(fields) do values[#values+1]=Base.digest({row[k]}) end
    return Base.digest(values)
end
function M.row_hash(row) return hash_fields(row,ROW) end
local function rows_hash(rows,omit)
    local copy={};for _i,row in ipairs(rows) do if row.bookmarkId~=omit then copy[#copy+1]=row end end
    table.sort(copy,function(a,b) return a.bookmarkId<b.bookmarkId end)
    local values={'marks-v1',#copy};for _i,row in ipairs(copy) do values[#values+1]=M.row_hash(row) end
    return Base.digest(values)
end
local function chapters_hash(rows,omit)
    local copy={};for _i,row in ipairs(rows) do if tostring(row.chapterUid)~=omit then copy[#copy+1]=row end end
    table.sort(copy,function(a,b) return a.chapterUid<b.chapterUid end)
    local values={'mark-chapters-v1',#copy}
    for _i,row in ipairs(copy) do values[#values+1]=hash_fields(row,{'chapterUid','title'}) end
    return Base.digest(values)
end
local function range(row)
    local a,b
    if type(row.range)=='string' then a,b=row.range:match('^(%d+)%-(%d+)$') end
    if not a or #a>10 or #b>10 or tonumber(a)>=tonumber(b) or tonumber(b)>2147483647 then return nil end
    return tonumber(a),tonumber(b)
end
local function disjoint(rows,reference)
    local a,b=range(reference);if not a then return false end
    for _i,row in ipairs(rows) do
        if row.chapterUid==reference.chapterUid then
            local first,last=range(row)
            if not first or first<b and last>a then return false end
        end
    end
    return true
end
function M.validate_body(operation,body)
    if type(body)~='table' then return false end
    local allowed
    if operation=='create' then
        allowed={bookId=true,chapterUid=true,bookVersion=true,type=true,style=true,colorStyle=true,range=true,markText=true}
        if not Marks.id(body.bookId) or not integer(body.chapterUid,2147483647) or body.chapterUid==0
            or not integer(body.bookVersion,2147483647) or body.bookVersion==0 or body.type~=1 or body.style~=1 or body.colorStyle~=0
            or not Base.valid_content(body.markText) or #body.markText>4096 or not range(body) then return false end
    elseif operation=='delete' then
        allowed={bookmarkIds=true}
        if type(body.bookmarkIds)~='table' or #body.bookmarkIds~=1 or not Base.key(body.bookmarkIds[1]) then return false end
        for k in pairs(body.bookmarkIds) do if k~=1 then return false end end
    else return false end
    for k in pairs(body) do if not allowed[k] then return false end end
    return true
end
function M.body_hash(body)
    if body.bookmarkIds then return Base.digest({'remove-mark-v1',body.bookmarkIds[1]}) end
    return Base.body_hash(body)
end
function M.make(client,snapshot,operation,reference,metadata)
    local book=type(snapshot)=='table' and snapshot.book_id
    snapshot=Data.validate(client,snapshot,book)
    if not Marks.id(book) or operation~='create' and operation~='delete' or type(reference)~='table' then fail('operation') end
    local row,body
    if operation=='create' then
        if not Reference.valid(reference,book) or not disjoint(snapshot.marks.updated,reference) then fail('selection') end
        row=reference
        if type(metadata)~='table' or tostring(metadata.bookId)~=book then fail('metadata') end
        body={bookId=book,chapterUid=row.chapterUid,bookVersion=metadata.bookVersion or metadata.version,
            type=1,style=1,colorStyle=0,range=row.range,markText=row.markText}
    else
        for _i,v in ipairs(snapshot.marks.updated) do if v.bookmarkId==reference.bookmarkId then row=v end end
        if not row or row.type~=1 or not range(row) or M.row_hash(row)~=M.row_hash(reference) then fail('changed') end
        body={bookmarkIds=client:json_decode('[]')};body.bookmarkIds[1]=row.bookmarkId
    end
    if not disjoint(snapshot.thoughts.reviews,row) then fail('linked_thought') end
    if not M.validate_body(operation,body) then fail('body') end
    local uid=tostring(row.chapterUid);local present=0
    for _i,v in ipairs(snapshot.marks.chapters) do if tostring(v.chapterUid)==uid then present=1 end end
    return {snapshot=snapshot,body=body,metadata={book_id=book,operation=operation,target_id=row.bookmarkId,
        before_hash=rows_hash(snapshot.marks.updated),after_hash=operation=='delete' and rows_hash(snapshot.marks.updated,row.bookmarkId) or '',
        reference_hash=M.row_hash(row),match_hash=operation=='create' and hash_fields(body,MATCH) or '',request_hash=M.body_hash(body),
        thoughts_hash=Base.snapshot_hash(snapshot.thoughts),chapters_hash=chapters_hash(snapshot.marks.chapters),
        chapter_without_hash=chapters_hash(snapshot.marks.chapters,uid),chapter_uid=uid,chapter_present=present}}
end
function M.validate_metadata(value)
    if type(value)~='table' or not Marks.id(value.book_id) or not Marks.id(value.chapter_uid) or not Base.key(value.target_id)
        or value.operation~='create' and value.operation~='delete' or not integer(value.chapter_present,1) then return false end
    local allowed={};for _i,k in ipairs(META) do allowed[k]=true;if value[k]==nil then return false end end
    for k in pairs(value) do if not allowed[k] then return false end end
    for _i,k in ipairs({'before_hash','reference_hash','request_hash','thoughts_hash','chapters_hash','chapter_without_hash'}) do
        if not Base.hash(value[k]) then return false end
    end
    return value.operation=='create' and value.after_hash=='' and Base.hash(value.match_hash)
        or value.operation=='delete' and Base.hash(value.after_hash) and value.match_hash==''
end
function M.check(snapshot,metadata)
    if not M.validate_metadata(metadata) or snapshot.book_id~=metadata.book_id then fail('metadata') end
    if Base.snapshot_hash(snapshot.thoughts)~=metadata.thoughts_hash then return false end
    local chapters=chapters_hash(snapshot.marks.chapters)
    if metadata.operation=='delete' or metadata.chapter_present==1 then
        if chapters~=metadata.chapters_hash then return false end
    elseif chapters_hash(snapshot.marks.chapters,metadata.chapter_uid)~=metadata.chapter_without_hash then return false end
    if metadata.operation=='delete' then return rows_hash(snapshot.marks.updated)==metadata.after_hash end
    local chosen,count=nil,0
    for _i,row in ipairs(snapshot.marks.updated) do
        if hash_fields(row,MATCH)==metadata.match_hash and rows_hash(snapshot.marks.updated,row.bookmarkId)==metadata.before_hash then
            chosen,count=row.bookmarkId,count+1
        end
    end
    return count==1,count==1 and chosen or nil
end
return M
