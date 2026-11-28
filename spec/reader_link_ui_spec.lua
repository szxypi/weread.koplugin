package.path='./?.lua;'..package.path
local tasks={}
package.preload['ui/uimanager']=function() return {close=function() end,show=function() end,
    scheduleIn=function(_self,delay,task) assert(delay>=0.1);tasks[#tasks+1]=task end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(text) return text end} end
local Protocol=require('weread.lib.protocol')
local url=Protocol.reader_url('900001')
local record={reader_url=url,metadata={bookId='900001',title='Synthetic',wordCount=12000}}
local store
package.preload['weread.lib.reader_link_store']=function() return {new=function() return store end} end
local Request=require('weread.ui.reader_link')
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local function fixture()
    local state={account='a',epoch=0,online=true,notices={},opened=0,stored=0,cancelled=0,valid=true}
    local auth={vid='900000',epoch=1}
    local settings={get_auth_scope=function() return auth end,auth_scope_matches=function() return state.valid end,
        get=function(_self,key,default) if key=='cookies' then return {wr_vid='900000',wr_skey='synthetic-import-cookie'} end;return default end}
    local jobs={}
    local host={settings=settings,client={},ui={},discovery_epoch=0,
        library_db={accountKey=function() return state.account end},
        isNetworkOnline=function() return state.online end,
        showOffline=function() state.offline=true end,requireLogin=function() state.login=true end,
        showInfo=function(_self,text) state.info=text end,showTransientInfo=function(_self,text) state.notices[#state.notices+1]=text end,
        showBusy=function(self,_text,cancel) self.busy_message={};state.dismiss=cancel end,
        closeBusy=function(self) self.busy_message=nil end,
        closeWeReadUI=function(self) Request.close(self);self.discovery_epoch=self.discovery_epoch+1 end,
        showBookRecord=function(_self,book,options) state.opened=state.opened+1;state.book=book;state.options=options end,
        reader_link_worker={start=function(_self,task,callback) jobs[#jobs+1]={task=task,callback=callback};return true end,
            cancel=function() state.cancelled=state.cancelled+1 end}}
    store={find=function() return state.cached end,put=function(_self,value) state.stored=state.stored+1;state.value=value;return state.save_ok~=false end}
    local function deliver(index,value) jobs[index or #jobs].callback(value or record) end
    return host,state,jobs,deliver,auth
end
local host,state,jobs,deliver=fixture()
local auth
expect(Request.start(host,url..'?wvid=discarded') and #jobs==1 and state.stored==0,'new import did not defer work')
deliver()
expect(state.stored==1 and state.opened==1 and state.book.book_id=='900001' and state.book.reader_url==url and state.options.verified_metadata
    and not host.reader_link_context and not host.busy_message,'verified metadata not saved/opened once')
expect(state.value.reader_url==url and not state.book.token,'private sharing data persisted')
for _,change in ipairs({'account','cookie','epoch','document','session','deadline','cancel'}) do
    host,state,jobs,deliver,auth=fixture();assert(Request.start(host,url))
    if change=='account' then state.account='b'
    elseif change=='cookie' then auth.epoch=2
    elseif change=='epoch' then host.discovery_epoch=1
    elseif change=='document' then host.ui.document={}
    elseif change=='session' then host._reader_session_gen=1
    elseif change=='deadline' then host.reader_link_context.started=os.time()-121
    else state.dismiss() end
    deliver()
    expect(#jobs==1 and state.stored==0 and state.opened==0 and not host.reader_link_context and not host.busy_message,'stale import applied: '..change)
end
host,state,jobs,deliver=fixture();assert(Request.start(host,url));local old=jobs[1];assert(Request.start(host,url))
local busy=host.busy_message;old.callback(record)
expect(host.busy_message==busy and host.reader_link_context and state.opened==0,'old callback cancelled new import')
deliver();expect(state.opened==1 and state.stored==1,'latest import lost')
host,state,jobs=fixture();state.cached=record;state.online=false
expect(Request.start(host,url) and #jobs==0 and state.opened==1 and state.stored==0,'offline saved link required network')
host,state,jobs=fixture();state.cached=record;state.online=false
expect(not Request.start(host,url,true) and state.offline and state.opened==0 and #jobs==0,'offline refresh replaced saved link')
host,state,jobs,deliver=fixture();state.save_ok=false;assert(Request.start(host,url));deliver()
expect(#jobs==1 and state.opened==0 and state.info:find('storage',1,true) and not host.reader_link_context,'failed persistence reported success')
host,state,jobs,deliver=fixture();assert(Request.start(host,url));deliver(nil,{reader_url=Protocol.reader_url('900002'),metadata={bookId='900002',title='Other'}})
expect(#jobs==1 and state.stored==0 and state.opened==0,'worker result from another link accepted')
host,state,jobs=fixture()
expect(not Request.start(host,'https://evil.test') and state.info and #jobs==0,'invalid URL started worker')
host,state,jobs=fixture();state.account=nil
expect(not Request.start(host,url) and state.login and #jobs==0,'unidentified account persisted imported data')
print(('reader_link_ui_spec: %d checks'):format(checks))
