-- Prepare one local card without fetching or changing account data.
local Query=require('weread.lib.search_query')
local Protocol=require('weread.lib.protocol')
local Identity=require('weread.lib.shelf_snapshot')
local _=require('weread.lib.plugin_util').tr
local M={}
local function safe(value,limit)
    if type(value)~='string' or #value>limit or value:find('[%z\1-\8\11\12\14-\31\127]')
        or Protocol.utf8_substr(value,#value+1)~=value then return '' end
    return Query.trim(value)
end
local function author(value)
    if type(value)=='string' then return safe(value,1024) end
    if type(value)~='table' or #value>20 then return '' end
    local names={}
    for _,v in ipairs(value) do
        local name=safe(v,256)
        if name~='' then names[#names+1]=name end
    end
    return safe(table.concat(names,' · '),1024)
end
function M.make(host,id,text,props)
    local quote=safe(text,4096)
    local book_id=Identity.persisted_identity(id)
    if quote=='' or not book_id then return nil end
    local candidates={}
    if host.settings and type(host.settings.get_book)=='function' then
        local ok,book=pcall(host.settings.get_book,host.settings,id)
        if ok and Identity.persisted_id(book)==book_id then candidates[#candidates+1]=book end
    end
    if host.library_db and type(host.library_db.getBook)=='function' then
        local ok,book=pcall(host.library_db.getBook,host.library_db,id)
        if ok and Identity.persisted_id(book)==book_id then candidates[#candidates+1]=book end
    end
    if type(props)=='table' then candidates[#candidates+1]=props end
    local title,authors='',''
    for _,book in ipairs(candidates) do
        if title=='' then title=safe(book.title,1024) end
        if authors=='' then authors=author(book.author or book.authors) end
    end
    return {text=quote,book_title=title~='' and title or _('Untitled book'),book_author=authors}
end
return M
