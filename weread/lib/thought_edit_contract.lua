-- One-operation user-text payloads, independently checked in Python against
-- real snapshots. Native endpoints verified by the private three-write trial.
-- No network, settings writes, credentials or random text in user thoughts.
local Thoughts=require('weread.lib.my_cloud_thoughts')
local Marks=require('weread.lib.my_cloud_marks')
local Crypto=require('weread.lib.crypto')
local Protocol=require('weread.lib.protocol')
local Dom=require('weread.lib.source_dom')
local M={MAX_CONTENT=131072}
local FIELDS={'reviewId','content','abstract','chapterName','range','chapterUid','chapterIdx','type','createTime','isPrivate','isFinish'}
local MATCH={'type','chapterUid','range','abstract','isPrivate'}
local META={'book_id','operation','target_id','before_hash','after_hash','reference_hash','content_hash','match_hash','match_index','request_hash'}
local function fail(reason) error('thought_edit/'..reason,0) end
local function integer(v,max) return type(v)=='number' and v>=0 and v%1==0 and v<=max end
function M.hash(v) return type(v)=='string' and #v==64 and v:match('^[a-f0-9]+$')~=nil end
function M.key(v) return type(v)=='string' and v~='' and #v<=256 and not v:find('[%z%c%s]') and Protocol.utf8_substr(v,#v)==v end
local function scalar(value)
    if value==nil then return 'n;' end
    if type(value)=='string' then return 's'..#value..':'..value end
    if integer(value,2^53-1) then return 'i'..string.format('%.0f',value)..';' end
    fail('scalar')
end
function M.digest(values)
    local parts={};for _i,v in ipairs(values) do parts[#parts+1]=scalar(v) end
    return Crypto.sha256_hex(table.concat(parts))
end
local function fields_hash(row,fields)
    local parts={};for _i,k in ipairs(fields) do parts[#parts+1]=scalar(row[k]) end
    return Crypto.sha256_hex(table.concat(parts))
end
function M.row_hash(row) return fields_hash(row,FIELDS) end
function M.snapshot_hash(snapshot)
    local rows,seen={},{}
    for _i,row in ipairs(snapshot.reviews) do
        if seen[row.reviewId] then fail('duplicate') end
        seen[row.reviewId]=true;rows[#rows+1]=row
    end
    table.sort(rows,function(a,b) return a.reviewId<b.reviewId end)
    local parts={'thoughts-v1',#rows};for _i,row in ipairs(rows) do parts[#parts+1]=M.row_hash(row) end
    return M.digest(parts)
end
function M.valid_content(value)
    if type(value)~='string' or #value==0 or #value>M.MAX_CONTENT or value:find('[%z\1-\8\11-\31\127]')
        or Protocol.utf8_substr(value,#value)~=value then return false end
    local clean=Dom.normalize(value);return clean~=nil and clean~=''
end
function M.reference_hash(operation,row)
    return operation=='create' and fields_hash(row,{'bookmarkId','type','chapterUid','range','markText'}) or M.row_hash(row)
end
local function match_hash(row,indexed)
    local parts={}
    for _i,key in ipairs(MATCH) do
        local value=row[key]
        if key=='chapterUid' and type(value)=='string' and value:match('^%d+$') then value=tonumber(value) end
        parts[#parts+1]=scalar(value)
    end
    if indexed then parts[#parts+1]=scalar(row.chapterIdx) end
    return Crypto.sha256_hex(table.concat(parts))
end
function M.context(client,marks,metadata,book,owner,reference)
    local row
    if reference.selection then
        if not require('weread.lib.selection_reference').valid(reference,book) then fail('selection') end
        row=reference
    else
        marks=Marks.project(client,marks,book,owner,1)
        for _i,v in ipairs(marks.updated) do if v.bookmarkId==reference.bookmarkId then row=v end end
    end
    if not row or row.type~=1 or not integer(row.chapterUid,2147483647) or row.chapterUid==0
        or type(row.markText)~='string' or #row.markText==0 or #row.markText>4096
        or M.reference_hash('create',row)~=M.reference_hash('create',reference) then fail('changed') end
    local first,last
    if type(row.range)=='string' then first,last=row.range:match('^(%d+)%-(%d+)$') end
    if not first or #first>10 or #last>10 or tonumber(first)>=tonumber(last) or tonumber(last)>2147483647 then fail('range') end
    if type(metadata)~='table' or tostring(metadata.bookId)~=book then fail('metadata') end
    local version=metadata.bookVersion or metadata.version
    if not integer(version,2147483647) or version==0 then fail('version') end
    local ctx={bookId=book,chapterUid=tostring(row.chapterUid),bookVersion=version,type=1,range=row.range,abstract=row.markText,isPrivate=1}
    -- Selection catalog indices belong to Web source verification. The real
    -- native creation fixture omitted chapterIdx; do not invent a conversion.
    if row.chapterIdx~=nil and not reference.selection then ctx.chapterIdx=row.chapterIdx end
    return ctx
end
function M.body_hash(body)
    local keys={};for key in pairs(body) do keys[#keys+1]=key end;table.sort(keys)
    local parts={'body-v1'};for _i,key in ipairs(keys) do parts[#parts+1]=key;parts[#parts+1]=body[key] end
    return M.digest(parts)
end
function M.validate_body(operation,body)
    if type(body)~='table' then return false end
    local allowed
    if operation=='create' then
        allowed={bookId=true,chapterUid=true,bookVersion=true,type=true,range=true,abstract=true,isPrivate=true,content=true,chapterIdx=true}
        if not Marks.id(body.bookId) or not Marks.id(body.chapterUid) or tonumber(body.chapterUid)>2147483647
            or not integer(body.bookVersion,2147483647) or body.bookVersion==0 or body.type~=1 or body.isPrivate~=1
            or not M.valid_content(body.content) or not M.valid_content(body.abstract) or #body.abstract>4096
            or body.chapterIdx~=nil and not integer(body.chapterIdx,2147483647) then return false end
        local first,last
        if type(body.range)=='string' then first,last=body.range:match('^(%d+)%-(%d+)$') end
        if not first or #first>10 or #last>10 or tonumber(first)>=tonumber(last) or tonumber(last)>2147483647 then return false end
    elseif operation=='edit' then allowed={reviewId=true,content=true};if not M.key(body.reviewId) or not M.valid_content(body.content) then return false end
    elseif operation=='delete' then allowed={reviewId=true};if not M.key(body.reviewId) then return false end
    else return false end
    for key in pairs(body) do if not allowed[key] then return false end end
    return true
end
function M.make(client,snapshot,operation,reference,content,marks,metadata,owner)
    local book=type(snapshot)=='table' and snapshot.book_id
    if not Marks.id(book) or operation~='create' and operation~='edit' and operation~='delete' then fail('operation') end
    snapshot=Thoughts.validate(client,snapshot,book)
    if operation~='delete' and not M.valid_content(content) then fail('content') end
    local before=M.snapshot_hash(snapshot)
    local body,target,after,reference_hash,matching,indexed
    if operation=='create' then
        body=M.context(client,marks,metadata,book,owner,reference);body.content=content
        target,after,reference_hash=reference.bookmarkId,'',M.reference_hash(operation,reference)
        indexed=body.chapterIdx~=nil;matching=match_hash(body,indexed)
    else
        target=reference.reviewId;local original
        for _i,row in ipairs(snapshot.reviews) do if row.reviewId==target then original=row end end
        if not original or M.row_hash(original)~=M.row_hash(reference) then fail('changed') end
        if original.isPrivate~=0 and original.isPrivate~=1 then fail('privacy') end
        body={reviewId=target};local rows=client:json_decode('[]')
        for _i,row in ipairs(snapshot.reviews) do
            if row.reviewId~=target then rows[#rows+1]=row
            elseif operation=='edit' then
                local copy={};for k,v in pairs(row) do copy[k]=v end;copy.content=content;rows[#rows+1]=copy
            end
        end
        if operation=='edit' then body.content=content end
        after=M.snapshot_hash({reviews=rows});reference_hash=M.row_hash(original);matching,indexed='',false
    end
    return {metadata={book_id=book,operation=operation,target_id=target,before_hash=before,after_hash=after,
        reference_hash=reference_hash,content_hash=operation~='delete' and M.digest({content}) or '',
        match_hash=matching,match_index=indexed and 1 or 0,request_hash=M.body_hash(body)},body=body,snapshot=snapshot}
end
function M.validate_metadata(value)
    if type(value)~='table' or not Marks.id(value.book_id) or not M.key(value.target_id)
        or value.operation~='create' and value.operation~='edit' and value.operation~='delete' then return false end
    local allowed={};for _i,k in ipairs(META) do allowed[k]=true;if value[k]==nil then return false end end
    for key in pairs(value) do if not allowed[key] then return false end end
    for _i,k in ipairs({'before_hash','reference_hash','request_hash'}) do if not M.hash(value[k]) then return false end end
    if not integer(value.match_index,1) then return false end
    if value.operation=='create' then
        return value.after_hash=='' and M.hash(value.content_hash) and M.hash(value.match_hash)
    end
    return M.hash(value.after_hash) and value.match_hash=='' and value.match_index==0
        and (value.operation=='edit' and M.hash(value.content_hash) or value.operation=='delete' and value.content_hash=='')
end
function M.check(snapshot,metadata)
    if not M.validate_metadata(metadata) or snapshot.book_id~=metadata.book_id then fail('book') end
    if metadata.operation~='create' then return M.snapshot_hash(snapshot)==metadata.after_hash end
    local chosen,count=nil,0
    for _i,row in ipairs(snapshot.reviews) do
        if M.digest({row.content})==metadata.content_hash and match_hash(row,metadata.match_index==1)==metadata.match_hash then
            local others={};for _j,v in ipairs(snapshot.reviews) do if v.reviewId~=row.reviewId then others[#others+1]=v end end
            if M.snapshot_hash({reviews=others})==metadata.before_hash then chosen,count=row.reviewId,count+1 end
        end
    end
    return count==1,count==1 and chosen or nil
end
return M
