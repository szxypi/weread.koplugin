package.path='./?.lua;'..package.path
local state
package.preload['ui/uimanager']=function() return {
    scheduleIn=function(_self,_delay,fn) state.queue[#state.queue+1]=fn end,show=function() end,
    close=function(_self,widget) if widget.onCloseWidget then widget:onCloseWidget() end end}
end
package.preload['ui/widget/confirmbox']=function() return {new=function(_self,value) return value end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(s) return s end,T=function(s,...) local args={...};return (s:gsub('%%(%d+)',function(i) return tostring(args[tonumber(i)]) end)) end} end
package.preload['weread.lib.content']=function() return {book_resolved_dir=function(_s,_id,book) return book.cache_dir end} end
package.preload['weread.lib.mp_cache_cleanup']=function() return {
    scan=function() return state.plan end,check=function(value) if state.invalid or not value then error('private cache failure') end;return value end,
    targets=function(plan,selected) return {body=selected and plan.versions[1],generations={1},bytes=2048} end,
    acquire=function()
        if state.lock_failed then return nil end
        state.lock={fd=9,release=function(self) self.fd=nil;state.released=true end};return state.lock
    end,
    begin=function() if state.changed then error('changed') end;return {removed_files=0,removed_bytes=0} end,
    step=function(job)
        state.steps=state.steps+1;job.removed_files=job.removed_files+1;job.removed_bytes=1024*job.removed_files
        if state.storage_failed then return false,'storage' end
        return true,state.more and 'more' or 'done'
    end}
end
local Cleanup=require('weread.ui.mp_cache_cleanup')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local function fixture()
    state={account='one',queue={},jobs={},steps=0,books={MP_WXS_1={cache_dir='/cache'}},plan={
        versions={{name='old.html',info={modification=1700000000,size=1024}},
            {name='current.html',current=true,info={modification=1700000000,size=1024}}}}}
    local host={ui={document={file='/reader'}},discovery_epoch=1,_reader_session_gen=1,client={},
        settings={cache_dir='/all',get=function() return state.books end},library_db={accountKey=function() return state.account end},
        showInfo=function(_self,text) state.notice=text end,
        closeWeReadUI=function(self) Cleanup.cancel(self);self.discovery_epoch=self.discovery_epoch+1 end,
        showBusy=function(self,_text,dismiss) self.busy_message={};state.dismiss=dismiss end,closeBusy=function(self) self.busy_message=nil end,
        showList=function(_self,title,rows) return {title=title,item_table=rows} end,
        mp_cleanup_worker={start=function(_self,task,cb) state.jobs[#state.jobs+1]={task=task,cb=cb};return true end,cancel=function() state.cancelled=true end}}
    local book={book_id='MP_WXS_1',cache_dir='/cache'};local article={reviewId='one',title='Test'}
    local function tick() local fn=table.remove(state.queue,1);assert(fn);fn() end
    local function deliver(index) local job=state.jobs[index or #state.jobs];job.cb(job.task()) end
    return host,book,article,tick,deliver
end
local host,book,article,tick,deliver=fixture()
expect(Cleanup.show(host,book,article),'cleanup start failed');tick();deliver()
local menu=host._mp_cleanup_menu
expect(menu and not host.busy_message and #menu.item_table==3 and menu.item_table[3].select_enabled==false,'preview missing or current version deletable')
expect(state.steps==0 and not state.lock,'preview mutated or locked cache')
menu.item_table[2].callback();local dialog=host._mp_cleanup_confirmation
expect(dialog.text:find('Reading records are not deleted',1,true) and state.steps==0,'confirmation missing or destructive before confirmation')
dialog.cancel_callback();expect(state.steps==0 and host.mp_cleanup_job,'cancel confirmation discarded preview or deleted files')
menu.item_table[2].callback();host._mp_cleanup_confirmation.ok_callback();deliver();tick()
expect(not host.mp_cleanup_job and state.released and state.steps==1 and state.notice:find('Removed 1 files',1,true),'successful cleanup did not release lock or report actual count')
for _,change in ipairs({'account','epoch','session','document','file','cache','record'}) do
    host,book,article,tick,deliver=fixture();Cleanup.show(host,book,article);tick();deliver()
    host._mp_cleanup_menu.item_table[2].callback();dialog=host._mp_cleanup_confirmation
    if change=='account' then state.account='two' elseif change=='epoch' then host.discovery_epoch=20
    elseif change=='session' then host._reader_session_gen=20 elseif change=='document' then host.ui.document={file='/reader'}
    elseif change=='file' then host.ui.document.file='/other' elseif change=='cache' then host.settings.cache_dir='/moved'
    else state.books.MP_WXS_1.cache_dir='/moved' end
    dialog.ok_callback();expect(not state.lock and state.steps==0,'stale confirmation acquired deletion lock: '..change)
end
host,book,article=fixture();Cleanup.show(host,book,article);local old_dismiss=state.dismiss
Cleanup.show(host,book,article);local latest=host.mp_cleanup_job;old_dismiss()
expect(host.mp_cleanup_job==latest,'old cancel callback stopped newer preview')
host,book,article,tick,deliver=fixture();Cleanup.show(host,book,article);tick();deliver();menu=host._mp_cleanup_menu
menu:onCloseWidget();menu.item_table[2].callback()
expect(not host.mp_cleanup_job and not host._mp_cleanup_confirmation,'closed menu retained deletion callback')
for _,failure in ipairs({'lock_failed','invalid','changed'}) do
    host,book,article,tick,deliver=fixture();Cleanup.show(host,book,article);tick();deliver()
    host._mp_cleanup_menu.item_table[2].callback();state[failure]=true;host._mp_cleanup_confirmation.ok_callback()
    if not state.lock_failed then deliver() end
    expect(not host.mp_cleanup_job and state.steps==0 and state.notice,'failed revalidation deleted files: '..failure)
    if state.lock then expect(state.released,'failed revalidation retained lock') end
end
host,book,article,tick,deliver=fixture();Cleanup.show(host,book,article);tick();deliver();host._mp_cleanup_menu.item_table[2].callback()
host._mp_cleanup_confirmation.ok_callback();deliver();state.more=true;tick();state.dismiss()
expect(state.steps==1 and state.released and not host.mp_cleanup_job and state.notice:find('Cleanup stopped',1,true),'cancel after one batch did not report partial deletion')
tick();expect(state.steps==1,'cancelled deletion callback continued')
host,book,article,tick,deliver=fixture();Cleanup.show(host,book,article);tick();deliver();host._mp_cleanup_menu.item_table[2].callback()
host._mp_cleanup_confirmation.ok_callback();deliver();state.storage_failed=true;tick()
expect(state.released and state.notice:find('Cleanup stopped',1,true) and state.notice:find('Removed 1',1,true),'partial failure claimed nothing removed')
host,book,article,tick=fixture()
host.mp_download_worker={job={pid=123},runner={done=function() return state.reaped end}}
Cleanup.show(host,book,article);tick();expect(#state.jobs==0,'preview raced unreaped article task')
state.reaped=true;tick();expect(#state.jobs==1,'preview never resumed after reaping')
print('PASS: MP cleanup UI confirmation, lock lifetime and partial cancellation ('..checks..' checks)')
