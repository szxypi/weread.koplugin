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
local function chapter_scope(chapters,selection)
    if type(selection)~='table' or not C.cb_id(selection.book_id) or selection.book_version~=0
        or not C.array(chapters,2,10000) then return nil end
    local indexes=Candidate.chapter_indices(chapters)
    if not indexes then return nil end
    local scope={}
    for i,chapter in ipairs(chapters) do
        local uid=tostring(chapter.chapterUid or chapter.chapterId or chapter.chapter_uid or '')
        local index=indexes[uid]
        if not C.id(uid) or not C.integer(index,0,1000000) then return nil end
        scope[i]={chapterUid=uid,chapterIdx=index}
    end
    return scope
end
function M.references(book,chapters,selection)
    if type(book)~='table' or type(chapters)~='table' then return nil end
    local refs,seen={},{}
    local scope=chapter_scope(chapters,selection)
    local function add(path,uid,full)
        uid=tostring(uid or '')
        local idx=Index(chapters,uid)
        if type(path)=='string' and #path>0 and #path<=4096 and not path:find('%z') and idx~=nil then
            if not seen[path] then
                refs[#refs+1]={file=path,chapter_uid=uid,chapter_idx=idx};seen[path]=#refs
            end
            if full and scope then refs[seen[path]].chapters=scope end
        end
    end
    local first=chapters[1];local first_uid=first and (first.chapterUid or first.chapterId or first.chapter_uid)
    if scope then add(book.cached_full_book,first_uid,true);add(book.cached_file,first_uid,true) end
    for _i,chapter in ipairs(chapters) do
        local uid=tostring(chapter.chapterUid or chapter.chapterId or '')
        add(book.cached_chapters and book.cached_chapters[uid],uid)
    end
    add(book.cached_full_book,first_uid,true);add(book.cached_file,first_uid,true)
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
-- A missing Web version is distinct from zero, null, malformed or conflicting
-- version fields. Only a unique, same-book imported TXT may use this path.
function M.unversioned_cb(payload,id)
    if not C.cb_id(id) then return false end
    local rows=type(payload)=='table' and (payload.data or payload.books or payload)
    if type(rows)~='table' then return false end
    if rows.bookId or rows.book then rows={rows} end
    if not C.array(rows,1,10000) then return false end
    local matches=0
    for _i,row in ipairs(rows) do
        local book=type(row)=='table' and row.book
        local outer,inner
        if type(row)=='table' then outer=row.bookId end
        if type(book)=='table' then inner=book.bookId end
        if outer==id or inner==id then
            if outer~=nil and outer~=id or inner~=nil and inner~=id then return false end
            matches=matches+1
            for _j,node in ipairs({row,type(book)=='table' and book or {}}) do
                if node.bookVersion~=nil or node.version~=nil then return false end
            end
        end
    end
    return matches==1
end
local function local_source(selection,ref,read)
    local meta_path=Source.meta_path(ref.chapter_uid)
    local initial=read(ref.file,{[Identity.PATH]=Identity.MAX_BYTES,[meta_path]=Source.MAX_META_BYTES})
    if not initial then return nil end
    local identity=Identity.decode(initial[Identity.PATH]);local meta=Source.decode_metadata(initial[meta_path])
    if not identity or not meta or identity.book_id~=selection.book_id or identity.file_id~=selection.file_id
        or identity.book_version~=selection.book_version or meta.file_id~=selection.file_id or meta.book_version~=selection.book_version
        or meta.book_id~=selection.book_id or meta.chapter_uid~=ref.chapter_uid then return nil end
    if selection.book_version==0 and (not C.cb_id(selection.book_id) or meta.format~='web_txt' or identity.chapter_count~=1
            or not Identity.has_text_digest(initial[Identity.PATH])) then return nil end
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
        or not C.integer(selection.book_version,C.cb_id(selection.book_id) and 0 or 1,2147483647)
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
            local matches=not previous or type(previous)=='table' and type(previous.ref)=='table'
                and C.digest(ref)==C.digest(previous.ref)
            if matches and local_source(selection,ref,options.read_archive or Archive.read) then
                return {kind='found',reference=ref}
            end
            local scope=position<=2 and chapter_scope(chapters,selection)
            local bundle=scope and require('weread.lib.readtime_source_bundle').inspect(selection,path,scope,options)
            if bundle then
                local first=bundle.entries[1]
                local canonical={file=path,chapter_uid=first.chapter_uid,chapter_idx=first.chapter_idx}
                if not previous or type(previous)=='table' and type(previous.ref)=='table'
                    and C.digest(canonical)==C.digest(previous.ref) then
                    canonical.chapters=scope;return {kind='found',reference=canonical}
                end
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
        local plain={file=ref.file,chapter_uid=ref.chapter_uid,chapter_idx=ref.chapter_idx}
        if not previous or C.digest(plain)==C.digest(previous.ref) then
            chosen=local_source(selection,plain,read)
        end
        if not chosen and selection.book_version==0 and C.array(ref.chapters,2,10000) then
            local bundle=require('weread.lib.readtime_source_bundle')
            local inventory=bundle.inspect(selection,ref.file,ref.chapters,options)
            if inventory then
                local first=inventory.entries[1]
                plain={file=ref.file,chapter_uid=first.chapter_uid,chapter_idx=first.chapter_idx}
                if not previous or C.digest(plain)==C.digest(previous.ref) then
                    local old
                    if previous then old={};for key,value in pairs(previous) do if key~='ref' then old[key]=value end end end
                    local bundle_options={read_archive=options.read_archive,list_metadata=options.list_metadata}
                    if options.fetch then
                        bundle_options.fetch=function(c,e,w,check)
                            return options.fetch(c,e,w,'web_txt',{verify_catalog=check},true)
                        end
                    end
                    local result=bundle.verify(client,selected,selection,ref.file,ref.chapters,old,bundle_options)
                    result.ref=plain
                    return result
                end
            end
        end
        if chosen then break end
    end
    assert(chosen,'readtime_source/archive')
    if previous then
        assert(chosen.format==previous.format and chosen.metadata_hash==previous.metadata_hash
            and C.digest(chosen.expected)==C.digest(previous.expected),'readtime_source/changed')
    end
    assert(not cb or chosen.format=='web_xhtml' or chosen.format=='web_txt','readtime_source/format')
    local function verify_catalog(raw)
        assert(selection.book_version==0 and cb and chosen.format=='web_txt' and M.unversioned_cb(raw,selection.book_id)
            or selection.book_version~=0 and M.version(raw,selection.book_id)==selection.book_version,'readtime_source/version')
    end
    local proof
    if options.fetch then proof=options.fetch(client,chosen.expected,selected,chosen.format,{verify_catalog=verify_catalog},cb)
    elseif cb and chosen.format=='web_txt' then proof=Current.fetch_cb_txt_versioned(client,chosen.expected,selected,verify_catalog)
    elseif cb then proof=Current.fetch_cb_versioned(client,chosen.expected,selected,verify_catalog)
    else proof=Current.fetch(client,chosen.expected,selected,chosen.format,{verify_catalog=verify_catalog}) end
    local checked
    if cb and chosen.format=='web_txt' then checked=Current.packet_cb_txt(proof,chosen.expected)
    elseif cb then checked=Current.packet_cb(proof,chosen.expected)
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
