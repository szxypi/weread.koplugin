-- Reload chapter metadata immediately before a cross-file navigation.
local ReadAccess=require('weread.lib.read_access')
local M={}
local function id(row)
    if type(row)~='table' then return nil end
    local value=row.chapterUid or row.chapterId
    if type(value)~='string' and type(value)~='number' then return nil end
    if type(value)=='number' and (value~=value or value%1~=0 or math.abs(value)>9007199254740991) then return nil end
    value=tostring(value)
    return value~='' and value or nil
end
local function equal_field(a,b,key)
    if a[key]==nil or b[key]==nil then return a[key]==b[key] end
    return tostring(a[key])==tostring(b[key])
end

-- Match the EPUB's ordered chapters against the current catalog. Gaps from a
-- partial download are fine. A repeated UID, reordering or missing entry is
-- insufficient evidence to continue from the file's final chapter.
function M.combined_end(book,document,proof)
    local catalog=book and book.chapters
    if not proof or type(proof.order)~='table' or type(proof.items)~='table'
        or type(catalog)~='table' or #catalog==0 or #catalog>20000
        or not require('weread.lib.chapter_cache_claim').document_matches(proof,document,book.book_id or book.bookId) then
        return nil
    end
    local version=require('weread.lib.book_file_identity').version(book.bookVersion or book.book_version)
    if version>0 and (proof.book_version or 0)>0 and version~=proof.book_version then return nil end
    if document.getPageFlow and document:getPageFlow(document:getCurrentPage())~=0 then return nil end
    local seen,matched,last,count={},0,nil,0
    for index,row in ipairs(catalog) do
        local uid=id(row)
        if not uid or seen[uid] then return nil end
        seen[uid]=true;count=index
        local member='chapter_'..uid
        if proof.items[member] then
            matched=matched+1
            if proof.order[matched]~=member then return nil end
            last=index
        end
    end
    if count==#catalog and matched==#proof.order then return last end
end

function M.resolve(host,expected,direction)
    if not host or type(expected)~='table' or type(expected.book)~='table'
        or type(expected.book_id)~='string' or type(expected.index)~='number'
        or expected.index%1~=0 or expected.index<1 or (direction~=-1 and direction~=1)
        or not host.settings or type(host.settings.get_book)~='function'
        or type(host.getChapterInfoFromFile)~='function' then return nil end
    local book=ReadAccess.load_cached_book(host.settings,expected.book_id)
    if not book or book.book_id==nil and book.bookId==nil then return nil end
    for _,key in ipairs({'bookVersion','book_version','version','fileId','file_id','cache_dir'}) do
        if not equal_field(book,expected.book,key) then return nil end
    end
    local catalog=book.chapters
    if type(catalog)~='table' or #catalog==0 then
        catalog=require('weread.lib.content').load_catalog_cache(host.client,host.settings,book)
    end
    if type(catalog)~='table' or #catalog==0 then
        local db=host.library_db
        catalog=db and type(db.getChapters)=='function' and db:getChapters(expected.book_id) or nil
    end
    if type(catalog)~='table' or #catalog==0 then return nil end
    book.chapters=catalog
    local index,current,combined,partial,proof=host:getChapterInfoFromFile(book,expected.file)
    if expected.combined_file then
        if direction~=1 or not combined or not partial or not proof or proof.file_id~=expected.combined_file
            or proof.opf_hash~=expected.combined_opf then return nil end
        index=M.combined_end(book,host.ui and host.ui.document,proof)
        current=index and catalog[index]
    elseif combined then
        return nil
    end
    if index~=expected.index or id(current)~=expected.current
        or id(catalog[index-1])~=expected.previous or id(catalog[index+1])~=expected.next then return nil end
    local target=catalog[index+direction]
    local current_id,target_id=id(current),id(target)
    if not current_id or not target_id or target_id==current_id then return nil end
    if expected.combined_file then return book,target end
    local current_count,target_count=0,0
    for _,row in ipairs(catalog) do
        local uid=id(row)
        if uid==current_id then current_count=current_count+1 end
        if uid==target_id then target_count=target_count+1 end
    end
    if current_count~=1 or target_count~=1 then return nil end
    return book,target
end
return M
