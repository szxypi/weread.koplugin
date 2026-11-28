-- Disambiguate old chapter mappings that point to the same EPUB.
local Catalog=require('weread.lib.chapter_catalog')
local Context=require('weread.lib.reader_context')
local Identity=require('weread.lib.book_file_identity')
local Protocol=require('weread.lib.protocol')
local Crypto=require('weread.lib.crypto')
local M={}
local counts_key={}

local function cached_chapters(book)
    return type(book.cached_chapters)=='table' and book.cached_chapters or {}
end

local function chapter_key(key)
    local ok,id=pcall(Context.identifier,key,true)
    return ok and id or 'invalid:'..tostring(key)
end

local function scan_path(book,path)
    local reference,chapter
    for key,value in pairs(cached_chapters(book)) do
        if value==path then
            local id=chapter_key(key)
            if reference and reference~=id then return true end
            reference,chapter=id,tostring(key)
        end
    end
    return reference,chapter
end

local function shared_reference(book,path,reference)
    return reference==true or reference~=nil and book.cached_full_book==path
end

-- The reader needs the mapped chapter and the ambiguity check for one file.
function M.mapped_chapter(book,path)
    if type(book)~='table' or type(path)~='string' then return nil,false end
    local reference,chapter=scan_path(book,path)
    return chapter,shared_reference(book,path,reference)
end

function M.shared(book,path,cache)
    if type(book)~='table' or type(path)~='string' then return false,false end
    if not cache then
        local reference=scan_path(book,path)
        return shared_reference(book,path,reference),reference~=nil
    end
    -- Callers checking many paths can build the index once for their action.
    local counts=cache[counts_key]
    if not counts then
        counts={}
        for key,value in pairs(cached_chapters(book)) do
            if type(value)=='string' then
                local id=chapter_key(key)
                if counts[value]==nil then counts[value]=id
                elseif counts[value]~=id then counts[value]=true end
            end
        end
        cache[counts_key]=counts
    end
    local reference=counts[path]
    return shared_reference(book,path,reference),reference~=nil
end

-- Superseded single-chapter downloads remain registered for their local notes.
local function registered_single(book,path)
    local documents=type(book)=='table' and book.annotation_documents
    local descriptor=type(documents)=='table' and documents[path]
    local chapters=type(descriptor)=='table' and descriptor.clean==true and descriptor.chapters
    if type(chapters)~='table' or #chapters~=1 or type(chapters[1])~='table' then return nil end
    local chapter=chapters[1]
    local ok,uid=pcall(Context.identifier,chapter.chapterUid or chapter.chapterId,true)
    if ok and (chapter.chapterUid==nil or chapter.chapterId==nil
        or tostring(chapter.chapterUid)==tostring(chapter.chapterId)) then return uid end
end

function M.retained_single(book,path)
    local uid=registered_single(book,path)
    if not uid or book.cached_full_book==path then return nil end
    if book.cached_file~=path then return uid end
    -- Older downloads used cached_file for both books and individual chapters.
    local replacement=require('weread.lib.read_access').cached_chapter(book.cached_chapters,uid)
    if type(replacement)=='string' and replacement~='' and replacement~=path then return uid end
end

local function spine_claim(opf,identity)
    if type(opf)~='string' or #opf>Catalog.MAX_PACKAGE_BYTES then return end
    local source,count=opf:match('<dc:source>([^<]+)</dc:source>'),0
    for _ in opf:gmatch('<dc:source>') do count=count+1 end
    local spine=opf:match('<spine[^>]*>(.-)</spine>')
    if count~=1 or not source or not spine then return end
    local items,order,n={},{},0
    for ref in spine:gmatch('<itemref%s+idref="([^"]+)"%s*/>') do
        if items[ref] then return end
        if ref~='cover' then n=n+1;order[n]=ref end
        if n>20000 then return end
        items[ref]=true
    end
    if n>0 and (not identity or identity.chapter_count==n) then return source,items,order end
end

function M.document_single(document,id,uid)
    local identity=Identity.read_document(document,id)
    if identity.book_id~=tostring(id) or identity.chapter_count~=1 or identity.file_id=='' then return false end
    local ok,opf=pcall(document.getDocumentFileContent,document,'OEBPS/content.opf')
    if not ok then return false end
    local source,items=spine_claim(opf,identity)
    return source==Protocol.reader_url(id,uid) and items.chapter==true
end

local function inspect(book,path)
    local ok,result=pcall(function()
        local id=Context.book_id(book)
        local Archive=require('weread.lib.source_archive')
        local members=Archive.read(path,{['OEBPS/content.opf']=Catalog.MAX_PACKAGE_BYTES,[Identity.PATH]=Identity.MAX_BYTES})
        local identity=members and Identity.decode(members[Identity.PATH])
        if members and not identity then return {kind='unknown'} end
        if not members then members=Archive.read(path,{['OEBPS/content.opf']=Catalog.MAX_PACKAGE_BYTES}) end
        local opf=members and members['OEBPS/content.opf']
        if identity and identity.book_id~=id then return {kind='unknown'} end
        local source,items,order=spine_claim(opf,identity)
        if not source then return {kind='unknown'} end
        if source==Protocol.reader_url(id) and not items.chapter then
            for ref in pairs(items) do
                if ref~='cover' and not ref:match('^chapter_[%w_-]+$') then return {kind='unknown'} end
            end
            return {kind='combined',items=items,order=order,opf_hash=Crypto.sha256_hex(opf),
                file_id=identity and identity.file_id or nil,book_version=identity and identity.book_version or nil}
        end
        if #order~=1 or not items.chapter then return {kind='unknown'} end
        local matching
        for key,value in pairs(book.cached_chapters or {}) do
            if value==path then
                local valid,uid=pcall(Context.identifier,key,true)
                if not valid then return {kind='unknown'} end
                if source==Protocol.reader_url(id,uid) then
                    if matching and matching~=uid then return {kind='unknown'} end
                    matching=uid
                end
            end
        end
        if matching then return {kind='single',uid=matching,opf_hash=Crypto.sha256_hex(opf)} end
        return {kind='unknown'}
    end)
    return ok and result or {kind='unknown'}
end

function M.inspect(book,path,cache,verify_source)
    -- The offline picker explicitly verifies the source of a sole mapping.
    if not verify_source and not M.shared(book,path,cache) then return {kind='unshared'} end
    if cache and cache[path] then return cache[path] end
    local result=inspect(book,path)
    if cache then cache[path]=result end
    return result
end

-- Explicit full-book paths need the same EPUB proof even without mappings.
function M.combined(book,path,cache)
    local result=cache and cache[path] or inspect(book,path)
    if result.kind~='combined' then return nil end
    if cache then cache[path]=result end
    return result
end

-- File percentages describe a whole book only when its spine and the current
-- catalog contain exactly the same chapters in the same order.
function M.complete(info,catalog)
    if type(info)~='table' or info.kind~='combined' or type(info.items)~='table' or type(info.order)~='table'
        or type(catalog)~='table' or #catalog==0 or #catalog>20000 or #catalog~=#info.order then return false end
    local keys=0
    for key in pairs(catalog) do
        if type(key)~='number' or key%1~=0 or key<1 or key>#catalog then return false end
        keys=keys+1
    end
    if keys~=#catalog then return false end
    local seen,count={},0
    for index,row in ipairs(catalog) do
        if type(row)~='table' then return false end
        local ok,uid=pcall(Context.identifier,row.chapterUid or row.chapterId,true)
        if not ok or seen[uid] or info.order[index]~='chapter_'..uid or not info.items['chapter_'..uid] then return false end
        seen[uid]=true;count=count+1
    end
    local items=0
    for key in pairs(info.items) do if key~='cover' then items=items+1 end end
    return count==items
end

-- Compare the on-disk proof with the archive currently pinned by ReaderUI.
function M.document_matches(info,document,book_id)
    if type(info)~='table' or info.kind~='combined' or type(info.file_id)~='string' or #info.file_id~=64
        or type(info.opf_hash)~='string'
        or type(document)~='table' then return false end
    local ok,opf=pcall(function()
        local identity=Identity.read_document(document,book_id)
        local opf=document:getDocumentFileContent('OEBPS/content.opf')
        if identity.book_id==tostring(book_id) and identity.file_id==info.file_id
            and type(opf)=='string' and Crypto.sha256_hex(opf)==info.opf_hash then return opf end
    end)
    if not ok or not opf then return false end
    return true,opf
end

function M.document_complete(info,document,book_id,catalog)
    return M.complete(info,catalog) and M.document_matches(info,document,book_id)
end

function M.usable(book,path,uid,cache,verify_source)
    local info=M.inspect(book,path,cache,verify_source)
    if info.kind=='unshared' then return true end
    local ok,id=pcall(Context.identifier,uid,true)
    if not ok then return false end
    return info.kind=='single' and info.uid==id or info.kind=='combined' and info.items['chapter_'..id]==true
end

local function navigation_titles(path,info)
    if not info.opf_hash then return {} end
    local members=require('weread.lib.source_archive').read(path,{
        ['OEBPS/content.opf']=Catalog.MAX_PACKAGE_BYTES,['OEBPS/nav.xhtml']=4*1024*1024,
    })
    local opf=members and members['OEBPS/content.opf']
    local nav=members and members['OEBPS/nav.xhtml']
    if type(opf)~='string' or Crypto.sha256_hex(opf)~=info.opf_hash or type(nav)~='string' then return {} end
    local toc=nav:match('<nav[^>]*epub:type="toc"[^>]*>(.-)</nav>')
    local manifest=opf:match('<manifest>(.-)</manifest>')
    if not toc or not manifest then return {} end
    local labels={}
    for href,text in toc:gmatch('<a href="(text/chapter[%d%-]*%.xhtml)">([^<]*)</a>') do
        if labels[href]~=nil then labels[href]=false
        else labels[href]=Protocol.xml_display_text(text) or false end
    end
    local titles,seen,hrefs={},{},{}
    for item,href in manifest:gmatch('<item id="([^"]+)" href="(text/chapter[%d%-]*%.xhtml)"') do
        local uid=info.kind=='single' and item=='chapter' and info.uid
            or info.kind=='combined' and info.items[item] and item:match('^chapter_(.+)$')
        if uid then
            if seen[uid] or hrefs[href] then return {} end
            seen[uid],hrefs[href]=true,true
            if labels[href] and labels[href]~='' then titles[uid]=labels[href] end
        end
    end
    return titles
end

-- Index the mappings once, so the saved-chapter worker never scans all of
-- a book's chapter mappings for each separate EPUB.
function M.saved_titles(book,full_path,missing,current)
    local by_path={}
    for uid,path in pairs(cached_chapters(book)) do
        if type(path)=='string' then
            local mapped=by_path[path] or {}
            mapped[uid]=path
            by_path[path]=mapped
        end
    end
    local id=Context.book_id(book)
    local checked={}
    local function title_for(path,uid)
        if not path then return nil end
        if not checked[path] then
            local proof=inspect({book_id=id,cached_chapters=by_path[path]},path)
            checked[path]=navigation_titles(path,proof)
        end
        return checked[path][uid]
    end
    local titles={}
    local access=require('weread.lib.read_access')
    for _,uid in ipairs(missing) do
        if not current() then return nil end
        local path=access.cached_chapter(book.cached_chapters,uid)
        titles[uid]=title_for(path,uid) or title_for(full_path,uid)
    end
    return current() and titles or nil
end

return M
