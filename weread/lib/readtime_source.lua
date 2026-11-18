-- Independent archive + live raw-source proof for one captured ledger file.
-- No inherited document handles, progress POSTs, renewal or file extraction.
local C=require('weread.lib.readtime_transfer_contract')
local Identity=require('weread.lib.book_file_identity')
local Source=require('weread.lib.position_source')
local Archive=require('weread.lib.source_archive')
local Current=require('weread.lib.source_currentness')
local Candidate=require('weread.lib.source_upload_candidate')
local Index=Candidate.chapter_index
local Crypto=require('weread.lib.crypto')
local M={}
function M.references(book,chapters)
    if type(book)~='table' or type(chapters)~='table' then return nil end
    local refs,seen={},{}
    local function add(path,uid)
        uid=tostring(uid or '')
        local idx=Index(chapters,uid)
        if type(path)=='string' and #path>0 and #path<=4096 and not path:find('%z') and idx~=nil and not seen[path] then
            seen[path]=true;refs[#refs+1]={file=path,chapter_uid=uid,chapter_idx=idx}
        end
    end
    for _i,chapter in ipairs(chapters) do
        local uid=tostring(chapter.chapterUid or chapter.chapterId or '')
        add(book.cached_chapters and book.cached_chapters[uid],uid)
    end
    local first=chapters[1];local uid=first and (first.chapterUid or first.chapterId)
    add(book.cached_full_book,uid);add(book.cached_file,uid)
    if #refs==0 or #refs>128 then return nil end
    return refs
end
function M.version(payload,id)
    local rows=type(payload)=='table' and (payload.data or payload.books or payload)
    if type(rows)~='table' then return nil end
    if rows.bookId or rows.book then rows={rows} end
    local result,count
    count=0
    for _i,row in ipairs(rows) do
        local book=type(row)=='table' and row.book
        if type(row)=='table' and tostring(row.bookId or type(book)=='table' and book.bookId)==id then
            count=count+1
            for _j,node in ipairs({row,type(book)=='table' and book or {}}) do
                for _k,key in ipairs({'bookVersion','version'}) do
                    local v=node[key]
                    if v~=nil then
                        if not C.integer(v,1,2147483647) or result and result~=v then return nil end
                        result=v
                    end
                end
            end
        end
    end
    return count==1 and result or nil
end
local function local_source(selection,ref,read)
    local meta_path=Source.meta_path(ref.chapter_uid)
    local initial=read(ref.file,{[Identity.PATH]=Identity.MAX_BYTES,[meta_path]=Source.MAX_META_BYTES})
    if not initial then return nil end
    local identity=Identity.decode(initial[Identity.PATH]);local meta=Source.decode_metadata(initial[meta_path])
    if not identity or not meta or identity.book_id~=selection.book_id or identity.file_id~=selection.file_id
        or identity.book_version~=selection.book_version or meta.file_id~=selection.file_id or meta.book_version~=selection.book_version
        or meta.book_id~=selection.book_id or meta.chapter_uid~=ref.chapter_uid then return nil end
    local members=read(ref.file,{[Identity.PATH]=Identity.MAX_BYTES,[meta_path]=Source.MAX_META_BYTES,
        [Source.raw_path(meta.raw_sha256)]=Source.MAX_BYTES,[meta.render_path]=Source.MAX_RENDERED_BYTES})
    if not members or members[Identity.PATH]~=initial[Identity.PATH] or members[meta_path]~=initial[meta_path] then return nil end
    local verified=Source.verify_snapshot{identity=identity,metadata=members[meta_path],book_id=selection.book_id,
        chapter_uid=ref.chapter_uid,raw=members[Source.raw_path(meta.raw_sha256)],rendered=members[meta.render_path]}
    if not verified then return nil end
    return {expected={book_id=selection.book_id,chapter_uid=ref.chapter_uid,chapter_idx=ref.chapter_idx,
        raw_sha256=meta.raw_sha256,raw_bytes=meta.raw_bytes},format=meta.format,metadata_hash=Crypto.sha256_hex(initial[meta_path]),ref=ref}
end
-- Run only in a background worker. Each call examines a bounded page and
-- returns no source text; later dispatch independently verifies the match.
function M.scan_page(book,chapters,selection,previous,cursor,options)
    options=options or {}
    if type(book)~='table' or not C.array(chapters,1,10000) or type(selection)~='table'
        or not C.book_id(selection.book_id) or not C.hash(selection.file_id)
        or not C.integer(selection.book_version,1,2147483647)
        or not C.integer(cursor,1,#chapters+2) then return {kind='unavailable'} end
    local indexes=Candidate.chapter_indices(chapters)
    if not indexes then return {kind='unavailable'} end
    local last=math.min(cursor+31,#chapters+2)
    for position=cursor,last do
        local chapter=chapters[position<=2 and 1 or position-2]
        local uid=tostring(chapter.chapterUid or chapter.chapterId or chapter.chapter_uid or '')
        local idx=indexes[uid]
        local path=position==1 and book.cached_full_book or position==2 and book.cached_file
            or position>2 and type(book.cached_chapters)=='table' and book.cached_chapters[uid]
        if type(path)=='string' and path~='' and #path<=4096 and not path:find('%z') and idx~=nil then
            local ref={file=path,chapter_uid=uid,chapter_idx=idx}
            if (not previous or type(previous)=='table' and type(previous.ref)=='table' and C.digest(ref)==C.digest(previous.ref))
                and local_source(selection,ref,options.read_archive or Archive.read) then
                return {kind='found',reference=ref}
            end
        end
    end
    return last<#chapters+2 and {kind='more',cursor=last+1} or {kind='unavailable'}
end
function M.observe(client,selected,selection,references,previous,options)
    options=options or {};local read=options.read_archive or Archive.read
    assert(type(selection)=='table' and C.book_id(selection.book_id),'readtime_source/selection')
    local cb=C.cb_id(selection.book_id)
    assert(C.array(references,1,128),'readtime_source/references')
    local chosen
    for _i,ref in ipairs(references) do
        assert(type(ref)=='table' and type(ref.file)=='string' and C.id(ref.chapter_uid) and C.integer(ref.chapter_idx,0,1000000),'readtime_source/reference')
        if not previous or C.digest(ref)==C.digest(previous.ref) then chosen=local_source(selection,ref,read) end
        if chosen then break end
    end
    assert(chosen,'readtime_source/archive')
    if previous then
        assert(chosen.format==previous.format and chosen.metadata_hash==previous.metadata_hash
            and C.digest(chosen.expected)==C.digest(previous.expected),'readtime_source/changed')
    end
    assert(not cb or chosen.format=='web_xhtml','readtime_source/format')
    local function verify_catalog(raw)
        assert(M.version(raw,selection.book_id)==selection.book_version,'readtime_source/version')
    end
    local proof
    if options.fetch then proof=options.fetch(client,chosen.expected,selected,chosen.format,{verify_catalog=verify_catalog},cb)
    elseif cb then proof=Current.fetch_cb_versioned(client,chosen.expected,selected,verify_catalog)
    else proof=Current.fetch(client,chosen.expected,selected,chosen.format,{verify_catalog=verify_catalog}) end
    local checked
    if cb then checked=Current.packet_cb(proof,chosen.expected)
    elseif chosen.format=='web_txt' then checked=Current.packet_txt(proof,chosen.expected)
    else checked=Current.packet(proof,chosen.expected) end
    assert(checked,'readtime_source/remote')
    chosen.catalog_stamp=checked.catalog_stamp
    local again=local_source(selection,chosen.ref,read)
    assert(again and C.digest(again)==C.digest({expected=chosen.expected,format=chosen.format,metadata_hash=chosen.metadata_hash,ref=chosen.ref}),'readtime_source/changed')
    if previous then assert(chosen.catalog_stamp==previous.catalog_stamp,'readtime_source/catalog') end
    return chosen
end
return M
