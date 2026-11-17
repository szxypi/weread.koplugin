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
local M={MAX_HITS=30,MAX_EXAMINED=100}

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

function M.scan(input,read_archive)
    local ok,result=pcall(function()
        if type(input)~='table' or type(input.book)~='string' or not Access.display_book_id(input.book)
            or type(input.chapter)~='string' or not Access.book_id(input.chapter)
            or type(input.paths)~='table' or #input.paths<1 or #input.paths>4
            or type(input.keyword)~='string' or #input.keyword<1 or #input.keyword>160
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
        local hits,at,examined,unresolved={},input.from,0,0
        while #hits<M.MAX_HITS and examined<M.MAX_EXAMINED do
            local first=map.flat:find(keyword,at,true)
            if not first then return {hits=hits,complete=true,unresolved=unresolved} end
            examined=examined+1
            local found,co=pcall(map._point,map,first)
            at=first+1
            local anchor=found and type(co)=='number' and (map:anchor(co,{segment_only=true}) or map:anchor(co))
            if anchor then
                hits[#hits+1]={chapter_uid=input.chapter,offset=co,source_hash=record.raw_sha256,
                    file_id=record.file_id,metadata_hash=snapshot.metadata_hash,
                    context=Protocol.utf8_substr(map.flat:sub(first),80)}
            else unresolved=unresolved+1 end
        end
        return {hits=hits,next_byte=at,unresolved=unresolved}
    end)
    return ok and result or {error='unavailable'}
end

return M
