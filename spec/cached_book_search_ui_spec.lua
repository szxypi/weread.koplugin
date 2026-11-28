package.path='./?.lua;'..package.path
local displayed,scheduled
local now=0
local UI={}
function UI:show(widget) displayed=widget end
function UI:close(widget) if widget and widget.onCloseWidget then widget:onCloseWidget() end end
function UI:scheduleIn(_delay,task) scheduled=task end
function UI:unschedule(task) if scheduled==task then scheduled=nil end end
package.preload['ui/uimanager']=function() return UI end
package.preload['ui/time']=function() return {now=function() return now end,ms=function(value) return value end} end
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
local encoded_catalog='synthetic encoded catalog'
package.preload['weread.lib.content']=function() return {book_epub_path=function() return output_path end,
    ensure_reader_state=function() end,fetch_catalog=function() return catalog_rows end,
    encode_catalog_cache=function() return encoded_catalog end,
    save_catalog_cache=function(_client,_settings,_book,_chapters,encoded)
        assert(encoded==encoded_catalog);catalog_writes=catalog_writes+1;return catalog_save_ok
    end} end
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
local capture_id=string.rep('a',64)
package.preload['weread.lib.cached_book_search']=function() return {MAX_HITS=30,MAX_EXAMINED=100,MAX_ARCHIVE_BATCH=1,
    valid_capture_id=function(value) return value==capture_id end,
    unicode_casefold_available=function() return unicode_available end,
    discover=function() return {error='unavailable'} end,
    scan=function(input)
        scans=scans+1
        last_case=input.ignore_ascii_case
        return {complete=true,unresolved=0,hits={{chapter_uid=input.chapter,context='synthetic result',offset=1}}}
    end} end
package.preload['weread.lib.cached_search_target']=function() return {row=function(book,keyword,hit)
    if not hit.offset then return nil end
    local chapter=tonumber(hit.chapter_uid)
    if chapter>2147483647 then chapter=hit.chapter_uid end
    return {bookId=book,chapterUid=chapter,markText=keyword,type=1,range='1'}
end} end
local navigations=0
package.preload['weread.ui.my_mark_navigation']=function() return {
    start=function(host,owner,row,guard) assert(guard(host,owner));navigations=navigations+1;owner.navigation={row=row} end,
    cancel=function(_host,owner) owner.navigation=nil end,
} end
local worker,starts=nil,0
package.preload['weread.lib.memory_worker']=function() return {new=function()
    local instance={}
    function instance:start(task,callback) self.task,self.callback=task,callback;worker=self;starts=starts+1;return true end
    function instance:cancel() self.cancelled=true end
    function instance:complete() self.callback(self.task()) end
    return instance
end} end
local Cached=require('weread.ui.cached_book_search')
local scan_batch_limit=Cached.MAX_SCANS_PER_WORKER
Cached.MAX_SCANS_PER_WORKER=1
local checks=0
local function expect(value,label) checks=checks+1;if not value then error(label) end end
local account,scope,epoch='account',{vid='123',epoch=1},1
local book={book_id='CB_Synthetic',cached_chapters={['1']='/one.epub',['2']='/two.epub'}}
local host={ui={document={file='/one.epub'}},_reader_session_gen=1,client={},
    settings={get_auth_scope=function() return scope end,auth_scope_matches=function(_self,value) return value==scope end,
        get=function(_self,key,default) if key=='auth_epoch' then return epoch end;return default end,
        get_book=function() return book end},library_db={accountKey=function() return account end,
            putChapters=function(_self,_id,_chapters,encoded) assert(encoded==encoded_catalog);return true end}}
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

host.getFullBookCachePath=function() return '/full.epub' end
expect(Cached.open(host,'CB_Synthetic',{chapters[1]}),'single-chapter search did not open')
expect(table.concat(host._cached_book_search_owner.queue[1].paths,',')=='/one.epub,/full.epub',
    'mapped chapter and full book were reordered or duplicated')
Cached.cancel(host)
host.ui.document.file='/full.epub'
expect(Cached.open(host,'CB_Synthetic',{chapters[1]}),'full book search did not open')
expect(table.concat(host._cached_book_search_owner.queue[1].paths,',')=='/full.epub,/one.epub',
    'the open full book was not preferred')
Cached.cancel(host)
host.getFullBookCachePath=nil;host.ui.document.file='/one.epub'

-- The queue must retain the exact string rather than rounding a large UID.
book.cached_chapters['9007199254740993']='/large.epub'
local large_chapters={{chapterUid='9007199254740993',title='Large identifier'}}
owner=open(large_chapters);worker:complete();task=scheduled;scheduled=nil;task()
expect(owner.finished and #owner.value==1 and owner.value[1].chapter_uid=='9007199254740993',
    'large chapter was skipped or rounded in the search queue')
hit_item(owner,1).callback()
expect(owner.navigation and owner.navigation.row.chapterUid=='9007199254740993',
    'large chapter identity was lost before navigation')
Cached.cancel(host);book.cached_chapters['9007199254740993']=nil

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

-- A worker may return more hits than fit in the current batch. Every hit
-- must remain reachable without rescanning, including the final short batch.
local search_module=require('weread.lib.cached_book_search')
local original_scan=search_module.scan
local batch_scans=0
search_module.scan=function(input)
    batch_scans=batch_scans+1
    local hits={}
    for index=1,5 do hits[index]={chapter_uid=input.chapter,context='hit '..index,offset=index} end
    return {complete=true,unresolved=0,hits=hits}
end
Cached.MAX_RESULTS=2
owner=open({chapters[1]});worker:complete()
expect(owner.limit and #owner.value==2 and #owner.overflow==3 and batch_scans==1,
    'search dropped hits at the batch boundary')
local old_next=assert(find_item(owner.menu,'Search next batch (keeps only the previous batch)'))
local old_hit=assert(find_item(owner.menu,'First · hit 1'))
old_next.callback()
expect(owner.limit and #owner.value==2 and owner.value[1].context=='hit 3' and #owner.overflow==1 and batch_scans==1,
    'next batch skipped or rescanned worker results')
old_next.callback();old_hit.callback()
expect(owner.page==2 and not owner.navigation,'stale batch action changed the current search')
assert(find_item(owner.menu,'Show previous result batch')).callback()
expect(owner.show_previous and find_item(owner.menu,'First · hit 1') and find_item(owner.menu,'First · hit 2'),
    'previous batch could not be viewed')
assert(find_item(owner.menu,'Show current result batch')).callback()
expect(not owner.show_previous and find_item(owner.menu,'First · hit 3') and batch_scans==1,
    'returning to current batch changed the search')
assert(find_item(owner.menu,'Search next batch (keeps only the previous batch)')).callback()
expect(owner.finished and not owner.limit and #owner.value==1 and owner.value[1].context=='hit 5' and batch_scans==1,
    'final partial batch lost a result')
assert(find_item(owner.menu,'Show previous result batch')).callback()
expect(find_item(owner.menu,'First · hit 3') and not find_item(owner.menu,'First · hit 1'),
    'only the immediately preceding batch should be retained')
Cached.cancel(host);Cached.MAX_RESULTS=1000;search_module.scan=original_scan

Cached.MAX_RESULTS=2
search_module.scan=function(input) return {complete=true,hits={
    {chapter_uid=input.chapter,context='exact 1',offset=1},
    {chapter_uid=input.chapter,context='exact 2',offset=2}}} end
owner=open({chapters[1]});worker:complete()
expect(owner.finished and not owner.limit and not find_item(owner.menu,'Search next batch (keeps only the previous batch)'),
    'exact final batch falsely offered more results')
Cached.cancel(host)
local tail_hits={{chapter_uid='2',context='later',offset=3}}
search_module.scan=function(input)
    if input.chapter=='1' then return {complete=true,hits={
        {chapter_uid='1',context='first',offset=1},{chapter_uid='1',context='second',offset=2}}} end
    return {complete=true,hits=tail_hits}
end
owner=open({chapters[1],chapters[2]});worker:complete()
local kept_batch=owner.value
assert(find_item(owner.menu,'Search next batch (keeps only the previous batch)')).callback()
local stopped_worker=worker;host.busy_message.cancel();stopped_worker:complete()
expect(not owner.job and owner.next_batch and owner.value==kept_batch and not owner.previous and owner.page==1,
    'cancelled next batch discarded the visible results')
assert(find_item(owner.menu,'Continue searching downloaded chapters')).callback();worker:complete()
task=scheduled;scheduled=nil;task()
expect(owner.finished and #owner.value==1 and owner.value[1].context=='later' and owner.previous==kept_batch and owner.page==2,
    'cancelled next batch did not resume from the saved cursor')
Cached.cancel(host);tail_hits={}
owner=open({chapters[1],chapters[2]});worker:complete();kept_batch=owner.value
assert(find_item(owner.menu,'Search next batch (keeps only the previous batch)')).callback();worker:complete()
task=scheduled;scheduled=nil;task()
expect(owner.finished and not owner.limit and not owner.next_batch and owner.value==kept_batch and owner.page==1
    and not owner.previous and find_item(owner.menu,'First · second'),'empty next batch replaced the last matches')
Cached.cancel(host);Cached.MAX_RESULTS=1000;search_module.scan=original_scan
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
expect(owner.discovery_pending,'new full download did not try the bounded archive index')
worker:complete();task=scheduled;scheduled=nil;task()
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
expect(navigations==3 and owner.navigation.row.chapterUid==1,
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
    local hash=string.rep('a',64)
    return {entries={{uid='2',index=1,raw_sha256=hash,render_path='OEBPS/text/chapter-001.xhtml'},
        {uid='3',index=2,raw_sha256=hash,render_path='OEBPS/text/chapter-002.xhtml'}},incomplete=false}
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
local backend=require('weread.lib.cached_book_search')
backend.MAX_ARCHIVE_BATCH=2
local indexed_batches=0
backend.batch_reader=function(file,requests)
    assert(file=='/full.epub' and #requests==2 and requests[1].chapter=='3' and requests[2].chapter=='2')
    indexed_batches=indexed_batches+1
    return function() end
end
book.cached_chapters={['1']='/one.epub'}
owner=open({chapters[1],chapters[3],chapters[2]});worker:complete()
expect(owner.queue[1].uid=='1' and not owner.queue[1].archive and owner.queue[2].uid=='3' and owner.queue[2].archive
    and owner.queue[3].uid=='2' and owner.titles['2']=='Second','archive index replaced known catalog order, titles or fallback')
task=scheduled;scheduled=nil;task();worker:complete()
task=scheduled;scheduled=nil;task();worker:complete()
task=scheduled;scheduled=nil;task()
expect(owner.finished and owner.checked==3 and #owner.value==3 and owner.value[3].chapter_uid=='2' and indexed_batches==1,
    'known catalog did not share grouped reads across its indexed chapters')
Cached.cancel(host)
book.cached_chapters={}
local rejected_batches=0
backend.batch_reader=function()
    rejected_batches=rejected_batches+1
    return nil
end
owner=open(nil);worker:complete()
task=scheduled;scheduled=nil;task();worker:complete()
expect(rejected_batches==1 and owner.checked==0,'failed archive batch advanced the search')
for _i=1,2 do task=scheduled;scheduled=nil;task();worker:complete() end
task=scheduled;scheduled=nil;task()
expect(owner.finished and owner.checked==2 and #owner.value==2,'fallback after archive batch failure lost chapters')
Cached.cancel(host);backend.MAX_ARCHIVE_BATCH=1
require('weread.lib.cached_book_search').discover=function()
    return {entries={{uid='2',index=1,raw_sha256=string.rep('b',64),
        render_path='OEBPS/text/chapter-001.xhtml'}},incomplete=true}
end
owner=open(nil);worker:complete();task=scheduled;scheduled=nil;task();worker:complete();task=scheduled;scheduled=nil;task()
expect(owner.finished and owner.discovery_incomplete and find_item(owner.menu,
    'Some chapters in the downloaded book could not be indexed.'),'partial full-book index was presented as complete')
Cached.cancel(host)

-- Exercise the same batch worker as the reader, with a controlled clock and
-- enough downloaded chapters to cross more than one worker boundary.
Cached.MAX_SCANS_PER_WORKER=scan_batch_limit
book.cached_chapters={}
host.ui.document.file='/one.epub';host.getFullBookCachePath=nil
local many={}
for index=1,9 do
    local uid=tostring(index)
    many[index]={chapterUid=uid,title='Chapter '..uid}
    book.cached_chapters[uid]='/chapter-'..uid..'.epub'
end
local function next_task()
    local callback=assert(scheduled);scheduled=nil;callback()
end
local initial_starts,initial_scans=starts,scans
owner=open(many,true)
worker:complete()
expect(owner.index==5 and owner.checked==4 and #owner.value==4 and last_case==true,'worker did not scan four ordered chapters')
next_task();worker:complete();next_task();worker:complete();next_task()
expect(owner.finished and owner.checked==9 and #owner.value==9 and scans-initial_scans==9 and starts-initial_starts==3,
    'full search did not use three workers for nine chapters')
for index,hit in ipairs(owner.value) do assert(hit.chapter_uid==tostring(index)) end
Cached.cancel(host)

local visited={}
search_module.scan=function(request)
    visited[#visited+1]=request.chapter..':'..request.from
    if request.chapter=='1' then
        if request.from==1 then return {hits={},next_byte=32,unresolved=2,capture_id=capture_id} end
        assert(request.capture_id==capture_id)
        local result=original_scan(request);result.capture_id=capture_id;return result
    end
    assert(not request.capture_id,'chapter inherited the previous chapter capture')
    if request.chapter=='2' then return {hits={},missing=true} end
    if request.chapter=='3' then return {error='unavailable'} end
    return original_scan(request)
end
owner=open(many)
worker:complete()
expect(table.concat(visited,',')=='1:1' and owner.index==1 and owner.from==32 and owner.unresolved==2,
    'worker advanced past an unfinished chapter')
next_task();worker:complete()
expect(table.concat(visited,',')=='1:1,1:32,2:1,3:1' and owner.index==3 and owner.checked==2 and owner.missing==1
    and #owner.value==1 and not owner.job and host.info=='Could not search downloaded chapters.',
    'worker error discarded the valid prefix or scanned later chapters')
Cached.cancel(host)

search_module.scan=function(request)
    if request.chapter=='1' then
        if request.from>1 then
            assert(request.capture_id==capture_id)
            return {hits={},missing=true,source_changed=true}
        end
        local result=original_scan(request)
        result.complete=nil;result.next_byte=32;result.capture_id=capture_id
        return result
    end
    assert(not request.capture_id)
    return original_scan(request)
end
owner=open({many[1],many[2]});worker:complete();next_task();worker:complete();next_task()
expect(owner.finished and owner.missing==1 and owner.source_changed and not owner.capture_id and #owner.value==2
    and owner.value[1].chapter_uid=='1' and owner.value[2].chapter_uid=='2'
    and find_item(owner.menu,'Some chapter text changed during this search. Search again to include the updated text.'),
    'changed source lost earlier hits or the next chapter')
Cached.cancel(host)

search_module.scan=function(request) now=now+360;return original_scan(request) end
owner=open(many)
worker:complete()
expect(owner.index==2 and owner.checked==1 and #owner.value==1,'worker started another chapter past the time budget')
next_task();local late_batch=worker;local late_callback=late_batch.callback;local in_flight=late_batch.task
host.busy_message.cancel();late_callback(in_flight())
expect(owner.index==2 and owner.checked==1 and #owner.value==1 and not owner.job,'cancelled worker consumed its partial result')
search_module.scan=original_scan
assert(find_item(owner.menu,'Continue searching downloaded chapters')).callback()
worker:complete()
expect(owner.index==6 and owner.value[2].chapter_uid=='2','resume did not start at the first uncommitted chapter')
Cached.cancel(host)

owner=open(many)
worker.callback(nil)
expect(owner.job and owner.index==1 and scheduled,'failed batch transport was not retried from the same chapter')
next_task();worker:complete()
expect(owner.index==2 and #owner.value==1,'failed batch transport did not fall back to a single scan')
Cached.cancel(host)

Cached.MAX_RESULTS=3;initial_scans=scans
owner=open(many);worker:complete()
expect(owner.limit and owner.index==4 and scans-initial_scans==3 and #owner.value==3,
    'worker scanned beyond the current result batch capacity')
Cached.cancel(host);Cached.MAX_RESULTS=1000

local long_catalog,indexed,widths={},{},{}
for index=1,260 do
    local uid=tostring(index)
    long_catalog[index]={chapterUid=uid,title='Chapter '..uid}
    indexed[index]={uid=uid,index=index,raw_sha256=string.rep('a',64),
        render_path=('OEBPS/text/chapter-%03d.xhtml'):format(index)}
end
host.getFullBookCachePath=function() return '/full.epub' end
backend.MAX_ARCHIVE_BATCH=258
backend.discover=function() return {entries=indexed,incomplete=false} end
backend.batch_reader=function(_file,requests)
    widths[#widths+1]=#requests
    return function() end
end
backend.scan=function(request) now=now+360;return original_scan(request) end
owner=open(long_catalog);worker:complete()
next_task();worker:complete()
expect(owner.checked==1 and widths[1]==258,'long archive batch did not respect its time budget')
backend.scan=original_scan
next_task();worker:complete()
expect(owner.checked==257 and widths[2]==256 and owner.value[2].chapter_uid=='2',
    'slow archive did not shrink the next batch or resume at the right chapter')
next_task();worker:complete();next_task()
expect(owner.finished and owner.checked==260 and owner.value[260].chapter_uid=='260','adapted batch lost the last chapter')
Cached.cancel(host)
print(('cached_book_search_ui_spec: %d checks'):format(checks))
