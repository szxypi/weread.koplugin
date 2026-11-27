-- Deferred quick-menu actions must not use an old book, account or catalog.
package.path='./?.lua;'..package.path
local callbacks,options
local searches=0
package.preload['weread.ui.end_of_book_dialog']=function() return {show=function(opts,value) options,callbacks=opts,value end} end
package.preload['weread.ui.book_search']=function() return {open=function() searches=searches+1 end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(value) return value end} end
package.preload['weread.lib.protocol']=function() return {is_mp_book=function() return false end} end
local catalog={{chapterUid='1'},{chapterUid='2'},{chapterUid='3'}}
package.preload['weread.lib.content']=function() return {load_catalog_cache=function() return catalog end} end
local Navigation=require('weread.ui.reader_navigation')
local doc={file='/synthetic/2.epub'}
local epoch,account=1,'one'
local original={book_id='123',bookVersion=1,cache_dir='/cache/123',chapters=catalog,
    cached_chapters={['2']=doc.file}}
local fresh={book_id='123',bookVersion=1,cache_dir='/cache/123',cached_chapters={['2']=doc.file}}
local books={['123']=original}
local opened,listing,details,sync,notice
local host={ui={document=doc},_reader_session_gen=7,settings={}}
function host.settings:get(key,default)
    if key=='books' then return books elseif key=='auth_epoch' then return epoch end
    return default
end
function host.settings:get_book() return fresh end
function host.settings:get_auth_scope() return {account=account} end
function host.settings:auth_scope_matches(scope) return scope.account==account end
function host:ensureChaptersLoaded(book) return book.chapters end
function host:getChapterInfoFromFile(book,file)
    for index,row in ipairs(book.chapters) do
        if book.cached_chapters[tostring(row.chapterUid)]==file then return index,row,false end
    end
end
function host:openChapter(book,chapter) opened={book=book,chapter=chapter} end
function host:showChapterList(book) listing=book end
function host:showCurrentBookDetails() details=true end
function host:onWeReadSyncProgress() sync=true end
function host:showTransientInfo(value) notice=value end
for key,value in pairs(Navigation) do if host[key]==nil then host[key]=value end end
local function menu() assert(host:showEndOfBookDialog('123'));return callbacks end
local c=menu();c.on_next()
assert(opened and opened.book==fresh and opened.chapter==catalog[3],'next used a stale book or wrong chapter')
opened=nil;c=menu();catalog[3]={chapterUid='4'};c.on_next()
assert(not opened and notice:find('Chapter information changed',1,true),'changed catalog was used')
catalog[3]={chapterUid='3'};notice=nil
c=menu();fresh.bookVersion=2;c.on_next()
assert(not opened and notice,'changed book version was used');fresh.bookVersion=1;notice=nil
c=menu();original.bookVersion=2;fresh.bookVersion=2;c.on_next()
assert(not opened and notice,'mutating a captured book defeated the version snapshot')
original.bookVersion=1;fresh.bookVersion=1;notice=nil
c=menu();c.on_chapter_list();assert(listing==fresh,'chapter list did not use the latest book')
listing=nil;c=menu();fresh.cache_dir='/cache/other';c.on_chapter_list()
assert(not listing and notice,'chapter list accepted a different book cache');fresh.cache_dir='/cache/123'
c=menu();account='two';c.on_next();c.on_chapter_list();c.on_book_details();c.on_sync_progress();c.on_close_book()
assert(not opened and not listing and not details and not sync,'changed account accepted a deferred action')
account='one';c=menu();epoch=2;c.on_next();c.on_book_details();c.on_sync_progress();c.on_search_book()
assert(not opened and not details and not sync and searches==0,'changed authorization accepted a deferred action')
epoch=1;c=menu();host._reader_session_gen=8;c.on_next();assert(not opened,'new session accepted an old action')
host._reader_session_gen=7;c=menu();doc.file='/synthetic/other.epub';c.on_next();c.on_book_details();c.on_sync_progress()
assert(not opened and not details and not sync,'changed file accepted an old action')
doc.file='/synthetic/2.epub'
local home_opens,browser_opens,reader_closes,after_scope=0,0,0,'one'
local fm={showFiles=function(self)
    self.instance={weread={settings={auth_scope_matches=function(_,scope) return scope.account==after_scope end},
        library_db={accountKey=function() return after_scope end},showHome=function() home_opens=home_opens+1 end}}
end}
package.loaded['apps/filemanager/filemanager']=fm
host.library_db={accountKey=function() return account end}
host.ui.onClose=function(reader,refresh)
    assert((refresh==false)==options.close_to_home)
    reader_closes=reader_closes+1;reader.document=nil
end
host.ui.showFileManager=function(_,path)
    assert(path==doc.file);browser_opens=browser_opens+1
end
c=menu();assert(options.close_to_home);c.on_close_book()
assert(home_opens==1 and reader_closes==1 and browser_opens==0,'WeRead book closed to the file browser')
host.ui.document=doc;fm.instance=nil;after_scope='two';c=menu();c.on_close_book()
assert(home_opens==1 and reader_closes==2,'a different account opened the old book home')
host.ui.document=doc;assert(host:showEndOfBookDialog(nil));assert(not options.close_to_home);callbacks.on_close_book()
assert(browser_opens==1 and reader_closes==3,'ordinary book did not keep KOReader close behavior')
print('reader_quick_navigation_spec: fresh chapters and deferred session guards passed')
