-- Bounded, worker-only search over source snapshots in downloaded EPUBs.
-- Search candidates are local only; clicking one rechecks its archive and
-- source anchor before any reader movement, and never grants sync authority.
local Access=require('weread.lib.read_access')
local Archive=require('weread.lib.source_archive')
local Coordinates=require('weread.lib.source_coordinates')
local Dom=require('weread.lib.source_dom')
local Identity=require('weread.lib.book_file_identity')
local Protocol=require('weread.lib.protocol')
local Source=require('weread.lib.position_source')
local Crypto=require('weread.lib.crypto')
local UnicodeSearch=require('weread.lib.unicode_search')
local M={MAX_HITS=30,MAX_EXAMINED=100}
M.unicode_casefold_available=UnicodeSearch.available

-- ASCII case folding preserves UTF-8 byte offsets; the original text remains
-- the source of the displayed context and of every navigation anchor.
local function fold_ascii(value)
    return (value:gsub('[A-Z]',function(char) return string.char(char:byte()+32) end))
end

local function path(value)
    return type(value)=='string' and value~='' and #value<=4096 and not value:find('[%z%c]')
end

-- Read only members named by independently decoded metadata; a matching raw
-- hash alone is not enough if the rendered chapter or archive identity changed.
function M.snapshot(file,book,uid,read_archive)
    if not path(file) or not Access.display_book_id(book) or not Access.book_id(uid) then return nil end
    local read=read_archive or Archive.read
    local ok,value=pcall(function()
        local meta_path=Source.meta_path(uid)
        local head=read(file,{[Identity.PATH]=Identity.MAX_BYTES,[meta_path]=Source.MAX_META_BYTES})
        local identity=head and Identity.decode(head[Identity.PATH])
        local metadata=head and head[meta_path]
        local record=Source.decode_metadata(metadata)
        if not identity or not record or identity.book_id~=book or record.book_id~=book
            or record.chapter_uid~=uid or record.file_id~=identity.file_id then return nil end
        local alias=Source.path_meta_path(record.render_path)
        local members=read(file,{[Source.raw_path(record.raw_sha256)]=Source.MAX_BYTES,
            [record.render_path]=Source.MAX_RENDERED_BYTES,[alias]=Source.MAX_META_BYTES})
        if not members or members[alias]~=metadata then return nil end
        local verified=Source.verify_snapshot({metadata=metadata,identity=identity,book_id=book,chapter_uid=uid,
            raw=members[Source.raw_path(record.raw_sha256)],rendered=members[record.render_path]})
        if not verified then return nil end
        return {identity=identity,metadata=metadata,record=verified,metadata_hash=Crypto.sha256_hex(metadata)}
    end)
    return ok and value or nil
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
        local members=(list_metadata or Archive.position_metadata)(input.file)
        if type(members)~='table' or #members>10000 then return {error='unavailable'} end
        local entries,seen_uid,seen_index={}, {}, {}
        local incomplete=false
        for _i,member in ipairs(members) do
            local record=type(member)=='table' and Source.decode_metadata(member.metadata)
            local uid=record and Access.book_id(record.chapter_uid)
            local index=record and record.render_path:match('^OEBPS/text/chapter%-(%d+)%.xhtml$')
            if not index and identity.chapter_count==1 and record and record.render_path=='OEBPS/text/chapter.xhtml' then index='1' end
            index=tonumber(index)
            if not record or not uid or tonumber(uid)>2147483647 or record.book_id~=input.book
                or record.file_id~=identity.file_id or record.book_version~=identity.book_version
                or Source.meta_path(uid)~=member.name or not index or index<1 or index>identity.chapter_count then
                incomplete=true
            elseif seen_uid[uid] or seen_index[index] then
                return {error='ambiguous'}
            else
                seen_uid[uid],seen_index[index]=true,true
                entries[#entries+1]={uid=uid,index=index}
            end
        end
        table.sort(entries,function(a,b) return a.index<b.index end)
        return {entries=entries,incomplete=incomplete or #entries~=identity.chapter_count}
    end)
    return ok and result or {error='unavailable'}
end

function M.scan(input,read_archive)
    local ok,result=pcall(function()
        if type(input)~='table' or type(input.book)~='string' or not Access.display_book_id(input.book)
            or type(input.chapter)~='string' or not Access.book_id(input.chapter)
            or type(input.paths)~='table' or #input.paths<1 or #input.paths>4
            or type(input.keyword)~='string' or #input.keyword<1 or #input.keyword>160
            or input.ignore_ascii_case~=nil and type(input.ignore_ascii_case)~='boolean'
            or type(input.from)~='number' or input.from%1~=0 or input.from<1 or input.from>Source.MAX_BYTES*4+1 then
            return {error='invalid'}
        end
        local keyword=Dom.normalize(input.keyword)
        if not keyword or keyword=='' then return {error='invalid'} end
        local snapshot,map,seen
        seen={}
        for _i,file in ipairs(input.paths) do
            if not path(file) then return {error='invalid'} end
            if not seen[file] then
                seen[file]=true
                local candidate=M.snapshot(file,input.book,input.chapter,read_archive)
                local candidate_map=candidate and Coordinates.build(candidate.record.raw,
                    {format=candidate.record.format,allow_multiple_bodies=true})
                if candidate_map and pcall(candidate_map._index,candidate_map) then
                    snapshot,map=candidate,candidate_map;break
                end
            end
        end
        if not snapshot then return {missing=true,hits={}} end
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
        while #hits<M.MAX_HITS and examined<M.MAX_EXAMINED do
            local first=haystack:find(keyword,at,true)
            if not first then return {hits=hits,complete=true,unresolved=unresolved} end
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
                    hits[#hits+1]={chapter_uid=input.chapter,offset=co,source_hash=record.raw_sha256,
                        file_id=record.file_id,metadata_hash=snapshot.metadata_hash,
                        context=map:snippet(source_first,80) or Protocol.utf8_substr(map.flat:sub(source_first),80)}
                else unresolved=unresolved+1 end
            end
        end
        return {hits=hits,next_byte=resume,unresolved=unresolved}
    end)
    return ok and result or {error='unavailable'}
end

return M
