package.path='./?.lua;'..package.path
local scheduled,worker,changed_file={},nil,false
local UI={}
function UI:scheduleIn(_,task) scheduled[#scheduled+1]=task end
function UI:unschedule(task) for i=#scheduled,1,-1 do if scheduled[i]==task then table.remove(scheduled,i) end end end
package.preload['ui/uimanager']=function() return UI end
package.preload['weread.lib.plugin_util']=function() return {tr=function(x) return x end} end
local page=1
package.preload['weread.lib.source_context']=function() return {location=function() return {page=page} end,
    same_location=function(a,b) return a and b and a.page==b.page end} end
local file_id=string.rep('f',64)
local entry={book_id='42',chapter_uid='37',book_version=1}
local hit={chapter_uid='37',file_id=file_id,byte=4,anchor={co=2,text='long enough anchor',point_offset=1,
    point_unit='unicode_scalars',basis='filtered_xhtml_utf16'}}
local path='/tmp/native-reader-v1/target.epub'
package.preload['weread.lib.native_direct_cache']=function() return {
    valid_entry=function(e,id,account) return e==entry and id=='42' and account=='123' end,
    open=function(_,_,_,e,current) assert(e==entry and current());return not changed_file and {path=path,file_id=file_id} end,
} end
package.preload['weread.lib.native_direct_search']=function() return {scan=function(_,_,e,keyword,byte,ignore,current)
    assert(e==entry and keyword=='needle' and byte==4 and not ignore and current());return {hits={hit}}
end} end
package.preload['weread.lib.native_direct_path']=function() return {contains=function(_,value) return value==path end} end
package.preload['weread.lib.book_file_identity']=function() return {read_document=function() return {
    book_id='42',book_version=1,file_id=file_id} end} end
package.preload['weread.lib.source_dom']=function() return {open_direct_prepared=function(_,_,_,_,options)
    assert(options.is_current());return {locate_anchor=function() return {co=2,book_id='42',chapter_uid='37',file_id=file_id,
        render_path='OEBPS/text/chapter.xhtml',xpointer='/target'} end}
end} end
local moved=0
package.preload['weread.lib.reader_position']=function() return {goto_xpointer=function(_,xp) assert(xp=='/target');moved=moved+1;return true end,
    snapshot=function() return {} end,contains_anchor=function() return true end} end
package.preload['weread.lib.memory_worker']=function() return {new=function()
    worker={}
    function worker:start(task,callback) self.task,self.callback=task,callback;return true end
    function worker:cancel() self.cancelled=true end
    function worker:complete() local task,callback=self.task,self.callback;self.task=nil;callback(task()) end
    return worker
end} end
local Search=require('weread.ui.native_direct_search_open')
local scope={vid='123'};local account='owner'
local function fixture(file)
    local host={ui={document={file=file},view={view_mode='page'}},client={},_reader_session_gen=2,
        settings={get_auth_scope=function() return scope end,auth_scope_matches=function(_,s) return s==scope end},
        library_db={accountKey=function() return account end}}
    function host:showBusy(_,cancel) self.busy_message={cancel=cancel} end
    function host:closeBusy() self.busy_message=nil end
    function host:showInfo(message) self.message=message end
    function host:openFile(next_file,callback) self.opened=next_file;self.callback=callback;self._reader_session_gen=3 end
    return host
end
local function tick() local task=table.remove(scheduled,1);if task then task() end end
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local host=fixture(path);expect(Search.start(host,entry,hit,'needle',false),'same chapter did not start')
worker:complete();tick();worker:complete()
expect(moved==1 and not host._native_direct_search_open,'same-chapter target was not verified and opened')
host=fixture(path);changed_file=true;Search.start(host,entry,hit,'needle',false);worker:complete()
expect(moved==1 and host.message and not host._native_direct_search_open,'changed file moved the reader');changed_file=false
host=fixture(path);Search.start(host,entry,hit,'needle',false);page=2;Search.on_view_changed(host)
expect(not host._native_direct_search_open and worker.cancelled,'page change left navigation active');page=1
host=fixture('/tmp/native-reader-v1/other.epub');Search.start(host,entry,hit,'needle',false);worker:complete()
expect(host.opened==path and type(host.callback)=='function','cross-chapter handoff not prepared')
local next_host=fixture(path);local next_reader=next_host.ui;next_reader.weread=next_host
expect(host.callback(next_reader) and not host.callback(next_reader),'handoff was not one-use')
account='other';tick();expect(not next_host._native_direct_search_open and moved==1,'new account resumed old search');account='owner'
host=fixture('/tmp/native-reader-v1/other.epub');Search.start(host,entry,hit,'needle',false);worker:complete()
next_host=fixture(path);next_reader=next_host.ui;next_reader.weread=next_host;assert(host.callback(next_reader));tick()
assert(next_host._native_direct_search_open);worker:complete();tick();worker:complete()
expect(moved==2 and not next_host._native_direct_search_open,'cross-chapter result did not complete')
print(('native_direct_search_open_spec: %d checks'):format(checks))
