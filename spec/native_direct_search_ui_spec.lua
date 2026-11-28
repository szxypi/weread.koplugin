package.path='./?.lua;'..package.path
local displayed,tasks,workers=nil,{},{}
local now=0
local UI={}
function UI:show(widget) displayed=widget end
function UI:close(widget) if widget and widget.onCloseWidget then widget:onCloseWidget() end end
function UI:scheduleIn(delay,task)
    tasks[#tasks+1]={at=now+delay,run=task}
    table.sort(tasks,function(a,b) return a.at<b.at end)
end
function UI:unschedule(task) for i=#tasks,1,-1 do if tasks[i].run==task then table.remove(tasks,i) end end end
local function next_task()
    local task=assert(table.remove(tasks,1));now=task.at;task.run()
end
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
local navigated,open_cancels
package.preload['weread.ui.native_direct_search_open']=function() return {
    start=function(_,entry,hit,keyword,ignore,callbacks)
        navigated={entry=entry,hit=hit,keyword=keyword,ignore=ignore,callbacks=callbacks};return true
    end,
    cancel=function() open_cancels=(open_cancels or 0)+1 end,
} end
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
    local menu={item_table=items,redraws=0}
    function menu.switchItemTable(widget,_,new) widget.item_table=new;widget.redraws=widget.redraws+1 end
    return menu
end
local function start()
    assert(Search.open(host,one));local input=assert(displayed);input.input='needle';input.buttons[1][2].callback()
    return assert(host._native_direct_search)
end
local function finish(worker)
    while worker.task or #tasks>0 do
        if worker.task then worker:complete() else next_task() end
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
expect(owner.menu.redraws==2 and #tasks==0,'fast chapter results redrew before completion')
local result
for _,item in ipairs(owner.menu.item_table) do if item.text=='Second · match c' then result=item end end
expect(result~=nil,'second chapter result missing');result.callback()
expect(navigated and navigated.entry==two and navigated.keyword=='needle' and navigated.ignore==false
    and host._native_direct_search==owner and navigated.callbacks.is_current(),'locating closed the result list')
local attempt=navigated
result.callback()
expect(navigated==attempt,'a second tap started another navigation')
attempt.callbacks.on_finish()
expect(host._native_direct_search==owner and owner.menu.item_table[4]==result and not owner.navigation,
    'failed navigation redrew or discarded the result list')
result.callback()
navigated.callbacks.on_commit()
navigated.callbacks.on_finish()
expect(not host._native_direct_search and not open_cancels,'successful navigation did not release the result list')
owner=start();finish(workers[#workers])
owner.menu.item_table[4].callback()
UI:close(owner.menu)
expect(open_cancels==1 and not host._native_direct_search and not navigated.callbacks.is_current(),
    'closing results left their pending navigation active')
owner=start();worker=workers[#workers]
worker:complete();next_task();worker:complete();next_task();worker:complete();next_task()
expect(owner.menu.redraws==1 and owner.checked==1 and #owner.value==1,'partial result redrew immediately')
next_task()
expect(owner.menu.redraws==2 and owner.menu.item_table[1].text:find('1 of 2',1,true)
    and owner.menu.item_table[3].text=='First · match b','progress redraw missed the latest partial results')
worker:complete()
host.busy_message.cancel()
expect(not owner.finished and not owner.job and owner.menu.redraws==3 and #tasks==0
    and owner.menu.item_table[1].text=='Continue searching downloaded chapters'
    and owner.menu.item_table[5].text=='Second · match c','cancel did not show completed results immediately')
owner.menu.item_table[1].callback();finish(worker)
expect(owner.finished and owner.menu.redraws==4 and #tasks==0,'resumed search kept an older progress redraw')
local previous_limit=Search.MAX_RESULTS;Search.MAX_RESULTS=1
owner=start();finish(workers[#workers]);Search.MAX_RESULTS=previous_limit
expect(owner.limit and not owner.job and owner.menu.redraws==2 and #tasks==0
    and owner.menu.item_table[5].text=='First · match b','result limit did not flush immediately')
Search.cancel(host)
owner=start();worker=workers[#workers];local callback,task=worker.callback,worker.task;account='other';callback(task())
expect(not host._native_direct_search and not owner.menu,'old account produced results');account='owner'
owner=start();local menu=owner.menu;workers[#workers]:complete();page=2;Search.on_view_changed(host)
expect(not host._native_direct_search and worker~=workers[#workers] and workers[#workers].cancelled
    and menu.redraws==1 and #tasks==0,'page change did not stop the search and its deferred redraw')
page=1;tasks={};print(('native_direct_search_ui_spec: %d checks'):format(checks))
