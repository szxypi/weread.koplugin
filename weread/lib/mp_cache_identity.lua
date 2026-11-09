-- Article identity is independent of titles. Inspired by MiuRead mp.lua's
-- per-account/per-article directories (c1893562aa25a870b8dd076d7be062a3348f823e).
local Crypto=require('weread.lib.crypto')
local M={MAX_CATALOG=5000}
local function identifier(value)
    if type(value)=='number' and value>=0 and value<=9007199254740991 and value%1==0 then value=value==0 and '0' or string.format('%.0f',value) end
    if type(value)~='string' or value=='' or #value>512 or value:find('[%z%c%s]') then return nil end
    return value
end
function M.key(book,article)
    if type(book)~='table' or type(article)~='table' then return nil end
    local owner=identifier(book.book_id or book.bookId)
    if not owner or book.bookId~=nil and identifier(book.bookId)~=owner then return nil end
    local source=owner
    if article.bookId~=nil and article.bookId~='' then source=identifier(article.bookId) end
    if not source then return nil end
    local kind,id='review',article.reviewId
    if id==nil or id=='' then kind,id='original',article.originalId end
    id=identifier(id);if not id then return nil end
    return Crypto.sha256_hex('mp-cache-v1\0'..#owner..':'..owner..'\0'..#source..':'..source..'\0'..kind..'\0'..#id..':'..id)
end
function M.path(root,key)
    if type(root)~='string' or root=='' or #root>3500 or root:find('[%z%c]')
        or type(key)~='string' or #key~=64 or not key:match('^[a-f0-9]+$') then return nil end
    return root:gsub('/+$','')..'/mp-articles/'..key..'/article.html'
end
function M.marker(key) return '<meta name="weread-mp-cache-key" content="'..key..'"/>' end
function M.valid(root,key)
    local path=M.path(root,key);if not path then return false end
    local lfs=require('libs/libkoreader-lfs')
    local parent=path:match('^(.*)/[^/]+$')
    if lfs.symlinkattributes(root..'/mp-articles','mode')~='directory'
        or lfs.symlinkattributes(parent,'mode')~='directory' or lfs.symlinkattributes(path,'mode')~='file' then return false end
    local file=io.open(path,'rb');if not file then return false end
    local head=file:read(4096) or '';file:close()
    return head:find(M.marker(key),1,true)~=nil
end
-- Legacy filenames carry no article ID. Only an unambiguous saved catalog
-- association allows read-only compatibility; never promote the old file.
function M.legacy_allowed(book,article,catalog,filename)
    local wanted=M.key(book,article)
    if not wanted or type(catalog)~='table' or #catalog>M.MAX_CATALOG then return false,'legacy_unverified' end
    local target=filename(article);local keys,count={},0
    for _i,other in ipairs(catalog) do
        if type(other)=='table' and filename(other)==target then
            local key=M.key(book,other)
            if not key then return false,'ambiguous_legacy' end
            if not keys[key] then keys[key]=true;count=count+1 end
        end
    end
    if count>1 then return false,'ambiguous_legacy' end
    return count==1 and keys[wanted]==true,'legacy_unverified'
end
function M.prepare(root,key)
    local path=M.path(root,key);if not path then return nil end
    local lfs=require('libs/libkoreader-lfs');local util=require('util')
    if not util.makePath(root) and lfs.attributes(root,'mode')~='directory' then return nil end
    for _i,dir in ipairs({root..'/mp-articles',path:match('^(.*)/[^/]+$')}) do
        local mode=lfs.symlinkattributes(dir,'mode')
        if mode and mode~='directory' then return nil end
        if not mode and not util.makePath(dir) then return nil end
        if lfs.symlinkattributes(dir,'mode')~='directory' then return nil end
    end
    return path
end
function M.write(root,key,html)
    local path=M.prepare(root,key);if not path then return false end
    local lfs=require('libs/libkoreader-lfs')
    local mode=lfs.symlinkattributes(path,'mode');if mode and mode~='file' then return false end
    local created,output=pcall(require('weread.lib.notes_export_file').create,path:match('^(.*)/[^/]+$'),'cache','html')
    if not created or not output then return false end
    local ok,result=pcall(function()
        if not output:write(html) or not output:sync() or not output:accept(#html) then return false end
        return os.rename(output.path,path)==true
    end)
    if not ok or not result then output:abort();return false end
    return true,path
end
return M
