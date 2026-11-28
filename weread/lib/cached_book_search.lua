-- Bounded, worker-only search over source snapshots in downloaded EPUBs.
-- Search candidates are local only; clicking one rechecks its archive and
-- source anchor before any reader movement, and never grants sync authority.
local Access=require('weread.lib.read_access')
local Archive=require('weread.lib.source_archive')
local Catalog=require('weread.lib.chapter_catalog')
local Coordinates=require('weread.lib.source_coordinates')
local Dom=require('weread.lib.source_dom')
local Identity=require('weread.lib.book_file_identity')
local Protocol=require('weread.lib.protocol')
local Source=require('weread.lib.position_source')
local Crypto=require('weread.lib.crypto')
local UnicodeSearch=require('weread.lib.unicode_search')
local M={MAX_HITS=30,MAX_EXAMINED=100,MAX_ARCHIVE_BATCH=math.floor((Archive.MAX_BATCH_MEMBERS-1)/4)}
M.unicode_casefold_available=UnicodeSearch.available

-- ASCII case folding preserves UTF-8 byte offsets; the original text remains
-- the source of the displayed context and of every navigation anchor.
local function fold_ascii(value)
    return (value:gsub('[A-Z]',function(char) return string.char(char:byte()+32) end))
end

local function path(value)
    return type(value)=='string' and value~='' and #value<=4096 and not value:find('[%z%c]')
end

function M.valid_capture_id(value)
    return type(value)=='string' and #value==64 and value:match('^[0-9a-f]+$')~=nil
end

-- Read only members named by independently decoded metadata; a matching raw
-- hash alone is not enough if the rendered chapter or archive identity changed.
local function read_snapshot(file,book,uid,read_archive,with_metadata_hash)
    if not path(file) or not Access.display_book_id(book) or not Access.book_id(uid) then return nil end
    local read=read_archive or Archive.read
    local ok,value=pcall(function()
        local meta_path=Source.meta_path(uid)
        local head=read(file,{[Identity.PATH]=Identity.MAX_BYTES,[meta_path]=Source.MAX_META_BYTES})
        local identity=head and Identity.decode(head[Identity.PATH])
        local metadata=head and head[meta_path]
        local verified=Source.verify_snapshot({metadata=metadata,identity=identity,book_id=book,chapter_uid=uid},
            function(render_path,raw_hash)
                local raw_path=Source.raw_path(raw_hash)
                local alias=Source.path_meta_path(render_path)
                local members=read(file,{[raw_path]=Source.MAX_BYTES,[render_path]=Source.MAX_RENDERED_BYTES,
                    [alias]=Source.MAX_META_BYTES})
                if members and members[alias]==metadata then return members[raw_path],members[render_path] end
            end)
        if not verified then return nil end
        local snapshot={identity=identity,metadata=metadata,record=verified}
        if with_metadata_hash then snapshot.metadata_hash=Crypto.sha256_hex(metadata) end
        return snapshot
    end)
    return ok and value or nil
end

function M.snapshot(file,book,uid,read_archive)
    return read_snapshot(file,book,uid,read_archive,true)
end

-- A full EPUB retains sealed UID-to-render-path metadata even when the
-- external catalog and all single-chapter mappings are gone. This is only a
-- discovery list: each chapter is independently verified before searching.
function M.discover(input,read_archive,list_metadata)
    local ok,result=pcall(function()
        if type(input)~='table' or type(input.book)~='string' or not Access.display_book_id(input.book)
            or not path(input.file) then return {error='invalid'} end
        local read=read_archive or Archive.read
        local head=read(input.file,{[Identity.PATH]=Identity.MAX_BYTES})
        local identity=head and Identity.decode(head[Identity.PATH])
        if not identity or identity.book_id~=input.book then return {error='unavailable'} end
        local entries,seen_uid,seen_index={}, {}, {}
        local incomplete,ambiguous=false,false
        local function visit(name,metadata)
            local record=Source.decode_metadata(metadata)
            local uid=record and Access.book_id(record.chapter_uid)
            local index=record and record.render_path:match('^OEBPS/text/chapter%-(%d+)%.xhtml$')
            if not index and identity.chapter_count==1 and record and record.render_path=='OEBPS/text/chapter.xhtml' then index='1' end
            index=tonumber(index)
            if not record or not uid or record.book_id~=input.book
                or record.file_id~=identity.file_id or record.book_version~=identity.book_version
                or Source.meta_path(uid)~=name or not index or index<1 or index>identity.chapter_count then
                incomplete=true
            elseif seen_uid[uid] or seen_index[index] then
                ambiguous=true;return false
            else
                seen_uid[uid],seen_index[index]=true,true
                entries[#entries+1]={uid=uid,index=index,raw_sha256=record.raw_sha256,render_path=record.render_path}
            end
        end
        if list_metadata then
            local members=list_metadata(input.file)
            if type(members)~='table' or #members>Catalog.MAX_CHAPTERS then return {error='unavailable'} end
            for _,member in ipairs(members) do
                if type(member)~='table' then incomplete=true
                elseif visit(member.name,member.metadata)==false then break end
            end
        elseif not Archive.position_metadata(input.file,visit) and not ambiguous then
            return {error='unavailable'}
        end
        if ambiguous then return {error='ambiguous'} end
        table.sort(entries,function(a,b) return a.index<b.index end)
        return {entries=entries,incomplete=incomplete or #entries~=identity.chapter_count}
    end)
    return ok and result or {error='unavailable'}
end

-- Use one bounded archive pass for a range of discovered chapters. The
-- regular snapshot checks still verify each requested member's identity and
-- hashes, including when a range was built from an older version of the file.
function M.batch_reader(file,requests)
    local wanted={[Identity.PATH]=Identity.MAX_BYTES}
    for _i,request in ipairs(requests) do
        local entry=request.archive
        local raw=Source.raw_path(entry.raw_sha256)
        if not raw then return nil end
        wanted[Source.meta_path(request.chapter)]=Source.MAX_META_BYTES
        wanted[Source.path_meta_path(entry.render_path)]=Source.MAX_META_BYTES
        wanted[entry.render_path]=Source.MAX_RENDERED_BYTES
        wanted[raw]=Source.MAX_BYTES
    end
    local members=Archive.read_batch(file,wanted)
    if not members then return nil end
    return function(pathname,names)
        if pathname~=file then return Archive.read(pathname,names) end
        local found={}
        for name,maximum in pairs(names) do
            local data=members[name]
            if not data or #data>maximum then return nil end
            found[name]=data
        end
        return found
    end
end

function M.scan(input,read_archive)
    local ok,result=pcall(function()
        if type(input)~='table' or type(input.book)~='string' or not Access.display_book_id(input.book)
            or type(input.chapter)~='string' or not Access.book_id(input.chapter)
            or type(input.paths)~='table' or #input.paths<1 or #input.paths>4
            or type(input.keyword)~='string' or #input.keyword<1 or #input.keyword>160
            or input.ignore_ascii_case~=nil and type(input.ignore_ascii_case)~='boolean'
            or type(input.from)~='number' or input.from%1~=0 or input.from<1 or input.from>Source.MAX_BYTES*4+1
            or input.from>1 and not M.valid_capture_id(input.capture_id)
            or input.from==1 and input.capture_id~=nil then
            return {error='invalid'}
        end
        local keyword=Dom.normalize(input.keyword)
        if not keyword or keyword=='' then return {error='invalid'} end
        local snapshot,map,seen
        local source_changed=false
        seen={}
        for _i,file in ipairs(input.paths) do
            if not path(file) then return {error='invalid'} end
            if not seen[file] then
                seen[file]=true
                local candidate=read_snapshot(file,input.book,input.chapter,read_archive)
                if not candidate and input.capture_id and read_archive then
                    -- A replacement can have members outside the earlier archive index.
                    candidate=read_snapshot(file,input.book,input.chapter)
                end
                if candidate then
                    -- A capture identifies the original bytes and format across EPUB copies.
                    if input.capture_id and candidate.record.capture_id~=input.capture_id then
                        source_changed=true
                    else
                        local candidate_map=Coordinates.build(candidate.record.raw,
                            {format=candidate.record.format,allow_multiple_bodies=true})
                        if candidate_map and pcall(candidate_map._index,candidate_map) then
                            snapshot,map=candidate,candidate_map;break
                        end
                    end
                end
            end
        end
        if not snapshot then return {missing=true,source_changed=source_changed or nil,hits={}} end
        local record=snapshot.record
        local haystack=map.flat
        local unicode,at,resume=nil,input.from,input.from
        if input.ignore_ascii_case then
            if UnicodeSearch.available() and (haystack:find('[\128-\255]') or keyword:find('[\128-\255]')) then
                local reason
                unicode,reason=UnicodeSearch.build(haystack,input.from,keyword)
                if not unicode then return {error=reason or 'unavailable'} end
                haystack,keyword,at=unicode.text,unicode.needle,1
            else haystack,keyword=fold_ascii(haystack),fold_ascii(keyword) end
        end
        local hits,examined,unresolved={},0,0
        local metadata_hash
        local function finish_scan(next_byte)
            return {hits=hits,next_byte=next_byte,complete=next_byte==nil,unresolved=unresolved,
                capture_id=(next_byte or input.capture_id) and record.capture_id or nil}
        end
        while #hits<M.MAX_HITS and examined<M.MAX_EXAMINED do
            local first=haystack:find(keyword,at,true)
            if not first then return finish_scan() end
            examined=examined+1
            local source_first,exact,last=first,true,first+#keyword-1
            if unicode then
                local source_size,starts
                source_first,source_size,starts=unicode.locate(first)
                local ending,_,_,end_of_character=unicode.locate(last)
                exact=source_first~=nil and source_size>0 and ending~=nil and starts and end_of_character==last
                resume=source_first and source_first+1 or resume
            else resume=first+1 end
            at=first+1
            if exact then
                local found,co=pcall(map._point,map,source_first)
                local anchor=found and type(co)=='number' and (map:anchor(co,{segment_only=true}) or map:anchor(co))
                if anchor then
                    metadata_hash=metadata_hash or Crypto.sha256_hex(snapshot.metadata)
                    hits[#hits+1]={chapter_uid=input.chapter,offset=co,source_hash=record.raw_sha256,
                        file_id=record.file_id,metadata_hash=metadata_hash,
                        context=map:snippet(source_first,80) or Protocol.utf8_substr(map.flat:sub(source_first),80)}
                else unresolved=unresolved+1 end
            end
        end
        local next_byte=haystack:find(keyword,at,true) and resume or nil
        return finish_scan(next_byte)
    end)
    return ok and result or {error='unavailable'}
end

return M
