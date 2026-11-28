package.path='./?.lua;'..package.path
package.preload['ui/uimanager']=function() return {} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(s) return s end} end
package.preload['weread.lib.shelf_source']=function() return {web_access=function() return true end} end
local state
local chapters={{chapterUid='1',title='One',wordCount=20,tar='https://example.invalid/source'},
    {chapterUid='2',title='Two',wordCount=30,extra='retained'}}
package.preload['weread.lib.content']=function() return {
    ensure_reader_state=function() if state.reader_error then error(state.reader_error,0) end end,
    fetch_catalog=function() if state.catalog_error then error(state.catalog_error,0) end;return state.catalog end,
} end
package.loaded['weread.lib.book_reading_client']={wrap=function(client) return client end}
local renewal,request,renewals={},nil,0
function renewal.run(_,options,callback) renewals=renewals+1;request={guard=options.is_current,callback=callback};return true,request end
function renewal.cancel(_,value) if request==value then request=nil end end
function renewal.error_text() return 'renewal failed' end
package.loaded['weread.ui.web_renewal']=renewal
package.loaded['weread.lib.web_authorization']={capture=function() return {
    revision=string.rep(state.cookies.wr_skey=='renewed-synthetic' and 'a' or 'b',64),
    scope={vid='900000',epoch=state.epoch}} end}
local Catalog=require('weread.ui.catalog_request')
local function fixture(view)
    request,renewals=nil,0
    state={epoch=1,valid=true,catalog=chapters,errors=0,callbacks=0,cancels=0,starts=0}
    state.cookies={wr_vid='900000',wr_skey='synthetic-only'}
    local host={client={},settings={get=function(_,key,default) if key=='cookies' then return state.cookies end;return default end,
        get_auth_scope=function() return {vid='900000',epoch=state.epoch} end,
        auth_scope_matches=function(_,scope) return state.epoch==scope.epoch end,
        flush=function() end},_chapter_list_view=view,
        isNetworkOnline=function() return true end,
        showInfo=function(_,text) state.errors=state.errors+1;state.message=text end,
        showBusy=function(self,_,cancel) self.busy_message={};state.cancel=cancel end,
        closeBusy=function(self) self.busy_message=nil end,
        _catalog_request_worker={start=function(_,task,done) state.starts=state.starts+1;state.worker={task=task,done=done};return true end,
            cancel=function() state.cancels=state.cancels+1 end}}
    local book={book_id='900001',title='Book',chapters={{chapterUid='9',title='Old'}}}
    local old=book.chapters
    local function done(result) state.callbacks=state.callbacks+1;state.result=result end
    assert(Catalog.start(host,book,done,{current=function() return state.valid end,chapter_view=view}))
    return host,book,old
end
local function run() local work=state.worker;work.done(work.task()) end
local function renewed()
    local current=assert(request);request=nil;state.cookies.wr_skey='renewed-synthetic'
    current.callback(true,{revision=string.rep('a',64)})
end
local host,book,old=fixture();run()
assert(state.callbacks==1 and state.result[1].tar==chapters[1].tar and state.result[2].extra=='retained'
    and book.chapters==old and not host.busy_message,'catalog data or existing book was altered before callback')
for _,stage in ipairs({'reader_error','catalog_error'}) do
    host,book,old=fixture();state[stage]='book_reading/web_expired';run()
    assert(renewals==1 and request and request.guard() and state.callbacks==0,'401 did not request one renewal')
    state[stage]=nil;renewed();run()
    assert(state.starts==2 and state.callbacks==1 and not host._catalog_request and book.chapters==old,
        'renewed catalog did not finish safely')
end
host=fixture();state.reader_error='book_reading/web_expired';run();renewed();run()
assert(renewals==1 and state.callbacks==0 and state.errors==1 and not host._catalog_request,
    'second 401 renewed again or delivered a stale catalog')
for _,reason in ipairs({'download_read/rate_limited','sensitive_http_unavailable'}) do
    book,old=select(2,fixture());state.reader_error=reason;run()
    assert(renewals==0 and state.callbacks==0 and state.errors==1 and book.chapters==old,
        'non-401 failure renewed or changed the existing catalog')
end
local view={}
host=fixture(view);Catalog.cancel(host,{})
assert(host._catalog_request,'closing an unrelated chapter view cancelled the request')
Catalog.cancel(host,view)
assert(not host._catalog_request,'closing the owning chapter view did not cancel the request')
for _,change in ipairs({'cancel','page','account','view','closed','cookie','book'}) do
    view._catalog_closed=nil
    host,book=fixture(view);state.reader_error='book_reading/web_expired';run()
    local pending=assert(request)
    if change=='cancel' then state.cancel()
    elseif change=='page' then state.valid=false
    elseif change=='account' then state.epoch=2
    elseif change=='view' then host._chapter_list_view={}
    elseif change=='closed' then view._catalog_closed=true
    elseif change=='cookie' then state.cookies.wr_skey='foreign-synthetic'
    else book.book_id='900002' end
    pending.callback(true,{revision=string.rep('a',64)})
    assert(not host._catalog_request and state.callbacks==0,'stale request delivered a catalog: '..change)
end
host=fixture();local late=state.worker;Catalog.cancel(host);late.done(late.task())
assert(state.callbacks==0 and not host._catalog_request,'cancelled worker delivered a result')
host=fixture();Catalog.cancel(host)
assert(Catalog.start(host,{book_id='900001'},function() error('private callback data') end,{current=function() return true end}))
run()
assert(state.errors==1 and not host._catalog_request and not state.message:find('private',1,true),
    'callback failure escaped or exposed details')
for _,invalid in ipairs({{{chapterUid='1'},{chapterUid='1'}},{{chapterUid='../1'}},{{chapterUid='1',tar=string.rep('x',8193)}}}) do
    book,old=select(2,fixture());state.catalog=invalid;run()
    assert(state.errors==1 and state.callbacks==0 and book.chapters==old,'invalid catalog replaced the cached chapters')
end
fixture();state.catalog={};run()
assert(state.callbacks==1 and #state.result==0,'empty catalog was rejected')
print('catalog_request_spec: background catalog and scoped renewal passed')
