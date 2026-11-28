-- Resolve only exact cached article paths from saved indexes/catalogs. File
-- manager opening must not hydrate unrelated books or infer IDs from titles.
local Content=require('weread.lib.content')
local Identity=require('weread.lib.mp_cache_identity')
local Records=require('weread.lib.mp_record_recovery')
local Protocol=require('weread.lib.protocol')
local M={MAX_BOOKS=50000,MAX_ROOTS=32}
local function fail() error('mp_file_identity/unavailable',0) end
function M.resolve(settings,path)
    if type(path)~='string' or not path:match('%.html$') and not path:match('%.epub$') then return end
    local indexed=type(settings.get_book_indexes)=='function'
    local books
    if indexed then books=settings:get_book_indexes() else books=settings:get('books',{}) end
    if type(books)~='table' then fail() end
    local candidates,count,roots={},0,0
    for id,index in pairs(books) do
        count=count+1;if count>M.MAX_BOOKS then fail() end
        if type(id)=='string' and Protocol.is_mp_book(id) and type(index)=='table' then
            local root=Content.book_resolved_dir(settings,id,index)
            if type(root)~='string' or root=='' then fail() end;root=root:gsub('/+$','')
            if path:sub(1,#root+1)==root..'/' then
                roots=roots+1;if roots>M.MAX_ROOTS then fail() end
                local book
                if indexed then book=settings:get_book(id) else book=index end
                if type(book)~='table' or tostring(book.book_id or book.bookId)~=id
                    or Content.book_resolved_dir(settings,id,book):gsub('/+$','')~=root then fail() end
                local relative=path:sub(#root+2);local managed=relative:sub(1,12)=='mp-articles/'
                local catalog=book.mp_articles
                if type(catalog)=='table' and #catalog>Identity.MAX_CATALOG then fail() end
                if type(catalog)~='table' then
                    if managed then fail() end
                else
                    local rows=0;local owner=managed and relative:match('^mp%-articles/([a-f0-9]+)/[^/]+$')
                    for ordinal,article in pairs(catalog) do
                        rows=rows+1
                        if rows>Identity.MAX_CATALOG or type(ordinal)~='number' or ordinal%1~=0
                            or ordinal<1 or ordinal>#catalog or type(article)~='table' then fail() end
                        local key,target
                        if managed then
                            key=Identity.key(book,article)
                            target=key~=nil and owner==key
                        else
                            local legacy=Content.mp_article_legacy_path(settings,book,article)
                            target=path==legacy or path==legacy:gsub('%.html$','.epub')
                            if target then key=Identity.key(book,article) end
                        end
                        if target then
                            if not key then fail() end
                            candidates[id..'\0'..key]={book=book,article=article}
                        end
                    end
                    if rows~=#catalog then fail() end
                    if managed and next(candidates)==nil then fail() end
                end
            end
        end
    end
    local selected,total=nil,0
    for _,value in pairs(candidates) do selected=value;total=total+1 end
    if total>1 then fail() end
    if selected then
        if #path>4096 or path:sub(1,1)~='/' or path:find('[%z%c]') or path:find('//',1,true)
            or path:find('/%./') or path:find('/%.%./') then fail() end
        selected.input=Records.capture(settings,selected.book,selected.article,path)
        if not selected.input then fail() end
    end
    return selected
end
return M
