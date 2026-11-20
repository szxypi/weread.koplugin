-- Reload chapter metadata immediately before a cross-file navigation.
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
function M.resolve(host,expected,direction)
    if not host or type(expected)~='table' or type(expected.book)~='table'
        or type(expected.book_id)~='string' or type(expected.index)~='number'
        or expected.index%1~=0 or expected.index<1 or (direction~=-1 and direction~=1)
        or not host.settings or type(host.settings.get_book)~='function'
        or type(host.getChapterInfoFromFile)~='function' then return nil end
    local book=host.settings:get_book(expected.book_id)
    if type(book)~='table' or tostring(book.book_id or book.bookId or '')~=expected.book_id then return nil end
    for _,key in ipairs({'bookVersion','book_version','version','fileId','file_id','cache_dir'}) do
        if not equal_field(book,expected.book,key) then return nil end
    end
    local catalog=require('weread.lib.content').load_catalog_cache(host.client,host.settings,book)
    if type(catalog)~='table' or #catalog==0 then
        local db=host.library_db
        catalog=db and type(db.getChapters)=='function' and db:getChapters(expected.book_id) or nil
    end
    if type(catalog)~='table' or #catalog==0 then return nil end
    book.chapters=catalog
    local index,current,combined=host:getChapterInfoFromFile(book,expected.file)
    if combined or index~=expected.index or id(current)~=expected.current
        or id(catalog[index-1])~=expected.previous or id(catalog[index+1])~=expected.next then return nil end
    local target=catalog[index+direction]
    local current_id,target_id=id(current),id(target)
    if not current_id or not target_id or target_id==current_id then return nil end
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
