-- Deferred quick-menu actions must not use an old book, account or catalog.
package.path='./?.lua;'..package.path
local callbacks,options
local searches=0
package.preload['weread.ui.end_of_book_dialog']=function() return {show=function(opts,value) options,callbacks=opts,value end} end
package.preload['weread.ui.book_search']=function() return {open=function() searches=searches+1 end} end
package.preload['ui/event']=function() return {new=function(_,name) return {name=name} end} end
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
local building_menu,lookups=false,0
local opened,listing,details,sync,notice
local network=true
local host={ui={document=doc},_reader_session_gen=7,settings={}}
function host.settings:get(key,default)
    assert(key~='books','reading navigation hydrated the whole library')
    if key=='auth_epoch' then return epoch end
    return default
end
function host.settings:get_book(id,legacy_numeric)
    assert(id=='123' and legacy_numeric,'reading navigation did not use the indexed book lookup')
    lookups=lookups+1
    return building_menu and original or fresh
end
function host.settings:get_auth_scope() return {account=account} end
function host.settings:auth_scope_matches(scope) return scope.account==account end
function host:ensureChaptersLoaded(book,read_only)
    assert(read_only==true,'opening the menu must not rewrite the catalog')
    return book.chapters
end
function host:getChapterInfoFromFile(book,file)
    for index,row in ipairs(book.chapters) do
        if book.cached_chapters[tostring(row.chapterUid)]==file then return index,row,false end
    end
end
function host:isNetworkLinkAvailable() return network end
function host:openChapter(book,chapter,_,opts) opened={book=book,chapter=chapter,options=opts} end
function host:showChapterList(book) listing=book end
local saved_picker
function host:showSavedChapters(id, detail, reader)
    assert(id=='123' and detail==nil and reader.is_current())
    saved_picker=reader
end
function host:showCurrentBookDetails() details=true end
function host:onWeReadSyncProgress() sync=true end
function host:showTransientInfo(value) notice=value end
for key,value in pairs(Navigation) do if host[key]==nil then host[key]=value end end
local function menu(at_end,open_downloads)
    building_menu=true
    assert(host:showEndOfBookDialog('123',at_end,open_downloads))
    building_menu=false
    return callbacks
end
local c=menu();c.on_next()
assert(opened and opened.book==fresh and opened.chapter==catalog[3] and not opened.options,
    'online next used a stale book, wrong chapter or restricted download')
c.on_previous()
assert(options.show_previous_chapter and options.enable_previous_chapter and opened.chapter==catalog[1],
    'quick menu did not open the previous standalone chapter')
network=false
c=menu();c.on_next()
assert(opened.options.cached_only and opened.options.on_cache_miss())
assert(saved_picker and saved_picker.load_book()==fresh and saved_picker.unavailable_chapter=='3'
    and saved_picker.subtitle=='Chapter unavailable offline','offline cache miss did not offer the saved picker')
network=true
do
    fresh.chapters=catalog
    local content=require('weread.lib.content')
    local load_catalog=content.load_catalog_cache
    content.load_catalog_cache=function() error('legacy inline chapters do not need an external catalog') end
    opened=nil
    local actions=menu();actions.on_next()
    assert(opened and opened.book==fresh and opened.chapter==catalog[3],'next lost a legacy inline chapter')
    content.load_catalog_cache=load_catalog
    fresh.chapters=nil
end
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
do
    original.chapters=nil
    local actions=menu()
    assert(options.chapter_list_downloaded and options.enable_chapter_list and not options.enable_next_chapter,
        'saved chapters needed the full catalog')
    actions.on_chapter_list()
    assert(saved_picker and saved_picker.load_book()==fresh and not listing,'quick menu did not use the saved picker')
    fresh.bookVersion=2
    assert(not saved_picker.load_book(),'saved picker accepted a changed book version')
    fresh.bookVersion=1
    epoch=2
    assert(not saved_picker.is_current() and not saved_picker.load_book(),'saved picker accepted a changed session')
    epoch=1
    saved_picker=nil
    menu(true,{})
    assert(saved_picker and saved_picker.load_book()==fresh,'automatic end-of-file fallback did not open the saved picker')
    original.cached_chapters={}
    saved_picker=nil
    menu(true,{})
    assert(not saved_picker and not options.enable_chapter_list,'no catalog or saved chapters enabled the picker')
    original.cached_chapters={['2']=doc.file}
    original.chapters=catalog
end
do
    local previous_info=host.getChapterInfoFromFile
    local page,target,events=5,8,{}
    function host.ui:getCurrentPage() return page end
    function host.ui:handleEvent(event) events[#events+1]=event.name end
    function doc:getPageCount() return 10 end
    function doc:getVisiblePageNumberCount() return 2 end
    host.ui.view={view_mode='page'}
    host.ui.rolling={}
    host.ui.toc={
        getPreviousChapter=function(_,current) if current>3 then return 3 end end,
        getNextChapter=function(_,current)
            assert(current==page+1,'next chapter query ignored the visible spread')
            if target>current then return target end
        end,
    }
    function host:getChapterInfoFromFile() return nil,nil,true,false end
    local actions=menu()
    assert(options.enable_previous_chapter and options.enable_next_chapter)
    actions.on_previous();actions.on_next()
    assert(events[1]=='GotoPrevChapter' and events[2]=='GotoNextChapter' and #events==2,
        'complete EPUB bypassed native chapter navigation')
    actions=menu();page=7;actions.on_previous();actions.on_next()
    assert(#events==2,'a stale quick action jumped after leaving its page')
    page=5;actions=menu();target=9;actions.on_next()
    assert(#events==2,'a changed native chapter target was used')
    actions=menu();host._weread_suspended=true;actions.on_previous();host._weread_suspended=false
    assert(#events==2,'a suspended reader accepted the deferred chapter action')
    host.progress_sync={generation=1,navigation_generation=0}
    actions=menu();host.progress_sync.generation=2;actions.on_previous()
    assert(#events==2,'a quick action survived a suspend and resume on the same page')
    host.progress_sync=nil
    page=1;menu();assert(not options.enable_previous_chapter)
    page=10;menu();assert(not options.enable_next_chapter)
    function host:getChapterInfoFromFile() return nil,nil,true,true end
    page=5;menu();assert(not options.enable_next_chapter and not options.enable_previous_chapter,
        'partial book reused unrelated chapter targets from the native table of contents')
    host.getChapterInfoFromFile=previous_info
    host.ui.getCurrentPage,host.ui.handleEvent,host.ui.view,host.ui.rolling,host.ui.toc=nil,nil,nil,nil,nil
    doc.getPageCount,doc.getVisiblePageNumberCount=nil,nil
end
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
local earlier_lookups=lookups
host.ui.document=doc;assert(host:showEndOfBookDialog(nil));assert(not options.close_to_home);callbacks.on_close_book()
assert(lookups==earlier_lookups,'ordinary local document looked up a WeRead book')
assert(browser_opens==1 and reader_closes==3,'ordinary book did not keep KOReader close behavior')
print('reader_quick_navigation_spec: fresh chapters and deferred session guards passed')
