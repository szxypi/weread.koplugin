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
        state.pages=state.pages+1;state.finished=state.pages==2
        return {hits={{chapter_uid='1',text='term',context=string.rep('long prefix ',20)..'term context',source_verified=false}},finished=state.finished}
    end,
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
print(('book_search_ui_spec: %d checks'):format(checks))
