package.path='./?.lua;'..package.path
local UI={shown=nil,tasks={}}
function UI:show(widget) self.shown=widget end
function UI:close(widget) if widget and widget.onCloseWidget then widget:onCloseWidget() end end
function UI:scheduleIn(_,task) self.tasks[#self.tasks+1]=task end
function UI:unschedule(task) for i=#self.tasks,1,-1 do if self.tasks[i]==task then table.remove(self.tasks,i) end end end
package.preload['ui/uimanager']=function() return UI end
package.preload['ui/widget/confirmbox']=function() return {new=function(_,value) return value end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(value) return value end} end
local page=1;local account='owner';local valid=true;local workers={};local result,reason,allow_seen
local scope={vid='7',epoch=1};local native={scope=scope,credentials={vid='7'}};local web={web={cookies={wr_vid='7'}}}
local entry={book_id='41',chapter_uid='2',book_version=3,file_id=string.rep('a',64)}
local target={book_id='41',chapter_uid='3',book_version=3,file_id=string.rep('b',64)}
local anchor={co=9,text='long unique anchor text',point_offset=4,point_unit='unicode_scalars',basis='filtered_xhtml_utf16'}
local hit={chapter_uid='3',start=5,finish=11,text='needle',source_verified=false}
package.preload['weread.lib.native_direct_cache']=function() return {valid_entry=function(e,id,vid)
    return type(e)=='table' and e.book_id==id and vid=='7' end} end
package.preload['weread.lib.native_direct_path']=function() return {contains=function(_,p) return p=='/native/target' end} end
package.preload['weread.lib.native_direct_online_search_target']=function() return {resolve=function(_,_,_,_,_,_,_,current,allow)
    assert(current());allow_seen=allow;return result,reason
end} end
package.preload['weread.lib.native_read_access']=function() return {capture=function() return native end,
    matches=function(_,n) return valid and n==native end} end
package.preload['weread.lib.source_currentness']=function() return {capture=function() return web end,
    matches=function(_,w) return valid and w==web end} end
package.preload['weread.lib.source_context']=function() return {location=function() return {page=page} end,
    same_location=function(a,b) return a and b and a.page==b.page end} end
package.preload['weread.lib.book_file_identity']=function() return {read_document=function(doc) return doc.identity or {} end} end
package.preload['weread.lib.protocol']=function() return {utf8_substr=function(s) return s end} end
package.preload['weread.ui.my_mark_navigation']=function() return {cancel=function(host,owner)
    local job=owner.navigation;owner.navigation=nil
    if job then if job.worker then job.worker:cancel() end;if job.confirm then UI:close(job.confirm) end
        if job.busy and host.busy_message==job.busy then host:closeBusy() end end
end} end
package.preload['weread.lib.memory_worker']=function() return {new=function()
    local w={};workers[#workers+1]=w
    function w:start(task,callback) self.task,self.callback=task,callback;return true end
    function w:cancel() self.cancelled=true end
    function w:complete() local task,callback=self.task,self.callback;self.task=nil;callback(task()) end
    return w
end} end
local Nav=require('weread.ui.native_direct_online_navigation')
local function fixture()
    page=1;account='owner';valid=true;result=nil;reason=nil;allow_seen=nil;UI.tasks={};UI.shown=nil
    local doc={file='/native/source'};local host={ui={document=doc,view={view_mode='page'}},client={},_reader_session_gen=1,
        settings={auth_scope_matches=function(_,s) return valid and s==scope end,get_book=function() return {title='Book'} end},
        library_db={accountKey=function() return account end}}
    function host:showInfo(value) self.message=value end
    function host:showBusy(_,cancel) self.busy_message={cancel=cancel} end
    function host:closeBusy() self.busy_message=nil end
    function host:openFile(path,callback) self.opened=path;self.callback=callback;self._reader_session_gen=2 end
    function host:cancelBookSearch() self.cancelled_search=true end
    local owner={id='41',scope=scope,account='owner',native_entry=entry,session=1}
    local function is_current() return valid end
    return host,owner,is_current
end
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local host,owner,current=fixture();expect(Nav.start(host,owner,hit,current),'navigation did not start')
reason='not_saved';workers[#workers]:complete();expect(owner.navigation and owner.navigation.confirm and allow_seen==false,'missing chapter did not prompt')
owner.navigation.confirm.cancel_callback();expect(not owner.navigation and not host.opened,'cancel opened a chapter')
host,owner,current=fixture();Nav.start(host,owner,hit,current);reason='not_saved';workers[#workers]:complete()
local confirm=owner.navigation.confirm;reason=nil;result={path='/native/target',entry=target,anchor=anchor,local_only=true}
confirm.ok_callback();workers[#workers]:complete()
expect(host.opened=='/native/target' and allow_seen==true and type(host.callback)=='function','confirmed chapter not opened')
local next_host={ui={document={file='/native/target',identity={book_id='41',file_id=target.file_id,book_version=3}},view={view_mode='page'}},
    settings=host.settings,library_db=host.library_db,_reader_session_gen=1};next_host.ui.weread=next_host
expect(host.callback(next_host.ui) and not host.callback(next_host.ui),'handoff was not one-use')
account='other';local task=table.remove(UI.tasks,1);task();expect(not next_host._native_online_search_open,'other account resumed target')
host,owner,current=fixture();Nav.start(host,owner,hit,current);local pending=workers[#workers]
result={path='/native/target',entry=target,anchor=anchor,local_only=true};account='other';pending:complete()
expect(not owner.navigation and not host.opened,'changed account opened target')
host,owner,current=fixture();Nav.start(host,owner,hit,current);pending=workers[#workers]
result={path='/native/target',entry=target,anchor=anchor,local_only=true};page=2;pending:complete()
expect(not owner.navigation and not host.opened,'changed page opened target')
host,owner,current=fixture();Nav.start(host,owner,hit,current);pending=workers[#workers]
result={path='/native/target',entry=target,anchor=anchor,local_only=true};hit.finish=12;pending:complete();hit.finish=11
expect(not owner.navigation and not host.opened,'changed search result opened target')
host,owner,current=fixture();host._book_search_owner=owner;Nav.start(host,owner,hit,current)
reason='not_saved';workers[#workers]:complete();page=2;Nav.on_view_changed(host)
expect(not owner.navigation and not host.opened,'page change left a download confirmation active')
host,owner,current=fixture();native.renewal_pending=true
expect(not Nav.start(host,owner,hit,current) and not owner.navigation
    and host.message=='Authorize or renew E-Ink login in settings, then try again.','pending authorization did not stop navigation')
native.renewal_pending=nil
print(('native_direct_online_navigation_spec: %d checks'):format(checks))
