package.path='./?.lua;'..package.path
local state
package.preload['ui/uimanager']=function() return {close=function(_self,widget) widget.closed=true end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(value) return value end} end
package.preload['weread.lib.mp_link']=function() return {MAX_RESULT=65536,
    capture=function(_settings,url) if url=='valid' then return {source=url} end end,
    matches=function() return not state.changed end,
    title=function(value) return type(value)=='string' and value end,
    read=function() return {ok=true,book_id='MP_WXS_42',review_id='MP_WXS_42_article_1',title='Article title'} end} end
package.preload['weread.lib.mp_link_store']=function() return {
    identity=function(book,review) return book=='MP_WXS_42' and review=='MP_WXS_42_article_1' end,
    add=function(_db,account,book,review,title) state.saves=state.saves+1;state.rows={{book_id=book,review_id=review,title=title}};return account==state.account and not state.store_error end,
    list=function(_db,account) return account==state.account and state.rows end} end
package.preload['weread.lib.content']=function() return {mp_article_cached_path=function() return state.cached and '/cached' end} end
package.preload['weread.ui.mp_record_recovery']=function() return {open=function() state.opened=true end} end
package.preload['weread.ui.shelf_state']=function() return {show=function(_host,id) state.managed=id end} end
local Module=require('weread.ui.mp_link')
local n=0
local function expect(value,label) n=n+1;assert(value,label) end
local function fixture()
    state={account='one',rows={},jobs={},saves=0,alive=true}
    local host={settings={get=function(_self,key,default) if key=='books' then return {} end;return default end},
        library_db={accountKey=function() return state.account end},client={},
        isNetworkConnected=function() return not state.offline end,showOffline=function() state.notice='offline' end,
        showBusy=function(self,_text,cancel) self.busy_message={};state.dismiss=cancel end,
        closeBusy=function(self) self.busy_message=nil end,showInfo=function(_self,text) state.notice=text end,
        showList=function(_self,_title,items) state.items=items;return {} end,
        getCachedMPArticles=function() return {} end,downloadMPArticleAndRead=function() state.downloaded=true end,
        mp_link_worker={start=function(_self,task,callback) state.jobs[#state.jobs+1]={task=task,callback=callback};return not state.start_error end,
            cancel=function() state.cancelled=true end}}
    local function current() return state.alive end
    local function deliver(result) local job=state.jobs[#state.jobs];job.callback(result or job.task()) end
    return host,current,deliver
end
local host,current,deliver=fixture()
expect(Module.start(host,{},current,'valid'),'lookup did not start');deliver()
expect(state.saves==1 and #state.items==1 and state.items[1].text=='Article title' and not host.mp_link_job and not host.busy_message,'lookup did not save title and show')
state.items[1].callback();expect(state.downloaded,'selected article did not enter native download')
state.downloaded=nil;state.cached=true;state.items[1].callback();expect(state.opened and not state.downloaded,'cache not reopened')
local old_item=state.items[1];host._mp_link_menu.onCloseWidget(host._mp_link_menu);state.opened=false;old_item.callback()
expect(not state.opened and not state.downloaded,'closed article list remained active')
Module.accounts(host,{},current);expect(#state.items==1 and state.items[1].post_text=='Article title','imported account missing')
state.items[1].callback();expect(state.managed=='MP_WXS_42','account status not opened')
local old_account=state.items[1];state.managed=nil;state.account='two';old_account.callback();expect(not state.managed,'stale account action remained active')
for _,change in ipairs({'account','view','credentials','expired'}) do
    host,current,deliver=fixture();Module.start(host,{},current,'valid')
    if change=='account' then state.account='two' elseif change=='view' then state.alive=false
    elseif change=='credentials' then state.changed=true else host.mp_link_job.started=os.time()-121 end
    deliver();expect(state.saves==0 and not state.items and not host.mp_link_job,'stale request committed: '..change)
end
host,current,deliver=fixture();Module.start(host,{},current,'valid');state.dismiss();deliver()
expect(state.saves==0 and not host.mp_link_job,'cancelled request committed')
host,current,deliver=fixture();Module.start(host,{},current,'valid');deliver({ok=true,book_id='bad',review_id='bad'})
expect(state.saves==0 and state.notice,'untrusted worker result saved')
host,current,deliver=fixture();state.store_error=true;Module.start(host,{},current,'valid');deliver()
expect(state.notice and not state.items,'storage failure opened article')
host,current=fixture();expect(not Module.start(host,{},current,'bad') and state.notice,'bad URL started')
print('PASS: imported article UI ('..n..' checks)')
