-- Own highlight range -> verified local source target. Python first verified
-- all 52 real ranges across five chapters; raw runes and progress units differ.
-- No networking, persistence, reader movement or permission for cloud writes.
local Coordinates=require('weread.lib.source_coordinates')
local Raw=require('weread.lib.annotation_source')
local Dom=require('weread.lib.source_dom')
local Data=require('weread.lib.my_cloud_marks')
local Crypto=require('weread.lib.crypto')
local Protocol=require('weread.lib.protocol')
local M={}
local function fail(reason) error('my_mark_target/'..reason,0) end
local function integer(value,max) return type(value)=='number' and value>=0 and value%1==0 and value<=max end
local function chars(value) return value:gmatch('()([%z\1-\127\194-\244][\128-\191]*)') end
local function trim(value)
    local first,last
    for at,char in chars(value) do
        if Dom.normalize(char)~='' then first=first or at;last=at+#char-1 end
    end
    return first and value:sub(first,last) or ''
end
local function count(value)
    local n=0;for _at,_char in chars(value) do n=n+1 end;return n
end
-- Cheap menu eligibility only. Parsing, quotation verification and source
-- conversion remain in the independent worker, including for very long text.
function M.can_locate(row)
    if type(row)~='table' or row.type~=1 or not integer(row.chapterUid,2147483647) or row.chapterUid==0
        or type(row.markText)~='string' or row.markText=='' or #row.markText>131072 or type(row.range)~='string' then return false end
    local first,last=row.range:match('^(%d+)%-(%d+)$')
    return first~=nil and #first<=10 and #last<=10 and tonumber(first)<tonumber(last) and tonumber(last)<=2147483647
end
function M.project(raw,book,chapter,row)
    local ok,value=pcall(function()
        if not Data.id(book) or not Data.id(chapter) or type(row)~='table' or row.type~=1
            or not integer(row.chapterUid,2147483647) or tostring(row.chapterUid)~=chapter
            or row.bookId~=nil and tostring(row.bookId)~=book then fail('scope') end
        local quote=row.markText
        if type(quote)~='string' or #quote>131072 or quote:find('[%z\1-\8\11-\31\127]') then fail('quote') end
        local needle=Dom.normalize(quote)
        if not needle or needle=='' then fail('quote') end
        local first,last
        if type(row.range)=='string' then first,last=row.range:match('^(%d+)%-(%d+)$') end
        if not first or #first>10 or #last>10 then fail('range') end
        first,last=tonumber(first),tonumber(last)
        if not first or not last or first>=last or last>2147483647 then fail('range') end
        local map=Coordinates.build(raw,{allow_multiple_bodies=true})
        if not map then fail('source_unsupported') end
        local source=raw:gsub('^\239\187\191','');local length=count(source)
        if last>length then fail('quote_changed') end
        local spans=Raw.index(raw,{body_only=true})
        if trim(Raw.quote(spans,row.range))~=trim(quote) then fail('quote_changed') end
        local selected=Protocol.utf8_substr(needle,1024)
        local long=count(needle)>1024
        local points={}
        local function attempt(before,after)
            local prefix=assert(Dom.normalize(before));local suffix=assert(Dom.normalize(after))
            local candidate=prefix..selected..suffix
            local found=map:locate(candidate)
            if not found then return end
            local start=found.first+#prefix
            if map.flat:sub(start,start+#needle-1)~=needle then return end
            local point=map:locate_point(candidate,count(prefix))
            if point then points[point.co]=true end
        end
        attempt('','')
        for _i,width in ipairs({24,48,96,192}) do
            local before=first>0 and Raw.quote(spans,tostring(math.max(0,first-width))..'-'..tostring(first)) or ''
            local after=last<length and not long and Raw.quote(spans,tostring(last)..'-'..tostring(math.min(length,last+width))) or ''
            attempt(before,after);attempt('',after);attempt(before,'')
        end
        local offset,n=nil,0
        for candidate in pairs(points) do offset=candidate;n=n+1 end
        if n~=1 then fail(n==0 and 'unmatched' or 'ambiguous') end
        -- Refuse overlapping source coordinates or entity interiors before
        -- the later archive and native DOM binding can receive a target.
        local anchor=map:anchor(offset,{segment_only=true}) or map:anchor(offset)
        if not anchor then fail('boundary') end
        return {book_id=book,chapter_uid=chapter,chapter_offset=offset,raw_sha256=Crypto.sha256_hex(raw),
            raw_bytes=#raw,basis='filtered_xhtml_utf16',upload_verified=false}
    end)
    if ok then return value end
    return nil,type(value)=='string' and value:match('^my_mark_target/[a-z_]+$') and value or 'my_mark_target/unavailable'
end
-- Independent worker-only archive reads. No raw text or path from the mark
-- becomes a filename; candidates come from the reader and this book's cache.
function M.bind_file(file,book,row,request_id,read_archive)
    local ok,value=pcall(function()
        if type(file)~='string' or file=='' or #file>4096 or file:find('[%z%c]')
            or not Data.id(book) or type(row)~='table' or not integer(row.chapterUid,2147483647) then fail('scope') end
        local uid=tostring(row.chapterUid)
        local Source=require('weread.lib.position_source')
        local Identity=require('weread.lib.book_file_identity')
        local read=read_archive or require('weread.lib.source_archive').read
        local path=Source.meta_path(uid)
        local members=read(file,{[Identity.PATH]=Identity.MAX_BYTES,[path]=Source.MAX_META_BYTES})
        local identity=members and Identity.decode(members[Identity.PATH])
        local metadata=members and members[path]
        local record=Source.decode_metadata(metadata)
        if not identity or identity.book_id~=book or not record or record.book_id~=book
            or record.chapter_uid~=uid or record.file_id~=identity.file_id or record.format~='web_xhtml' then fail('source_changed') end
        local raw_path=Source.raw_path(record.raw_sha256)
        local data=read(file,{[raw_path]=Source.MAX_BYTES,[record.render_path]=Source.MAX_RENDERED_BYTES})
        local verified=Source.verify_snapshot({metadata=metadata,identity=identity,book_id=book,chapter_uid=uid,
            raw=data and data[raw_path],rendered=data and data[record.render_path]})
        if not verified then fail('source_changed') end
        local remote,reason=M.project(verified.raw,book,uid,row)
        if not remote then error(reason,0) end
        local bound=require('weread.lib.source_cloud').bind({file=file,identity=identity,book_id=book,request_id=request_id},remote,read)
        if not bound.position or bound.metadata~=metadata then fail('source_changed') end
        bound.file,bound.identity=file,identity
        return bound
    end)
    if ok then return value end
    return {error=type(value)=='string' and value:match('^my_mark_target/[a-z_]+$') and value or 'my_mark_target/unavailable',request_id=request_id}
end
function M.resolve(book,current_file,row,request_id,read_archive)
    if type(book)~='table' then return {error='my_mark_target/scope',request_id=request_id} end
    local id=Data.id(tostring(book.book_id or book.bookId or ''))
    local uid=type(row)=='table' and tostring(row.chapterUid)
    if not id or not uid then return {error='my_mark_target/scope',request_id=request_id} end
    local seen={}
    local reason='my_mark_target/source_unavailable'
    for _i,file in ipairs({current_file or false,book.cached_chapters and book.cached_chapters[uid] or false,
        book.cached_full_book or false,book.cached_file or false}) do
        if type(file)=='string' and not seen[file] then
            seen[file]=true
            local value=M.bind_file(file,id,row,request_id,read_archive)
            if value.position then return value end
            reason=value.error
        end
    end
    return {error=reason,request_id=request_id}
end
return M
