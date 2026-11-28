package.path='./?.lua;'..package.path
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local state
package.preload['ui/uimanager']=function() return {
    show=function(_,dialog) state.dialog=dialog end,close=function() end,
    scheduleIn=function(_,_,task) state.tasks[#state.tasks+1]=task end,unschedule=function() end} end
package.preload['ui/widget/buttondialog']=function() return {new=function(_,value) return value end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(value) return value end} end
package.preload['weread.lib.native_direct_path']=function() return {contains=function(_,path)
    return type(path)=='string' and path:find('/native-reader-v1/',1,true)~=nil end} end
local scope={vid='123'}
local entry={book_id='42',chapter_uid='7',book_version=3,file_id=string.rep('a',64),source_sha256=string.rep('b',64)}
local target={book_id='42',chapter_uid='7',book_version=3,file_id=string.rep('c',64),source_sha256=entry.source_sha256}
package.preload['weread.lib.native_direct_cache']=function() return {valid_entry=function(item,id,account)
    return (item==entry or item==target) and id=='42' and account=='123' end} end
package.preload['weread.lib.book_file_identity']=function() return {read_document=function()
    return {book_id='42',book_version=3,file_id=entry.file_id} end} end
package.preload['weread.lib.source_context']=function() return {
    location=function() return {page=state.page} end,same_location=function(a,b) return a and b and a.page==b.page end,
    capture=function(doc,id,_,options)
        local found=options.metadata_resolver(doc,id,'OEBPS/text/chapter.xhtml')
        expect(found and found.identity.file_id==entry.file_id and options.is_current(),'reader identity not checked')
        return state.capture_error and {error='unavailable'} or {text='synthetic'}
    end} end
package.preload['weread.lib.memory_worker']=function() return {new=function() return {
    start=function(_,task,callback) state.job={task=task,callback=callback};return true end,
    cancel=function() state.cancelled=true end} end} end
package.preload['weread.lib.native_direct_copy_resume']=function() return {prepare=function(_,account,item,path,dest,input,current)
    expect(account=='123' and item==entry and path==state.old and dest==state.new and input.text=='synthetic' and current(),
        'copy mapping lost its source');return state.result
end} end
package.preload['weread.ui.native_direct_search_open']=function() return {start=function(_,item,hit,keyword,ignore)
    if state.open_failed then return false end
    state.opened={item=item,hit=hit,keyword=keyword,ignore=ignore};return true end} end
local Resume=require('weread.ui.native_direct_copy_resume')
local function fixture()
    state={page=2,tasks={},old='/tmp/native-reader-v1/old.epub',new='/tmp/native-reader-v1/new.epub',account='owner'}
    state.result={entry=target,hit={file_id=target.file_id},keyword='synthetic unique text'}
    local doc={file=state.old}
    local host={ui={document=doc,view={view_mode='page'}},client={},_reader_session_gen=1,
        settings={get_auth_scope=function() return scope end,auth_scope_matches=function(_,value) return value==scope end},
        library_db={accountKey=function() return state.account end},showBusy=function(self) self.busy_message={} end,
        closeBusy=function(self) self.busy_message=nil end,showInfo=function(_,message) state.message=message end}
    function state.pump() local task=table.remove(state.tasks,1);assert(task);task() end
    function state.deliver() local job=assert(state.job);job.callback(job.task()) end
    return host,state
end
local host,s=fixture();expect(Resume.offer(host,entry,s.new),'copy offer did not open')
expect(not s.opened and s.dialog.buttons[1][2].text=='Continue in new copy','copy opened without a choice')
s.dialog.buttons[1][1].callback();expect(not host._native_direct_copy_resume and not s.opened,'later opened the copy')
host,s=fixture();Resume.offer(host,entry,s.new);s.dialog.buttons[1][2].callback();s.pump();s.deliver()
expect(s.opened and s.opened.item==target and s.opened.keyword=='synthetic unique text' and not s.opened.ignore,
    'verified copy did not use the local search handoff')
host,s=fixture();s.open_failed=true;Resume.offer(host,entry,s.new);s.dialog.buttons[1][2].callback();s.pump();s.deliver()
expect(not s.opened and s.message:find('current page was kept',1,true),'failed handoff did not preserve the current page')
host,s=fixture();Resume.offer(host,entry,s.new);s.dialog.buttons[1][2].callback();s.pump()
local job=s.job;local result=job.task();s.page=3;job.callback(result)
expect(not s.opened and not host._native_direct_copy_resume,'late mapping moved a changed page')
host,s=fixture();s.capture_error=true;Resume.offer(host,entry,s.new);s.dialog.buttons[1][2].callback();s.pump()
expect(not s.opened and s.message:find('current page was kept',1,true),'missing context changed the reader')
host,s=fixture();Resume.offer(host,entry,s.new);local old=s.dialog.buttons[1][2].callback;Resume.cancel(host);old()
expect(not s.opened and #s.tasks==0,'dismissed prompt remained active')
host,s=fixture();Resume.offer(host,entry,s.new);s.dialog.buttons[1][2].callback();s.pump()
job=s.job;result=job.task();s.account='other';job.callback(result)
expect(not s.opened and not host._native_direct_copy_resume,'changed account accepted an old result')
print('PASS: improved copy prompt, reader lifetime and verified handoff ('..checks..' checks)')
