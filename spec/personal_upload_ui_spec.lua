package.path='./?.lua;'..package.path
local state
package.preload['ui/uimanager']=function() return {show=function() end,close=function() end,nextTick=function(_self,fn) fn() end} end
package.preload['ui/widget/confirmbox']=function() return {new=function(_self,value) return value end} end
package.preload['ui/widget/buttondialog']=function() return {new=function(_self,value) return value end} end
package.preload['ui/widget/pathchooser']=function() return {new=function(_self,value) return value end} end
package.preload['ffi/util']=function() return {template=function(text,value) return (text:gsub('%%1',value)) end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(value) return value end} end
package.preload['weread.lib.read_access']=function() return {display_book_id=function(id) return id=='CB_synthetic' and id end} end
package.preload['weread.lib.native_read_access']=function() return {capture=function() return not state.no_access and {scope={vid='900000',epoch=1}} end,
    matches=function() return not state.stale end} end
package.preload['weread.lib.shelf_membership_write']=function() return {members=function(snapshot) return snapshot and snapshot.members end,
    contains=function(snapshot,id) return snapshot and snapshot.present==id end,digest=function() return string.rep('a',64) end,
    protected=function() return string.rep('b',64) end} end
package.preload['weread.lib.personal_upload']=function() return {MAX_RESULT=8*1024*1024,
    capture=function(path) return path=='/synthetic/book.txt' and {path=path,name='book.txt',size=8} end,
    run=function() return state.result end} end
package.preload['weread.lib.personal_upload_journal']=function() return {new=function() return {
    read=function() return state.record end,
    begin=function(_self,_scope,path,size)
        if state.record.phase=='pending' or state.fail_begin then return nil end
        state.record={phase='pending',path=path,size=size};return state.record
    end,
    owns=function(_self,_scope,record) return state.record==record and record.phase=='pending' end,
    finish=function(_self,_scope,record)
        if state.fail_finish or state.record~=record then return false end
        state.record={phase='idle'};return true
    end} end} end
local Module=require('weread.ui.personal_upload')
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local function fixture()
    state={account='one',record={phase='idle'},jobs={},saved=0,valid=true}
    local scope={vid='900000',epoch=1}
    local host={settings={get_auth_scope=function() return scope end,auth_scope_matches=function() return state.valid end},
        client={},library_db={accountKey=function() return state.account end,cacheShelf=function() state.saved=state.saved+1;return not state.fail_cache end},
        ui={file_chooser={path='/synthetic'}},discovery_epoch=0,_reader_session_gen=1,
        isNetworkConnected=function() return not state.offline end,showOffline=function() state.notice='offline' end,
        showInfo=function(_self,text) state.notice=text end,showBookshelf=function() state.opened=true end,
        showBusy=function(self,_text,cancel) self.busy_message={};state.dismiss=cancel end,
        closeBusy=function(self) self.busy_message=nil end,applyShelfSnapshot=function() state.applied=true end,
        personal_upload_worker={start=function(_self,task,callback) if state.fail_start then return false end;state.jobs[#state.jobs+1]={task=task,callback=callback};return true end,
            cancel=function() state.cancelled=true end}}
    local function choose()
        expect(Module.open(host),'chooser did not open')
        local chooser=assert(host._personal_upload_ui.chooser);chooser.onConfirm('/synthetic/book.txt')
        local dialog=assert(host._personal_upload_ui.dialog);dialog.ok_callback()
    end
    local function deliver(result) local job=state.jobs[#state.jobs];job.callback(result or job.task()) end
    state.result={kind='confirmed',put_attempted=true,notify_attempted=true,book_id='CB_synthetic',
        before_members_digest=string.rep('a',64),protected_digest=string.rep('b',64),
        snapshot={members={'41','CB_synthetic'},present='CB_synthetic',books={},archive={}}}
    return host,choose,deliver
end
local host,choose,deliver=fixture();choose();expect(state.record.phase=='pending' and #state.jobs==1,'intent was not reserved before worker')
deliver();expect(state.record.phase=='idle' and state.saved==1 and state.applied and not host._personal_upload_ui,'verified upload not settled')
for _,kind in ipairs({'unconfirmed','bad_result','cache_failure','finish_failure','start_failure','cancel','stale','account','epoch'}) do
    host,choose,deliver=fixture()
    if kind=='start_failure' then state.fail_start=true end
    choose()
    if kind=='unconfirmed' then deliver({kind='unconfirmed',put_attempted=true,notify_attempted=false})
    elseif kind=='bad_result' then deliver({kind='confirmed',put_attempted=true,notify_attempted=true})
    elseif kind=='cache_failure' then state.fail_cache=true;deliver()
    elseif kind=='finish_failure' then state.fail_finish=true;deliver()
    elseif kind=='cancel' then state.dismiss();deliver()
    elseif kind=='stale' then state.stale=true;deliver()
    elseif kind=='account' then state.account='two';deliver()
    elseif kind=='epoch' then host.discovery_epoch=2;deliver() end
    expect(state.record.phase=='pending' and not state.applied,'uncertain upload was cleared: '..kind)
end
host,choose,deliver=fixture();choose();deliver({kind='login',put_attempted=false,notify_attempted=false})
expect(not host._personal_upload_ui and state.record.phase=='idle' and state.notice:find('authorization',1,true),'proven-unsent login failure stayed pending')
host,choose,deliver=fixture();choose();deliver({kind='unconfirmed',put_attempted=true,notify_attempted=false})
expect(Module.open(host),'pending record did not open');local pending=host._personal_upload_ui.dialog
pending.buttons[2][1].callback();local confirm=host._personal_upload_ui.dialog;confirm.ok_callback()
expect(state.record.phase=='idle' and not host._personal_upload_ui,'explicit pending-record clearance failed')
print('PASS: native personal upload UI ('..checks..' checks)')
