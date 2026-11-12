-- Source-bound selection references. Draft IDs retain only chapter/range/hash;
-- restoring them requires the same verified source in a known cached EPUB.
local Quote=require('weread.lib.selection_quote')
local Source=require('weread.lib.position_source')
local Identity=require('weread.lib.book_file_identity')
local Currentness=require('weread.lib.source_currentness')
local Candidate=require('weread.lib.source_upload_candidate')
local Marks=require('weread.lib.my_cloud_marks')
local Dom=require('weread.lib.source_dom')
local Raw=require('weread.lib.annotation_source')
local Coordinates=require('weread.lib.source_coordinates')
local M={}
local function fail(reason) error('selection_reference/'..reason,0) end
local function hash(v) return type(v)=='string' and #v==64 and v:match('^[a-f0-9]+$') end
local function trim(text)
    local first,last
    for at,char in text:gmatch('()([%z\1-\127\194-\244][\128-\191]*)') do
        if Dom.normalize(char)~='' then first=first or at;last=at+#char-1 end
    end
    return first and text:sub(first,last) or ''
end
local function identifier(uid,range,sha) return 'selection:'..uid..':'..range..':'..sha end
function M.parse(value)
    if type(value)~='string' or #value>256 then return nil end
    local uid,first,last,sha=value:match('^selection:(%d+):(%d+)%-(%d+):([a-f0-9]+)$')
    if not Marks.id(uid) or #uid>10 or tonumber(uid)>2147483647 or not hash(sha)
        or not first or #first>10 or #last>10 or tostring(tonumber(first))~=first or tostring(tonumber(last))~=last
        or tonumber(first)>=tonumber(last) or tonumber(last)>2147483647 then return nil end
    return {chapter_uid=uid,range=first..'-'..last,raw_sha256=sha}
end
function M.valid(row,book)
    local ref=type(row)=='table' and M.parse(row.bookmarkId)
    local expected=type(row)=='table' and Currentness.expected(row.source)
    local normalized=type(row)=='table' and type(row.markText)=='string' and Dom.normalize(row.markText)
    return ref and expected and row.selection==true and row.type==1 and Marks.id(book)==book
        and expected.book_id==book and expected.chapter_uid==ref.chapter_uid and expected.raw_sha256==ref.raw_sha256
        and row.chapterUid==tonumber(ref.chapter_uid) and row.chapterIdx==expected.chapter_idx and row.range==ref.range
        and type(row.markText)=='string' and #row.markText>0 and #row.markText<=Quote.MAX_QUOTE
        and not row.markText:find('[%z\1-\8\11-\31\127]') and normalized~=nil and normalized~='' or false
end
local function archive(file,book,uid,read)
    if type(file)~='string' or file=='' or #file>4096 or file:find('[%z%c]') then fail('file') end
    read=read or require('weread.lib.source_archive').read
    local data=read(file,{[Identity.PATH]=Identity.MAX_BYTES,[Source.meta_path(uid)]=Source.MAX_META_BYTES})
    local identity=data and Identity.decode(data[Identity.PATH]);local meta=data and data[Source.meta_path(uid)]
    local record=Source.decode_metadata(meta)
    if not identity or identity.book_id~=book or not record or record.book_id~=book or record.chapter_uid~=uid
        or record.file_id~=identity.file_id or record.format~='web_xhtml' then fail('source') end
    local raw_path=Source.raw_path(record.raw_sha256)
    data=read(file,{[raw_path]=Source.MAX_BYTES,[record.render_path]=Source.MAX_RENDERED_BYTES})
    local verified=Source.verify_snapshot{metadata=meta,identity=identity,book_id=book,chapter_uid=uid,
        raw=data and data[raw_path],rendered=data and data[record.render_path]}
    if not verified then fail('source') end
    return verified.raw,record,meta
end
local function reference(book,uid,index,value)
    if not Marks.id(book) or not Marks.id(uid) or index==nil then fail('catalog') end
    local row={selection=true,type=1,bookmarkId=identifier(uid,value.range,value.raw_sha256),range=value.range,
        chapterUid=tonumber(uid),chapterIdx=index,markText=value.abstract,source={book_id=book,chapter_uid=uid,
            chapter_idx=index,raw_sha256=value.raw_sha256,raw_bytes=value.raw_bytes}}
    if not M.valid(row,book) then fail('reference') end;return row
end
local function guarded(task)
    local ok,value=pcall(task)
    if ok then return value end
    return nil,type(value)=='string' and value:match('^selection_reference/[a-z_]+$') and value or 'selection_reference/unavailable'
end
function M.capture(input,read)
    return guarded(function()
        if type(input)~='table' or not Marks.id(input.book_id) or not Marks.id(input.chapter_uid) then fail('scope') end
        local raw=archive(input.file,input.book_id,input.chapter_uid,read)
        local value=Quote.project(raw,input.first,input.last,input.text);if not value then fail('selection') end
        return reference(input.book_id,input.chapter_uid,Candidate.chapter_index(input.chapters,input.chapter_uid),value)
    end)
end
function M.capture_native(input,read)
    return guarded(function()
        local a,b=input.first,input.last
        if type(a)~='table' or type(b)~='table' or not Marks.id(a.book_id) or not Marks.id(a.chapter_uid)
            or type(a.identity)~='table' or type(b.identity)~='table' then fail('selection') end
        for _i,key in ipairs({'book_id','chapter_uid','file','metadata','render_path'}) do if a[key]~=b[key] then fail('selection') end end
        local raw,record,metadata=archive(a.file,a.book_id,a.chapter_uid,read)
        if a.metadata~=metadata or a.render_path~=record.render_path or a.identity.file_id~=record.file_id
            or b.identity.file_id~=record.file_id or a.identity.book_version~=record.book_version or b.identity.book_version~=record.book_version then fail('source_changed') end
        local map=Coordinates.build(raw,{allow_multiple_bodies=true});if not map then fail('source') end
        local function endpoint(context,label)
            local text=context.text;local offset=context.point_offset
            if type(text)~='string' or #text>8192 or Dom.normalize(text)~=text or type(offset)~='number'
                or offset<0 or offset%1~=0 then fail('selection') end
            local points={};for at in text:gmatch('()[%z\1-\127\194-\244][\128-\191]*') do points[#points+1]=at end
            points[#points+1]=#text+1
            if offset>=#points then fail('selection') end
            local found={};local target=offset+1
            local function attempt(first,last)
                local quote=text:sub(points[first],points[last]-1)
                local located=map:locate(quote)
                if not located then return end
                local point=map:locate_point(quote,target-first)
                local byte=point and Quote.boundary(map,point.co)
                if byte and byte==located.first+points[target]-points[first] then found[byte]=found[byte] or point.co end
            end
            for _i,width in ipairs({24,48,96,192}) do
                local first,last=math.max(1,target-width),math.min(#points,target+width)
                attempt(first,last);attempt(target,last);attempt(first,target)
            end
            if not next(found) then fail(label..'_unmatched') end;return found
        end
        -- Moving a footnote can give a one-sided endpoint context a different
        -- source neighbor. Match both endpoints together with the complete
        -- native selection, then require one unique canonical raw range.
        local starts,ends=endpoint(a,'start'),endpoint(b,'end')
        local text=Dom.normalize(input.text);local choices={}
        for first_byte,first in pairs(starts) do
            for last_byte,last in pairs(ends) do
                if first_byte<last_byte and map.flat:sub(first_byte,last_byte-1)==text then
                    local value=Quote.project(raw,first,last,input.text)
                    if value then choices[value.range]=value end
                end
            end
        end
        local value,count=nil,0;for _range,result in pairs(choices) do value,count=result,count+1 end
        if count~=1 then fail(count==0 and 'quote_boundary' or 'quote_ambiguous') end
        return reference(a.book_id,a.chapter_uid,Candidate.chapter_index(input.chapters,a.chapter_uid),value)
    end)
end
function M.restore(book,current_file,key,read)
    return guarded(function()
        local parsed=M.parse(key);local id=type(book)=='table' and tostring(book.book_id or book.bookId or '')
        if not parsed or not Marks.id(id) then fail('scope') end
        local index=Candidate.chapter_index(book.chapters,parsed.chapter_uid);if index==nil then fail('catalog') end
        local seen={}
        for _i,file in ipairs({current_file or false,book.cached_chapters and book.cached_chapters[parsed.chapter_uid] or false,
            book.cached_full_book or false,book.cached_file or false}) do
            if type(file)=='string' and not seen[file] then
                seen[file]=true
                local ok,raw,record=pcall(archive,file,id,parsed.chapter_uid,read)
                if ok and record.raw_sha256==parsed.raw_sha256 then
                    local quote=trim(Raw.quote(Raw.index(raw,{body_only=true}),parsed.range))
                    local row=reference(id,parsed.chapter_uid,index,{range=parsed.range,abstract=quote,
                        raw_sha256=record.raw_sha256,raw_bytes=record.raw_bytes})
                    return row
                end
            end
        end
        fail('source_changed')
    end)
end
function M.same(a,b)
    for _i,key in ipairs({'selection','type','bookmarkId','range','chapterUid','chapterIdx','markText'}) do if a[key]~=b[key] then return false end end
    for key,value in pairs(a.source) do if b.source[key]~=value then return false end end
    for key,value in pairs(b.source) do if a.source[key]~=value then return false end end
    return true
end
function M.verify(row,book,current_file,read)
    if type(book)~='table' or not M.valid(row,tostring(book.book_id or book.bookId or '')) then return nil end
    local restored=M.restore(book,current_file,row.bookmarkId,read)
    return restored and M.same(restored,row) and restored or nil
end
return M
