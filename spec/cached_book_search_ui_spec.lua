package.path='./?.lua;'..package.path
local displayed,scheduled
local UI={}
function UI:show(widget) displayed=widget end
function UI:close(widget) if widget and widget.onCloseWidget then widget:onCloseWidget() end end
function UI:scheduleIn(_delay,task) scheduled=task end
function UI:unschedule(task) if scheduled==task then scheduled=nil end end
package.preload['ui/uimanager']=function() return UI end
package.preload['ui/widget/inputdialog']=function() return {new=function(_self,options)
    function options:onShowKeyboard() end
    function options:getInputText() return self.input end
    return options
end} end
package.preload['ffi/util']=function() return {template=function(text,...)
    local values={...};return (text:gsub('%%(%d+)',function(index) return tostring(values[tonumber(index)]) end))
end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(value) return value end} end
package.preload['weread.ui.shelf_popup']=function() return {redraw=function(_menu,callback) callback() end,
    close=function(menu) if menu then menu._shelf_popup=nil end end,
    show=function(menu,dialog) menu._shelf_popup=dialog;UI:show(dialog);return true end} end
package.preload['ui/widget/confirmbox']=function() return {new=function(_self,options) return options end} end
local output_path='/new-full.epub'
local catalog_rows,catalog_writes,catalog_save_ok=nil,0,true
package.preload['weread.lib.content']=function() return {book_epub_path=function() return output_path end,
    ensure_reader_state=function() end,fetch_catalog=function() return catalog_rows end,
    save_catalog_cache=function() catalog_writes=catalog_writes+1;return catalog_save_ok end} end
package.preload['weread.lib.worker_settings']=function() return {fingerprint=function() return 'fingerprint' end,
    capture=function() return function() return nil end end,merge=function() return true end} end
package.preload['libs/libkoreader-lfs']=function()
    local missing=function() return nil,'missing',2 end
    return {attributes=missing,symlinkattributes=missing}
end
package.preload['weread.ui.book_reading']=function() return {catalog=function(rows) return rows end} end
package.preload['weread.lib.source_dom']=function() return {normalize=function(value)
    return type(value)=='string' and value:gsub('%s','') or nil
end} end
local scans,last_case,unicode_available=0,nil,false
package.preload['weread.lib.cached_book_search']=function() return {MAX_HITS=30,MAX_EXAMINED=100,
    unicode_casefold_available=function() return unicode_available end,
    scan=function(input)
        scans=scans+1
        last_case=input.ignore_ascii_case
        return {complete=true,unresolved=0,hits={{chapter_uid=input.chapter,context='synthetic result',offset=1}}}
    end} end
package.preload['weread.lib.cached_search_target']=function() return {row=function(book,keyword,hit)
    if not hit.offset then return nil end
    return {bookId=book,chapterUid=tonumber(hit.chapter_uid),markText=keyword,type=1,range='1'}
end} end
local navigations=0
package.preload['weread.ui.my_mark_navigation']=function() return {
    start=function(host,owner,row,guard) assert(guard(host,owner));navigations=navigations+1;owner.navigation={row=row} end,
    cancel=function(_host,owner) owner.navigation=nil end,
} end
local worker
package.preload['weread.lib.memory_worker']=function() return {new=function()
    local instance={}
    function instance:start(task,callback) self.task,self.callback=task,callback;worker=self;return true end
    function instance:cancel() self.cancelled=true end
    function instance:complete() self.callback(self.task()) end
    return instance
end} end
local Cached=require('weread.ui.cached_book_search')
local checks=0
local function expect(value,label) checks=checks+1;if not value then error(label) end end
local account,scope,epoch='account',{vid='123',epoch=1},1
local book={book_id='CB_Synthetic',cached_chapters={['1']='/one.epub',['2']='/two.epub'}}
local host={ui={document={file='/one.epub'}},_reader_session_gen=1,client={},
    settings={get_auth_scope=function() return scope end,auth_scope_matches=function(_self,value) return value==scope end,
        get=function(_self,key,default) if key=='auth_epoch' then return epoch end;return default end,
        get_book=function() return book end},library_db={accountKey=function() return account end,
            putChapters=function() return true end}}
function host:cancelBookSearch() Cached.cancel(self) end
function host:requireLogin() return true end
function host:showBusy(_message,cancel) self.busy_message={cancel=cancel} end
function host:closeBusy() self.busy_message=nil end
function host:showInfo(value) self.info=value end
function host:isNetworkOnline() error('local search attempted a network check') end
function host:showList(_title,items)
    local menu={items=items};function menu.switchItemTable(widget,_label,next_items) widget.items=next_items end
    return menu
end
local chapters={{chapterUid='1',title='First'},{chapterUid='2',title='Second'},{chapterUid='3',title='Not downloaded'}}
expect(Cached.open(host,'CB_Synthetic',chapters,'original term') and displayed.input=='original term',
    'online fallback did not prefill its query')
expect(displayed.buttons[2][1].text=='Search (ignore English case)','missing Unicode fallback label')
Cached.cancel(host)
unicode_available=true
expect(Cached.open(host,'CB_Synthetic',chapters) and displayed.buttons[2][1].text=='Search (ignore case)',
    'Unicode casefold option label missing')
Cached.cancel(host);unicode_available=false
expect(not Cached.open(host,'CB_Synthetic',chapters,'bad\nquery'),'unsafe prefilled query was accepted')
local function open(rows,ignore_case)
    assert(Cached.open(host,'CB_Synthetic',rows));local input=assert(displayed)
    input.input='needle';(ignore_case and input.buttons[2][1] or input.buttons[1][2]).callback()
    return assert(host._cached_book_search_owner)
end
local function find_item(menu,text)
    for _i,row in ipairs(menu.items) do if row.text==text then return row end end
end
local function hit_item(owner,index)
    local hit=owner.value[index]
    return assert(find_item(owner.menu,owner.titles[hit.chapter_uid]..' · '..hit.context))
end
local owner=open(chapters)
expect(owner.job and owner.total==3 and owner.missing==1,'offline search did not begin with partial coverage')
worker:complete();expect(#owner.value==1 and owner.checked==1 and scheduled and last_case==false,'first downloaded chapter did not advance')
local task=scheduled;scheduled=nil;task();worker:complete();task=scheduled;scheduled=nil;task()
expect(owner.finished and #owner.value==2 and owner.checked==2 and owner.missing==1,'second chapter or coverage was lost')
expect(owner.menu.items[1].text=='Downloaded search: 2 of 3 chapters checked; 1 unavailable.'
    and owner.menu.items[2].text=='Download full book and search again','missing coverage or action was hidden after results')
hit_item(owner,2).callback()
expect(navigations==1 and owner.navigation.row.chapterUid==2,'cached result did not start guarded navigation')
Cached.cancel(host)

owner=open(chapters,true);worker:complete()
expect(last_case==true and owner.ignore_ascii_case and #owner.value==1,'case-insensitive mode was not sent to the worker')
host.busy_message.cancel();owner.menu.items[1].callback();worker:complete()
expect(last_case==true and #owner.value==2,'case-insensitive mode was lost on resume')
Cached.cancel(host)

-- A user may fill missing coverage, keeping the query and case mode. The
-- active EPUB is never replaced and old callbacks cannot restart a search.
local downloads,cancelled,options=0,0,nil
host.downloader={start=function(_self,_book,rows,suffix,values)
    downloads=downloads+1;options=values;assert(#rows==3 and suffix=='full');return true
end,cancelRequest=function(_self,complete) assert(complete==options.on_complete);cancelled=cancelled+1 end}
host.isNetworkOnline=function() return true end
local function finish_partial()
    local partial=open(chapters,true);worker:complete();local next_task=scheduled;scheduled=nil;next_task()
    worker:complete();next_task=scheduled;scheduled=nil;next_task();return partial
end
local function download_button(partial)
    for _,item in ipairs(partial.menu.items) do
        if item.text=='Download full book and search again' then return item end
    end
end
Cached.MAX_RESULTS=1
owner=open(chapters);worker:complete()
expect(owner.limit and not owner.finished and owner.menu.items[1].text==
    'Downloaded search result limit reached; results may be incomplete.'
    and download_button(owner)~=nil,'limited search hid its warning or download action')
Cached.cancel(host);Cached.MAX_RESULTS=1000
owner=finish_partial();local action=assert(download_button(owner));action.callback()
local confirm=assert(owner.download.confirm);confirm.cancel_callback()
expect(downloads==0 and not owner.download,'cancelled download changed search')
action=assert(download_button(owner));action.callback();confirm=assert(owner.download.confirm);confirm:onCloseWidget()
expect(not owner.download,'dismissed confirmation blocked the search')
action=assert(download_button(owner));action.callback();confirm=assert(owner.download.confirm)
output_path=host.ui.document.file;confirm.ok_callback();output_path='/new-full.epub'
expect(downloads==0 and not owner.download and host.info=='Cannot replace the book currently open in the reader.',
    'active EPUB was allowed as download destination')
local fs=require('libs/libkoreader-lfs');local old_attrs,old_link=fs.attributes,fs.symlinkattributes
fs.symlinkattributes=function() return {mode='file'} end
fs.attributes=function() return {dev=1,ino=2} end
action=assert(download_button(owner));action.callback();confirm=assert(owner.download.confirm);confirm.ok_callback()
expect(downloads==0 and not owner.download,'hard link to active EPUB was allowed as destination')
fs.symlinkattributes=function() return {mode='link'} end
action=assert(download_button(owner));action.callback();confirm=assert(owner.download.confirm);confirm.ok_callback()
expect(downloads==0 and not owner.download,'symbolic-link destination was allowed')
fs.attributes,fs.symlinkattributes=old_attrs,old_link
action=assert(download_button(owner));action.callback();confirm=assert(owner.download.confirm);confirm.ok_callback()
expect(downloads==1 and owner.download and options.offer_read==false,'full download did not start')
book.cached_full_book=output_path;options.on_complete(true,output_path)
task=scheduled;scheduled=nil;task()
expect(owner.job and owner.keyword=='needle' and owner.ignore_ascii_case and owner.total==3 and owner.missing==0,
    'completed download did not restart the same search over all chapters')
worker:complete();task=scheduled;scheduled=nil;task();worker:complete();task=scheduled;scheduled=nil;task()
worker:complete();task=scheduled;scheduled=nil;task()
expect(owner.finished and #owner.value==3 and last_case==true,'full-book search missed chapters or case mode')
Cached.cancel(host);book.cached_full_book=nil

owner=finish_partial();action=assert(download_button(owner));action.callback();confirm=assert(owner.download.confirm)
confirm.ok_callback();local late=options.on_complete;Cached.cancel(host);late(true,output_path)
expect(cancelled==1 and not host._cached_book_search_owner and not scheduled,'closed search kept a download callback')

owner=open(chapters);local old=worker;host.busy_message.cancel()
expect(not owner.job and old.cancelled and not owner.finished,'stopping scan did not retain resumable state')
local before=scans;old:complete();expect(scans==before+1 and #owner.value==0,'cancelled result was committed')
owner.menu.items[1].callback();expect(owner.job~=nil,'stopped scan could not resume')
account='other';worker:complete();account='account'
expect(not host._cached_book_search_owner,'changed account retained a late scan')

scope=nil;account=nil;owner=open(nil)
expect(owner.catalog_missing and owner.total==2 and owner.job,'signed-out offline mapped search was unavailable')
worker:complete();task=scheduled;scheduled=nil;task();worker:complete();task=scheduled;scheduled=nil;task()
expect(owner.finished and find_item(owner.menu,'Chapter list unavailable; only mapped downloads were searched.'),
    'missing catalog coverage was not disclosed')
hit_item(owner,1).callback()
expect(navigations==2 and owner.navigation.row.chapterUid==1,
    'a mapped downloaded result without a catalog did not start guarded local navigation')
Cached.cancel(host)
scope={vid='123',epoch=1};account='account';catalog_rows=chapters
local function no_catalog_complete()
    local missing_catalog=open(nil,true);worker:complete();local next_task=scheduled;scheduled=nil;next_task()
    worker:complete();next_task=scheduled;scheduled=nil;next_task();return missing_catalog
end
local function fetch_button(value)
    for _,item in ipairs(value.menu.items) do if item.text=='Fetch chapter list for this search' then return item end end
end
Cached.MAX_RESULTS=1
owner=open(nil,true);worker:complete()
local limited_fetch=assert(fetch_button(owner))
expect(owner.limit and not owner.finished and owner.menu.items[1].text==
    'Downloaded search result limit reached; results may be incomplete.',
    'limited search without catalog hid its warning or catalog recovery')
limited_fetch.callback();expect(owner.job~=nil,'limited search could not fetch its catalog')
host.busy_message.cancel();Cached.cancel(host);Cached.MAX_RESULTS=1000
owner=no_catalog_complete();local fetch=assert(fetch_button(owner));fetch.callback()
expect(owner.job and owner.catalog_missing,'catalog fetch did not start in background')
worker:complete()
expect(owner.job and not owner.catalog_missing and owner.total==3 and owner.missing==1
    and owner.keyword=='needle' and owner.ignore_ascii_case and catalog_writes==1,'catalog fetch did not restart the same search')
worker:complete();task=scheduled;scheduled=nil;task();worker:complete();task=scheduled;scheduled=nil;task()
expect(owner.finished and #owner.value==2 and owner.missing==1 and download_button(owner),
    'refreshed catalog lost unavailable chapters or the download option')
Cached.cancel(host)

owner=no_catalog_complete();fetch=assert(fetch_button(owner));fetch.callback();old=worker
host.busy_message.cancel();old:complete()
expect(owner.catalog_missing and catalog_writes==1 and not owner.job,'cancelled catalog fetch saved or restarted')
Cached.cancel(host)
owner=no_catalog_complete();fetch=assert(fetch_button(owner));fetch.callback();account='other';worker:complete();account='account'
expect(not host._cached_book_search_owner and catalog_writes==1,'catalog fetch survived an account change')
owner=no_catalog_complete();fetch=assert(fetch_button(owner));catalog_save_ok=false;fetch.callback();worker:complete();catalog_save_ok=true
expect(owner.catalog_missing and owner.finished and #owner.value==2 and catalog_writes==2,
    'catalog save failure replaced existing search results')
Cached.cancel(host)
local discovery_count=0
require('weread.lib.cached_book_search').discover=function()
    discovery_count=discovery_count+1
    return {entries={{uid='2',index=1},{uid='3',index=2}},incomplete=false}
end
book.cached_chapters={};host.ui.document.file='/full.epub'
host.getFullBookCachePath=function() return '/full.epub' end
owner=open(nil);old=worker
expect(owner.discovery_pending and owner.total==0,'full-book discovery did not run before scanning')
host.busy_message.cancel();old:complete()
expect(owner.discovery_pending and #owner.value==0 and discovery_count==1,'cancelled discovery committed its results')
owner.menu.items[1].callback();worker:complete()
expect(owner.discovered and owner.total==2 and owner.queue[1].uid=='2' and owner.queue[2].uid=='3',
    'full-book index did not add the downloaded chapters in order')
task=scheduled;scheduled=nil;task();worker:complete();task=scheduled;scheduled=nil;task();worker:complete()
task=scheduled;scheduled=nil;task()
expect(owner.finished and #owner.value==2 and find_item(owner.menu,
    'Chapter list unavailable; only indexed downloads were searched.'),'discovered full-book results were incomplete or undisclosed')
Cached.cancel(host)
require('weread.lib.cached_book_search').discover=function()
    return {entries={{uid='2',index=1}},incomplete=true}
end
owner=open(nil);worker:complete();task=scheduled;scheduled=nil;task();worker:complete();task=scheduled;scheduled=nil;task()
expect(owner.finished and owner.discovery_incomplete and find_item(owner.menu,
    'Some chapters in the downloaded book could not be indexed.'),'partial full-book index was presented as complete')
Cached.cancel(host)
print(('cached_book_search_ui_spec: %d checks'):format(checks))
