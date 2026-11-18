-- Local inventory for an entire unversioned imported TXT archive. This is a
-- source description only: a caller must still compare every chapter with
-- the current service before using it to authorize any account operation.
local C=require('weread.lib.readtime_transfer_contract')
local Identity=require('weread.lib.book_file_identity')
local Search=require('weread.lib.cached_book_search')
local Archive=require('weread.lib.source_archive')
local Candidate=require('weread.lib.source_upload_candidate')
local Current=require('weread.lib.source_currentness')
local M={}

local function version(value)
    local json=package.loaded.json
    if value==nil or type(json)=='table' and (value==json.null or type(json.util)=='table' and value==json.util.null) then return '' end
    if C.integer(value,0,9007199254740991) then return string.format('%.0f',value) end
    if type(value)=='string' and #value>=1 and #value<=19 and value:match('^%d+$') then
        local clean=value:gsub('^0+','');return clean~='' and clean or '0'
    end
    error('readtime_bundle/catalog',0)
end

function M.inspect(selection,file,chapters,options)
    options=options or {}
    if type(selection)~='table' or not C.cb_id(selection.book_id) or selection.book_version~=0
        or not C.hash(selection.file_id) or type(file)~='string' or file=='' or #file>4096
        or file:find('[%z%c]') or not C.array(chapters,2,10000) then return nil end
    local indexes=Candidate.chapter_indices(chapters)
    if not indexes then return nil end
    local read=options.read_archive or Archive.read
    local list=options.list_metadata or Archive.position_metadata
    local ok,result=pcall(function()
        local root=read(file,{[Identity.PATH]=Identity.MAX_BYTES})
        local raw=root and root[Identity.PATH]
        local identity=Identity.decode(raw)
        if not identity or identity.book_id~=selection.book_id or identity.book_version~=0
            or identity.file_id~=selection.file_id or identity.chapter_count~=#chapters
            or not Identity.has_text_digest(raw) then return nil end
        local listed=list(file)
        local discovered=Search.discover({book=selection.book_id,file=file},read,function() return listed end)
        if type(discovered)~='table' or discovered.error or discovered.incomplete
            or not C.array(discovered.entries,#chapters,#chapters) then return nil end
        local entries,seen_index={},{}
        for i,item in ipairs(discovered.entries) do
            local chapter=chapters[i]
            local uid=tostring(chapter.chapterUid or chapter.chapterId or chapter.chapter_uid or '')
            local idx=indexes[uid]
            if item.index~=i or item.uid~=uid or not C.id(uid) or not C.integer(idx,0,1000000)
                or seen_index[idx] then return nil end
            seen_index[idx]=true
            local snapshot=Search.snapshot(file,selection.book_id,uid,read)
            local info=snapshot and snapshot.record
            if not snapshot or snapshot.identity.file_id~=selection.file_id or snapshot.identity.book_version~=0
                or snapshot.identity.chapter_count~=#chapters or not info or info.format~='web_txt' then return nil end
            entries[i]={book_id=selection.book_id,chapter_uid=uid,chapter_idx=idx,
                raw_sha256=info.raw_sha256,raw_bytes=info.raw_bytes,metadata_hash=snapshot.metadata_hash}
        end
        -- Detect replacement or metadata-list changes while the chapters were read.
        local last=read(file,{[Identity.PATH]=Identity.MAX_BYTES})
        local relisted=list(file)
        local after=Search.discover({book=selection.book_id,file=file},read,function() return relisted end)
        if not last or last[Identity.PATH]~=raw or type(after)~='table' or after.error or after.incomplete
            or C.digest(relisted)~=C.digest(listed) or C.digest(after.entries)~=C.digest(discovered.entries) then return nil end
        return {file=file,book_id=selection.book_id,file_id=selection.file_id,book_version=0,
            format='web_txt',entries=entries,inventory_hash=C.digest(entries)}
    end)
    return ok and result or nil
end

-- Read-only remote comparison. All chapter catalogs must describe the same
-- complete inventory on both sides of every source read. The compact result
-- may be retained, but it is never by itself permission to send a request.
function M.verify(client,web,selection,file,chapters,previous,options)
    options=options or {}
    local inventory=assert(M.inspect(selection,file,chapters,options),'readtime_bundle/archive')
    local stamp
    local function catalog(raw)
        assert(require('weread.lib.readtime_source').unversioned_cb(raw,selection.book_id),'readtime_bundle/version')
        local rows=raw.data or raw.books or raw
        if rows.bookId or rows.book then rows={rows} end
        local selected
        for _i,row in ipairs(rows) do
            local nested=type(row)=='table' and row.book
            if type(row)=='table' and (row.bookId==selection.book_id
                    or type(nested)=='table' and nested.bookId==selection.book_id) then selected=row end
        end
        local remote=selected and (selected.updated or selected.chapterInfos or selected.chapters)
        assert(C.array(remote,#inventory.entries,#inventory.entries),'readtime_bundle/catalog')
        for i,row in ipairs(remote) do
            local uid=type(row)=='table' and tostring(row.chapterUid or row.chapterId or row.chapter_uid or '')
            assert(uid==inventory.entries[i].chapter_uid,'readtime_bundle/catalog')
        end
        local indexes=assert(Candidate.chapter_indices(remote),'readtime_bundle/catalog')
        local parts={}
        for _i,node in ipairs({selected,type(selected.book)=='table' and selected.book or {}}) do
            for _j,key in ipairs({'bookVersion','version','contentVersion'}) do parts[#parts+1]=version(node[key]) end
        end
        for i,entry in ipairs(inventory.entries) do
            assert(indexes[entry.chapter_uid]==entry.chapter_idx,'readtime_bundle/catalog')
            parts[#parts+1]=entry.chapter_uid;parts[#parts+1]=entry.chapter_idx
            for _j,key in ipairs({'bookVersion','version','contentVersion'}) do parts[#parts+1]=version(remote[i][key]) end
        end
        local candidate=C.digest(parts)
        assert(not stamp or stamp==candidate,'readtime_bundle/catalog_changed')
        stamp=candidate
    end
    local fetch=options.fetch or Current.fetch_cb_txt_versioned
    for _i,entry in ipairs(inventory.entries) do
        local expected={book_id=entry.book_id,chapter_uid=entry.chapter_uid,chapter_idx=entry.chapter_idx,
            raw_sha256=entry.raw_sha256,raw_bytes=entry.raw_bytes}
        local checks=0
        local proof=fetch(client,expected,web,function(raw) checks=checks+1;catalog(raw) end)
        assert(checks==2 and Current.packet_cb_txt(proof,expected),'readtime_bundle/remote')
    end
    local after=assert(M.inspect(selection,file,chapters,options),'readtime_bundle/archive')
    assert(after.inventory_hash==inventory.inventory_hash and stamp,'readtime_bundle/changed')
    local result={file=file,book_id=selection.book_id,file_id=selection.file_id,book_version=0,format='web_txt',
        inventory_hash=inventory.inventory_hash,catalog_stamp=stamp,chapter_count=#inventory.entries}
    if previous then assert(C.digest(result)==C.digest(previous),'readtime_bundle/changed') end
    return result
end

return M
