package.path='./?.lua;'..package.path
local displayed
local UI={}
function UI:show(widget) displayed=widget end
function UI:close(widget) if widget and widget.onCloseWidget then widget:onCloseWidget() end end
package.preload['ui/uimanager']=function() return UI end
package.preload['ui/widget/inputdialog']=function() return {new=function(_self,options)
    function options:onShowKeyboard() end
    function options:getInputText() return self.input end
    return options
end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(value) return value end} end
package.preload['weread.ui.shelf_popup']=function() return {redraw=function(_owner,callback) callback() end,close=function() end} end
local access={web={cookies={}},revision='a'};local access_current=true
package.preload['weread.lib.read_access']=function() return {capture=function() return access end,
    display_book_id=function(id) return type(id)=='string' and (id:match('^[1-9]%d*$') or id:match('^CB_[A-Za-z0-9]+$')) and id or nil end,
    matches=function() return access_current end} end
local navigation_calls=0
package.preload['weread.ui.my_mark_navigation']=function() return {
    start=function(target_host,owner,row,current) assert(current(target_host,owner));navigation_calls=navigation_calls+1;owner.navigation={row=row} end,
    cancel=function(_host,owner) owner.navigation=nil end,
} end
package.preload['weread.ui.book_reading']=function() return {catalog=function(rows) return rows end} end
package.preload['weread.lib.book_search_target']=function() return {row=function(book,hit)
    if hit.source_verified~=false then return nil end
    return {bookId=book,chapterUid=tonumber(hit.chapter_uid),markText=hit.text,type=1,range='1-3'}
end} end
local fetch_mode='ok';local fetches=0
package.preload['weread.lib.book_search']=function() return {
    new=function(book,keyword,chapters) return {book=book,keyword=keyword,pages=0,finished=false,chapters=chapters} end,
    fetch=function(_client,state)
        fetches=fetches+1
        if fetch_mode=='fail' then return nil,'unavailable' end
        if fetch_mode=='expired' then return nil,'web_http_401' end
        if fetch_mode=='business_expired' then return nil,'web_expired' end
        if fetch_mode=='limited' then return nil,'rate_limited' end
        if fetch_mode=='empty' then state.pages=state.pages+1;state.finished=true;return {hits={},finished=true} end
        state.pages=state.pages+1;state.finished=state.pages==2
        return {hits={{chapter_uid='1',text='term',context=string.rep('long prefix ',20)..'term context',source_verified=false}},finished=state.finished}
    end,
} end
local pending_renewal,renewals,cancellations=nil,0,0
local synchronous_renewal=false
package.preload['weread.ui.web_renewal']=function() return {
    run=function(_host,options,callback)
        renewals=renewals+1;pending_renewal={guard=options.is_current,callback=callback}
        if synchronous_renewal then fetch_mode='ok';callback(true) end
        return true,pending_renewal
    end,
    cancel=function(_host,request) if request then cancellations=cancellations+1 end end,
    error_text=function(reason) return 'renewal error: '..tostring(reason) end,
} end
local active_worker
package.preload['weread.lib.memory_worker']=function() return {new=function()
    local worker={}
    function worker:start(task,callback) self.task,self.callback=task,callback;active_worker=self;return true end
    function worker:cancel() self.cancelled=true end
    function worker:complete() local value=self.task();self.callback(value) end
    return worker
end} end

local Search=require('weread.ui.book_search')
local checks=0
local function expect(value,label) checks=checks+1;if not value then error(label) end end
local account='123';local online=true;local scope_valid=true
local host={ui={document={file='/synthetic.epub'}},_reader_session_gen=1,
    settings={get_auth_scope=function() return {vid='123',epoch=1} end,
        auth_scope_matches=function() return scope_valid end},
    library_db={accountKey=function() return account end},client={}}
function host:isNetworkOnline() return online end
function host:showOffline() self.info='offline' end
function host:showInfo(value) self.info=value end
function host:showBusy(_value,cancel) self.busy_message={cancel=cancel} end
function host:closeBusy() self.busy_message=nil end
function host:showList(_title,items)
    local menu={items=items}
    function menu.switchItemTable(widget,_new_title,next_items) widget.items=next_items end
    return menu
end
local chapters={{chapterUid='1',title='Chapter'}}
local function open_and_submit()
    assert(Search.open(host,'100',chapters));local input=assert(displayed)
    input.input='term';input.buttons[1][2].callback()
    return assert(host._book_search_owner)
end

online=false;expect(not Search.open(host,'100',chapters) and host.info=='offline','offline search opened')
online=true
scope_valid=false;expect(not Search.open(host,'100',chapters)
    and host.info=='A verified WeRead web login is required for online book search.','missing login had no explanation')
scope_valid=true
local owner=open_and_submit()
expect(owner.state.pages==0 and owner.job~=nil,'first page did not start asynchronously')
active_worker:complete()
expect(owner.state.pages==1 and #owner.value==1 and #owner.menu.items==2,
    'first page did not populate native results and next-page action')
expect(owner.menu.items[2].text:find('term',1,true)~=nil,'a long excerpt hid the search term')
owner.menu.items[1].callback();expect(owner.state.pages==1 and owner.job~=nil,'pagination changed state before its worker returned')
active_worker:complete()
expect(owner.state.pages==2 and owner.state.finished and #owner.value==2 and #owner.menu.items==2,
    'second page did not append results and remove the next-page action')
owner.menu.items[1].callback()
expect(navigation_calls==1 and owner.navigation.row.bookId=='100','search result did not start verified navigation')
Search.cancel(host)
expect(not host._book_search_owner and not owner.navigation,'closing search did not cancel navigation')

owner=open_and_submit();local old=active_worker;host.ui.document={file='/other.epub'};old:complete()
expect(not host._book_search_owner and #owner.value==0,'late response opened after switching documents')
host.ui.document={file='/synthetic.epub'}
owner=open_and_submit();active_worker:complete();fetch_mode='fail';owner.menu.items[1].callback();active_worker:complete()
expect(owner.state.pages==1 and #owner.value==1 and host.info=='Could not search this book. Check the network and try again.',
    'failed later page replaced already displayed results')
fetch_mode='ok';Search.cancel(host)
owner=open_and_submit();access_current=false;active_worker:complete();access_current=true
expect(owner.state.pages==0 and #owner.value==0 and not host._book_search_owner
    and host.info=='WeRead login changed. Search again.','changed authorization committed a stale response')
Search.cancel(host)
owner=open_and_submit();scope_valid=false;active_worker:complete();scope_valid=true
expect(not host._book_search_owner and #owner.value==0,'account change kept search work alive')

fetch_mode='expired';owner=open_and_submit();active_worker:complete()
local renewal=pending_renewal
expect(owner.recovery and renewal and renewal.guard() and owner.state.pages==0,'401 did not start scoped renewal')
local before=fetches;owner.menu.items[1].callback()
expect(fetches==before and not owner.job,'pagination ran while renewal was pending')
fetch_mode='ok';renewal.callback(true)
expect(not owner.recovery and owner.job and owner.state.pages==0,'successful renewal did not retry the same page')
active_worker:complete()
expect(owner.state.pages==1 and #owner.value==1,'renewed first page did not display once')
fetch_mode='expired';owner.menu.items[1].callback();active_worker:complete();renewal=pending_renewal
expect(owner.recovery and owner.state.pages==1 and #owner.value==1,'renewal discarded previous pages')
local nav_before=navigation_calls;owner.menu.items[2].callback()
expect(navigation_calls==nav_before and not owner.navigation,'result navigation ran during renewal')
fetch_mode='ok';renewal.callback(true);active_worker:complete()
expect(owner.state.pages==2 and #owner.value==2,'renewed later page repeated or lost results')
Search.cancel(host)
fetch_mode='expired';synchronous_renewal=true;owner=open_and_submit();active_worker:complete();synchronous_renewal=false
expect(owner.job and not owner.recovery,'synchronous renewal lost the replacement page worker')
active_worker:complete();expect(owner.state.pages==1 and #owner.value==1,'synchronous renewal failed to display results')
Search.cancel(host)

fetch_mode='expired';local before_renewals=renewals;owner=open_and_submit();active_worker:complete()
renewal=pending_renewal;renewal.callback(true);active_worker:complete()
expect(renewals==before_renewals+1 and not owner.recovery and owner.state.pages==0
    and host.info=='The search login is unavailable. Check your login and try again. Existing results are kept.',
    'repeated 401 caused another automatic renewal or hid the login problem')
owner.menu.items[1].callback();active_worker:complete()
expect(renewals==before_renewals+1 and not owner.recovery and owner.state.pages==0,
    'manual retry renewed the same failed page again')
Search.cancel(host)

owner=open_and_submit();active_worker:complete();renewal=pending_renewal;local cancelled_before=cancellations
host.busy_message.cancel()
expect(not owner.recovery and cancellations==cancelled_before+1,'cancel did not stop pending renewal')
before=fetches;renewal.callback(true)
expect(fetches==before and not owner.job,'cancelled renewal restarted the search')
Search.cancel(host)

owner=open_and_submit();active_worker:complete();renewal=pending_renewal
host.ui.document={file='/other.epub'}
expect(not renewal.guard(),'renewal did not detect a switched document')
renewal.callback(false,'session_changed')
expect(not host._book_search_owner and not owner.job,'late renewal survived a document change')
host.ui.document={file='/synthetic.epub'}

owner=open_and_submit();active_worker:complete();renewal=pending_renewal;account='456'
expect(not renewal.guard(),'renewal did not detect an account change')
renewal.callback(false,'session_changed')
expect(not host._book_search_owner and not owner.job,'late renewal survived an account change')
account='123'

owner=open_and_submit();active_worker:complete();renewal=pending_renewal;cancelled_before=cancellations
Search.cancel(host)
expect(not owner.recovery and cancellations==cancelled_before+1 and not renewal.guard(),
    'closing search did not cancel and invalidate renewal')
before=fetches;renewal.callback(true)
expect(fetches==before and not host._book_search_owner,'closed search resumed after a late renewal')

fetch_mode='business_expired';before_renewals=renewals;owner=open_and_submit();active_worker:complete()
expect(renewals==before_renewals and not owner.recovery and owner.state.pages==0,
    'unverified business error triggered automatic renewal')
Search.cancel(host)
fetch_mode='limited';owner=open_and_submit();active_worker:complete()
expect(renewals==before_renewals and not owner.recovery
    and host.info=='Search requests are temporarily limited. Wait and try again. Existing results are kept.',
    'rate limiting triggered renewal or lacked an actionable message')
Search.cancel(host)
owner=open_and_submit();before_renewals=renewals
active_worker.callback({reason='web_http_401',page={},state={book='100',keyword='term',pages=0}})
expect(renewals==before_renewals and not owner.recovery and owner.state.pages==0,
    'malformed error packet triggered automatic renewal')
Search.cancel(host)
fetch_mode='ok';owner=open_and_submit();active_worker:complete();fetch_mode='expired';owner.menu.items[1].callback();active_worker:complete()
renewal=pending_renewal;renewal.callback(false,'renewal_unconfirmed')
expect(not owner.recovery and owner.state.pages==1 and #owner.value==1
    and host.info=='renewal error: renewal_unconfirmed','failed renewal discarded previous results')
Search.cancel(host);fetch_mode='ok'
expect(Search.open(host,'CB_Synthetic',chapters),'imported book did not open online search')
local cb_input=assert(displayed);cb_input.input='term';cb_input.buttons[1][2].callback()
local cb_owner=assert(host._book_search_owner);active_worker:complete()
expect(cb_owner.menu.items[#cb_owner.menu.items].text=='Search results may be incomplete for this book.',
    'imported book results did not disclose indexing limitations')
Search.cancel(host)
fetch_mode='empty';expect(Search.open(host,'CB_Synthetic',chapters),'imported book search did not reopen')
cb_input=assert(displayed);cb_input.input='term';cb_input.buttons[1][2].callback();cb_owner=assert(host._book_search_owner)
active_worker:complete()
expect(cb_owner.menu.items[1].text=='No matches returned. Search may be incomplete for this book.',
    'empty imported search claimed a complete negative result')
Search.cancel(host)
expect(not Search.open(host,'CB_bad/path',chapters),'invalid imported book ID was accepted')
print(('book_search_ui_spec: %d checks'):format(checks))
