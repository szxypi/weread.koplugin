package.path='./?.lua;'..package.path
local state
package.preload['weread.lib.content']=function() return {
    book_resolved_dir=function(settings,id,book) return book.cache_dir or settings.cache_dir..'/'..id end,
    mp_article_legacy_path=function(_settings,book,article) return book.cache_dir..'/'..article.title..'.html' end} end
package.preload['weread.lib.protocol']=function() return {is_mp_book=function(id) return id:sub(1,7)=='MP_WXS_' end} end
package.preload['weread.lib.mp_record_recovery']=function() return {capture=function(_settings,book,article,path)
    if state.invalid then error('unavailable') end
    state.captured={book=book,article=article,path=path};return {path=path}
end} end
local Resolve=require('weread.lib.mp_file_identity')
local Identity=require('weread.lib.mp_cache_identity')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local function fixture()
    local first={book_id='MP_WXS_1',cache_dir='/cache/one',mp_articles={{reviewId='one',title='旧文章'}}}
    local second={book_id='MP_WXS_2',cache_dir='/cache/two',mp_articles={{reviewId='two',title='别的文章'}}}
    state={indexes={MP_WXS_1={cache_dir=first.cache_dir},MP_WXS_2={cache_dir=second.cache_dir},normal={cache_dir='/cache/local'}},
        books={MP_WXS_1=first,MP_WXS_2=second},loaded={}}
    local settings={cache_dir='/all',get_book_indexes=function() return state.indexes end,
        get=function() error('indexed resolver hydrated every book') end,
        get_book=function(_self,id) state.loaded[#state.loaded+1]=id;return state.books[id] end}
    return settings,first,first.mp_articles[1]
end
local settings=fixture();local book,article
for _i,path in ipairs({'/local/file.epub','/cache/local/book.epub','/cache/one-other/旧文章.html','/cache/one/a.txt'}) do
    expect(Resolve.resolve(settings,path)==nil and #state.loaded==0 and not state.captured,'unrelated file hydrated an article collection')
end
for _i,ext in ipairs({'html','epub'}) do
    settings,book,article=fixture();local path=book.cache_dir..'/'..article.title..'.'..ext
    local selected=Resolve.resolve(settings,path)
    expect(selected.book==book and selected.article==article and selected.input.path==path,'legacy article association lost')
    expect(#state.loaded==1 and state.loaded[1]=='MP_WXS_1','unrelated book metadata was loaded')
end
settings,book,article=fixture();local key=Identity.key(book,article)
for _i,name in ipairs({'article.html','article-0123456789abcdef.html','article-0123456789abcdef.epub'}) do
    state.captured=nil
    local path=book.cache_dir..'/mp-articles/'..key..'/'..name
    expect(Resolve.resolve(settings,path).article==article and state.captured.path==path,'managed identity not mapped through its saved catalog')
end
settings,book,article=fixture();book.mp_articles[2]={reviewId='one',title=article.title}
expect(Resolve.resolve(settings,'/cache/one/旧文章.html').article.reviewId=='one','duplicate same-identity catalog row became ambiguous')
for _i,change in ipairs({'same_title','overlap','invalid_id','missing_book','foreign_book','moved_book','bad_index','sparse','catalog_limit','invalid_source'}) do
    settings,book,article=fixture()
    if change=='same_title' then book.mp_articles[2]={reviewId='other',title=article.title}
    elseif change=='overlap' then state.indexes.MP_WXS_2.cache_dir=book.cache_dir;state.books.MP_WXS_2.cache_dir=book.cache_dir;state.books.MP_WXS_2.mp_articles[1].title=article.title
    elseif change=='invalid_id' then article.reviewId=nil
    elseif change=='missing_book' then state.books.MP_WXS_1=nil
    elseif change=='foreign_book' then book.book_id='MP_WXS_foreign'
    elseif change=='moved_book' then book.cache_dir='/moved'
    elseif change=='bad_index' then state.indexes=false
    elseif change=='sparse' then book.mp_articles.bad={}
    elseif change=='catalog_limit' then for index=2,Identity.MAX_CATALOG+1 do book.mp_articles[index]=article end
    else state.invalid=true end
    expect(not pcall(Resolve.resolve,settings,'/cache/one/旧文章.html'),'invalid authority accepted: '..change)
end
settings,book=fixture();book.mp_articles=nil
expect(not pcall(Resolve.resolve,settings,'/cache/one/mp-articles/'..key..'/article.html'),'unknown managed owner was opened')
settings,book=fixture();state.indexes.MP_WXS_1.cache_dir='/cache/one/..';book.cache_dir='/cache/one/..'
expect(not pcall(Resolve.resolve,settings,'/cache/one/../旧文章.html'),'noncanonical cache path accepted')
settings=fixture();local maximum=Resolve.MAX_BOOKS;Resolve.MAX_BOOKS=1
expect(not pcall(Resolve.resolve,settings,'/cache/one/旧文章.html'),'index capacity ignored');Resolve.MAX_BOOKS=maximum
settings,book=fixture();settings.get_book_indexes=nil;settings.get=function() return state.books end
expect(Resolve.resolve(settings,'/cache/one/旧文章.html').book==book,'non-index settings adapter lost compatibility')
print('PASS: exact file-manager article lookup and lazy book hydration ('..checks..' checks)')
