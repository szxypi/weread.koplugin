package.path='./?.lua;'..package.path
local displayed,tasks,workers=nil,{},{}
local UI={}
function UI:show(widget) displayed=widget end
function UI:close(widget) if widget and widget.onCloseWidget then widget:onCloseWidget() end end
function UI:scheduleIn(_,task) tasks[#tasks+1]=task end
function UI:unschedule(task) for i=#tasks,1,-1 do if tasks[i]==task then table.remove(tasks,i) end end end
package.preload['ui/uimanager']=function() return UI end
package.preload['ui/widget/inputdialog']=function() return {new=function(_,value)
    function value:onShowKeyboard() end
    function value:getInputText() return self.input end
    return value
end} end
package.preload['ffi/util']=function() return {template=function(value,...)
    local args={...};return (value:gsub('%%(%d+)',function(i) return tostring(args[tonumber(i)]) end))
end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(value) return value end} end
package.preload['weread.ui.shelf_popup']=function() return {redraw=function(_,fn) fn() end,close=function() end} end
local page=1
package.preload['weread.lib.source_context']=function() return {location=function() return {page=page} end,
    same_location=function(a,b) return a and b and a.page==b.page end} end
package.preload['weread.lib.source_dom']=function() return {normalize=function(value) return value and value:gsub('%s','') end} end
package.preload['weread.lib.unicode_search']=function() return {available=function() return false end} end
local one={book_id='42',chapter_uid='1',book_version=1,source_sha256='a',title='First',key='a'}
local copy={book_id='42',chapter_uid='1',book_version=1,source_sha256='a',title='First',key='b'}
local two={book_id='42',chapter_uid='2',book_version=1,source_sha256='b',title='Second',key='c'}
local old={book_id='42',chapter_uid='3',book_version=0,source_sha256='c',title='Old',key='d'}
local rows={one,copy,two,old}
package.preload['weread.lib.native_direct_cache']=function() return {MAX_ENTRIES=2000,
    valid_entry=function(e,id,account) return type(e)=='table' and e.book_id==id and account=='123' end,
    list=function(_,_,_,current) assert(current());return rows end} end
local scans={}
package.preload['weread.lib.native_direct_search']=function() return {MAX_HITS=30,MAX_EXAMINED=100,
    scan=function(_,_,entry,_,from,_,current)
        assert(current());scans[#scans+1]=entry.key
        if entry==one then return {error='damaged'} end
        return {complete=true,unresolved=0,hits={{chapter_uid=entry.chapter_uid,byte=from,file_id=string.rep('a',64),
            context='match '..entry.key,anchor={co=1}}}}
    end} end
local navigated
package.preload['weread.ui.native_direct_search_open']=function() return {start=function(_,entry,hit,keyword,ignore)
    navigated={entry=entry,hit=hit,keyword=keyword,ignore=ignore};return true
end} end
package.preload['weread.lib.memory_worker']=function() return {new=function()
    local worker={};workers[#workers+1]=worker
    function worker:start(task,callback) self.task,self.callback=task,callback;return true end
    function worker:cancel() self.cancelled=true end
    function worker:complete() local task,callback=self.task,self.callback;self.task=nil;callback(task()) end
    return worker
end} end
local Search=require('weread.ui.native_direct_search')
local scope={vid='123'};local account='owner'
local host={ui={document={file='/chapter'},view={view_mode='page'}},_reader_session_gen=1,client={},
    settings={get_auth_scope=function() return scope end,auth_scope_matches=function(_,value) return value==scope end},
    library_db={accountKey=function() return account end}}
function host:cancelBookSearch() Search.cancel(self) end
function host:showBusy(_,cancel) self.busy_message={cancel=cancel} end
function host:closeBusy() self.busy_message=nil end
function host:showInfo(text) self.message=text end
function host:showList(_,items)
    local menu={item_table=items}
    function menu.switchItemTable(widget,_,new) widget.item_table=new end
    return menu
end
local function start()
    assert(Search.open(host,one));local input=assert(displayed);input.input='needle';input.buttons[1][2].callback()
    return assert(host._native_direct_search)
end
local function finish(worker)
    while worker.task or #tasks>0 do
        if worker.task then worker:complete() else local task=table.remove(tasks,1);task() end
    end
end
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
expect(Search.open(host,one,'prefilled') and displayed.input=='prefilled','downloaded fallback lost search text')
Search.cancel(host)
expect(not Search.open(host,one,'bad\nquery'),'downloaded fallback accepted a control character')
local owner=start();local worker=workers[#workers];finish(worker)
expect(owner.finished and owner.checked==2 and owner.unavailable==0 and #owner.value==2,'search missed available chapters')
expect(table.concat(scans,',')=='a,b,c','failed copy or old version was searched incorrectly')
local result
for _,item in ipairs(owner.menu.item_table) do if item.text=='Second · match c' then result=item end end
expect(result~=nil,'second chapter result missing');result.callback()
expect(navigated and navigated.entry==two and navigated.keyword=='needle' and navigated.ignore==false
    and not host._native_direct_search,'result did not start guarded navigation')
owner=start();worker=workers[#workers];local callback,task=worker.callback,worker.task;account='other';callback(task())
expect(not host._native_direct_search and not owner.menu,'old account produced results');account='owner'
start();page=2;Search.on_view_changed(host)
expect(not host._native_direct_search and worker~=workers[#workers] and workers[#workers].cancelled,'page change did not stop search')
page=1;tasks={};print(('native_direct_search_ui_spec: %d checks'):format(checks))
