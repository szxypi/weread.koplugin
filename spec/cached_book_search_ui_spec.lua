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
package.preload['weread.ui.shelf_popup']=function() return {redraw=function(_menu,callback) callback() end,close=function() end} end
package.preload['weread.ui.book_reading']=function() return {catalog=function(rows) return rows end} end
package.preload['weread.lib.source_dom']=function() return {normalize=function(value)
    return type(value)=='string' and value:gsub('%s','') or nil
end} end
local scans=0
package.preload['weread.lib.cached_book_search']=function() return {MAX_HITS=30,MAX_EXAMINED=100,
    scan=function(input)
        scans=scans+1
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
        get_book=function() return book end},library_db={accountKey=function() return account end}}
function host:cancelBookSearch() Cached.cancel(self) end
function host:showBusy(_message,cancel) self.busy_message={cancel=cancel} end
function host:closeBusy() self.busy_message=nil end
function host:showInfo(value) self.info=value end
function host:isNetworkOnline() error('local search attempted a network check') end
function host:showList(_title,items)
    local menu={items=items};function menu.switchItemTable(widget,_label,next_items) widget.items=next_items end
    return menu
end
local chapters={{chapterUid='1',title='First'},{chapterUid='2',title='Second'},{chapterUid='3',title='Not downloaded'}}
local function open(rows)
    assert(Cached.open(host,'CB_Synthetic',rows));local input=assert(displayed)
    input.input='needle';input.buttons[1][2].callback();return assert(host._cached_book_search_owner)
end
local owner=open(chapters)
expect(owner.job and owner.total==3 and owner.missing==1,'offline search did not begin with partial coverage')
worker:complete();expect(#owner.value==1 and owner.checked==1 and scheduled,'first downloaded chapter did not advance')
local task=scheduled;scheduled=nil;task();worker:complete();task=scheduled;scheduled=nil;task()
expect(owner.finished and #owner.value==2 and owner.checked==2 and owner.missing==1,'second chapter or coverage was lost')
owner.menu.items[2].callback()
expect(navigations==1 and owner.navigation.row.chapterUid==2,'cached result did not start guarded navigation')
Cached.cancel(host)

owner=open(chapters);local old=worker;host.busy_message.cancel()
expect(not owner.job and old.cancelled and not owner.finished,'stopping scan did not retain resumable state')
local before=scans;old:complete();expect(scans==before+1 and #owner.value==0,'cancelled result was committed')
owner.menu.items[1].callback();expect(owner.job~=nil,'stopped scan could not resume')
account='other';worker:complete();account='account'
expect(not host._cached_book_search_owner,'changed account retained a late scan')

scope=nil;account=nil;owner=open(nil)
expect(owner.catalog_missing and owner.total==2 and owner.job,'signed-out offline mapped search was unavailable')
worker:complete();task=scheduled;scheduled=nil;task();worker:complete();task=scheduled;scheduled=nil;task()
expect(owner.finished and owner.menu.items[#owner.menu.items].text=='Chapter list unavailable; only mapped downloads were searched.',
    'missing catalog coverage was not disclosed')
owner.menu.items[1].callback()
expect(navigations==1 and host.info=='Chapter list unavailable. Refresh it online before opening a downloaded search result.',
    'a result without a catalog was allowed to navigate or did not explain the limitation')
Cached.cancel(host)
print(('cached_book_search_ui_spec: %d checks'):format(checks))
