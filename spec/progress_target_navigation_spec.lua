package.path='./?.lua;'..package.path
local existing,dialogs,queue={},{},{}
local function empty() return {} end
for _,name in ipairs({'ui/widget/inputdialog','ui/widget/progressbardialog','ui/widget/textviewer',
    'weread.ui.book_reviews_view','weread.lib.content','weread.lib.protocol'}) do package.preload[name]=empty end
package.preload['weread.lib.book_reviews']=function() return {format_date=function() return '' end} end
package.preload['weread.lib.logger']=function() return {info=function() end,warn=function() end,err=function() end} end
package.preload['ui/widget/confirmbox']=function() return {new=function(_self,value) return value end} end
package.preload['ui/uimanager']=function() return {
    show=function(_self,dialog) dialogs[#dialogs+1]=dialog end,close=function() end,
    scheduleIn=function(_self,delay,fn) assert(delay>=0.1);queue[#queue+1]=fn end,
} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(text) return text end,T=function(text) return text end,
    log_error=tostring,display_error=tostring,file_exists=function(path) return existing[path]==true end} end
local Library=require('weread.ui.library')
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label or ('check '..checks)) end
local book,chapter={book_id='book',cached_chapters={}},{chapterUid=22,title='Chapter two'}
local function fixture()
    existing,dialogs,queue={},{},{}
    local epoch,pending=0,{}
    local opens,downloads,cancels={},{},0
    local active=false
    local sync={pending_jump=pending}
    function sync:_scope() return {epoch=epoch} end
    function sync:chapter_request_current(value,scope) return self.pending_jump==value and scope.epoch==epoch end
    function sync:chapter_handoff(path) return function() return path end end
    function sync:cancel_pending_jump() self.pending_jump=nil;cancels=cancels+1 end
    local host={progress_sync=sync,downloader={start=function(_self,_book,_chapters,_suffix,options)
        downloads[#downloads+1]=options;active=true
    end},safeCallback=function(_self,_label,fn) return fn end,
        openFile=function(_self,path,handoff) assert(not active,'chapter opened before downloader cleanup');opens[#opens+1]={path=path,handoff=handoff} end}
    setmetatable(host,{__index=Library})
    local function drain() while #queue>0 do table.remove(queue,1)() end end
    return {host=host,sync=sync,opens=opens,downloads=downloads,drain=drain,
        invalidate=function() epoch=epoch+1;sync.pending_jump={} end,
        complete=function(ok,path) downloads[#downloads].on_complete(ok,path);active=false end,
        counters=function() return cancels end}
end
local cached=fixture();book.cached_chapters['22']='/cached.epub';existing['/cached.epub']=true
expect(cached.host:openProgressTargetChapter(book,chapter),'cached target rejected')
expect(#cached.opens==1 and type(cached.opens[1].handoff)=='function' and #dialogs==0,'cached target lost after-open handoff')
book.cached_chapters={}
local stale=fixture();assert(stale.host:openProgressTargetChapter(book,chapter))
local old=dialogs[#dialogs];stale.invalidate();old.ok_callback();old.cancel_callback()
expect(#stale.downloads==0 and stale.counters()==0,'stale prompt downloaded or cancelled a new target')
local current=fixture();assert(current.host:openProgressTargetChapter(book,chapter));dialogs[#dialogs].ok_callback()
expect(#current.downloads==1 and current.downloads[1].open_on_complete~=true,'downloader retained unscoped automatic open')
expect(current.downloads[1].silent_completion and current.downloads[1].offer_read==false,'download could show an unscoped read prompt')
current.complete(true,'/new.epub')
expect(#current.opens==0 and #queue==1,'download callback opened before cleanup')
current.drain()
expect(#current.opens==1 and current.opens[1].path=='/new.epub' and current.opens[1].handoff,
    'current successful download did not hand off once')
local replaced=fixture();assert(replaced.host:openProgressTargetChapter(book,chapter));dialogs[#dialogs].ok_callback()
replaced.complete(true,'/old.epub');replaced.invalidate();replaced.drain()
expect(#replaced.opens==0,'late successful download overrode a new navigation request')
local failed=fixture();assert(failed.host:openProgressTargetChapter(book,chapter));dialogs[#dialogs].ok_callback()
failed.invalidate();failed.complete(false,'failed')
expect(failed.counters()==0,'old failed download cancelled a new target')
local owned_failure=fixture();assert(owned_failure.host:openProgressTargetChapter(book,chapter));dialogs[#dialogs].ok_callback()
owned_failure.complete(false,'failed');expect(owned_failure.counters()==1,'current failure did not release its pending target')
local switch_args,file_args
local forwarded={closeWeReadUI=function() end,ui={document={},switchDocument=function(_self,...) switch_args={...} end}}
local callback=function() end
Library.openFile(forwarded,'/book.epub',callback)
expect(switch_args[1]=='/book.epub' and switch_args[3]==callback,'ReaderUI switch lost native after-open callback')
forwarded.ui={openFile=function(_self,...) file_args={...} end}
Library.openFile(forwarded,'/book.epub',callback)
expect(file_args[1]=='/book.epub' and file_args[5]==callback,'FileManager open lost native after-open callback')
print(('progress_target_navigation_spec: %d checks'):format(checks))
