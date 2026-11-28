-- An account-scoped choice of downloaded chapter, not a cloud position.
-- Native KOReader state owns the page inside that chapter.
local Access=require('weread.lib.read_access')
local Source=require('weread.lib.position_source')
local M={}
local function hash(value,length)
    return type(value)=='string' and #value==length and value:match('^[0-9a-f]+$')~=nil
end
local function epoch(value)
    return type(value)=='number' and value==value and value%1==0 and value>=0 and value<=9007199254740990
end
function M.make(point,book,account,auth_epoch)
    local uid=type(point)=='table' and Access.book_id(point.chapter_uid)
    if type(book)~='string' or Access.display_book_id(book)~=book or not uid
        or point.book_id~=book or point.upload_verified~=false
        or not Source.is_coordinate_basis(point.basis) or not hash(point.file_id,64) or not hash(point.raw_sha256,64)
        or account~=nil and not hash(account,20) or not epoch(auth_epoch) then return nil end
    return {schema=1,book_id=book,chapter_uid=uid,file_id=point.file_id,raw_sha256=point.raw_sha256,
        basis=point.basis,owner=account or '',auth_epoch=auth_epoch}
end
function M.valid(value,book,account,auth_epoch)
    if type(value)~='table' or value.schema~=1 or value.book_id~=book or value.owner~=(account or '')
        or value.auth_epoch~=auth_epoch then return false end
    local check=M.make({book_id=value.book_id,chapter_uid=value.chapter_uid,file_id=value.file_id,
        raw_sha256=value.raw_sha256,basis=value.basis,upload_verified=false},book,account,auth_epoch)
    if not check then return false end
    for key,item in pairs(value) do if check[key]~=item then return false end end
    for key,item in pairs(check) do if value[key]~=item then return false end end
    return true
end
return M
