package.path='./?.lua;'..package.path
local scheduled,tasks,cancels={}, {},0
local UI={scheduleIn=function(_,_,fn) scheduled[#scheduled+1]=fn end,
    unschedule=function(_,fn) for i=#scheduled,1,-1 do if scheduled[i]==fn then table.remove(scheduled,i) end end end,
    close=function(_,value) if value.onCloseWidget then value:onCloseWidget() end end,show=function() end,
    nextTick=function(_,fn) scheduled[#scheduled+1]=fn end}
package.preload['ui/uimanager']=function() return UI end
package.preload['weread.lib.plugin_util']=function() return {tr=function(s) return s end,T=function(s,...)
    local args={...};return (s:gsub('%%(%d+)',function(i) return tostring(args[tonumber(i)] or '') end))
end} end
package.preload['weread.ui.download_dialog']=function() return {new=function(_,value)
    function value:show() end;function value:reportProgress(n) self.progress=n end
    function value:setTitle(title) self.title=title end;return value end} end
package.preload['ui/widget/confirmbox']=function() return {new=function(_,value) return value end} end
local saved,prefetched,fail_cache,fail_image,change_during={}, {},false,false,false
package.loaded['weread.lib.my_cloud_marks']={display_id=function(v) return type(v)=='string' and v:match('^%d+$') and v end}
package.loaded['weread.lib.my_cloud_thoughts']={validate=function(_,value,id)
    assert(type(value)=='table' and value.book_id==id and type(value.reviews)=='table');return value end}
package.loaded['weread.lib.my_cloud_marks_store']={MAX_BOOKS=5000,MAX_PAYLOAD=4096,new=function()
    return {valid_ids=function(_,ids) if fail_cache then return nil end;local out={}
        for _,id in ipairs(ids) do if saved[id] then out[id]=true end end;return out end,
        read=function(_,id) return saved[id] end}
end}
package.loaded['weread.lib.thought_edit_contract']={row_hash=function(row) return row.token end,
    hash=function(value) return type(value)=='string' and #value==64 end}
package.loaded['weread.lib.native_position_guard']={new=function()
    local alive=true;return {valid=function() return alive end,close=function() alive=false end} end}
package.loaded['weread.lib.thought_image_store']={new=function() return {clear=function(_,account,current)
    assert(account=='account' and current());return 2 end} end}
package.loaded['weread.lib.thought_image']={prefetch=function(_,_,account,book,review,url,current,precommit)
    assert(account=='account' and current());prefetched[#prefetched+1]={book,review,url}
    if change_during then saved[book].reviews[1].token='changed during download' end
    if not precommit() then return nil,'changed' end
    if fail_image then return nil,'storage' end
    return #prefetched==1 and 'cached' or 'saved'
end}
package.loaded['weread.lib.memory_worker']={new=function() return {start=function(_,task,callback)
    tasks[#tasks+1]={task=task,callback=callback};return true end,cancel=function() cancels=cancels+1 end} end}
local Bulk=require('weread.ui.notebook_image_bulk')
local function fixture()
    tasks={};scheduled={};cancels=0;prefetched={};fail_cache=false;fail_image=false;change_during=false
    local url='https://weread-picture-1258476243.file.myqcloud.com/'
    saved={['1']={book_id='1',reviews={{reviewId='a',token='a1',attachment_state='available',attachment_digest=string.rep('a',64),
        attachment_urls=url..'a\n'..url..'b'},
        {reviewId='b',token='b1',attachment_state='partial',attachment_digest=string.rep('b',64),attachment_urls=url..'c'}}},
        ['3']={book_id='3',reviews={{reviewId='old',token='old',attachment_state='available',attachment_urls=url..'old'}}}}
    local state={current=true,online=true,account='account',notices={}}
    local host={settings={data_dir='/data',cache_dir='/cache'},client={},library_db={accountKey=function() return state.account end},
        isNetworkOnline=function() return state.online end,showOffline=function(_,v) state.notices[#state.notices+1]=v end,
        showInfo=function(_,v) state.notices[#state.notices+1]=v end,
        showTransientInfo=function(_,v) state.notices[#state.notices+1]=v end}
    function host:showBusy(_,cancel) self.busy_message={cancel=cancel} end
    local owner={account='account',menu={},value={books={{bookId='1'},{bookId='2'},{bookId='3'},{bookId='unsupported'}}}}
    return host,owner,state,function() return state.current and state.account==owner.account end
end
local function complete() local task=assert(table.remove(tasks,1));task.callback(task.task()) end
local function step() local fn=assert(table.remove(scheduled,1));fn() end
local function drain(owner)
    local count=0
    while owner.image_bulk_context do
        count=count+1;assert(count<40)
        if #tasks>0 then complete() else step() end
    end
end
local host,owner,state,current=fixture();assert(Bulk.start(host,owner,current));local job=owner.image_bulk_context
drain(owner)
assert(job.done==3 and job.saved==2 and job.cached==1 and job.missing==1 and job.partial==1 and job.unverified==1 and job.skipped==1)
assert(#prefetched==3 and state.notices[1]:find('2 downloaded, 1 already saved',1,true))
host,owner,state,current=fixture();assert(Bulk.start(host,owner,current));complete();step()
saved['1'].reviews[1].token='changed';complete()
assert(not owner.image_bulk_context and #prefetched==0 and state.notices[1]:find('stopped',1,true),
    'changed note fetched an old attachment')
host,owner,state,current=fixture();assert(Bulk.start(host,owner,current));complete();step();change_during=true;complete()
assert(not owner.image_bulk_context and #prefetched==1 and state.notices[1]:find('stopped',1,true),
    'note changed during image fetch was not detected')
host,owner,state,current=fixture();assert(Bulk.start(host,owner,current));local pending=tasks[1]
owner.image_bulk_context.dialog.buttons[1][1].callback();pending.callback({missing=true})
assert(not owner.image_bulk_context and cancels==1 and #prefetched==0 and state.notices[1]:find('cancelled',1,true))
host,owner,state,current=fixture();assert(Bulk.start(host,owner,current));state.account='other';complete()
assert(not owner.image_bulk_context and #prefetched==0 and #state.notices==0,'account change accepted old work')
host,owner,state,current=fixture();assert(Bulk.start(host,owner,current));fail_cache=true;complete()
assert(not owner.image_bulk_context and #prefetched==0 and state.notices[1]:find('stopped',1,true))
host,owner,state,current=fixture();assert(Bulk.start(host,owner,current));complete();step();fail_image=true;complete()
assert(not owner.image_bulk_context and #prefetched==1 and state.notices[1]:find('Earlier images are kept',1,true))
host,owner,state,current=fixture();state.online=false;assert(not Bulk.start(host,owner,current) and #tasks==0)
host,owner,state,current=fixture();owner.bulk_context={};assert(state.online and not Bulk.start(host,owner,current) and #tasks==0)
host,owner,state,current=fixture();assert(Bulk.clear(host,owner,current));local confirm=assert(owner.menu._shelf_popup)
assert(#tasks==0 and not host.busy_message);confirm.ok_callback();assert(owner.image_bulk_context and host.busy_message)
complete();assert(not owner.image_bulk_context and not host.busy_message and state.notices[1]:find('Cleared 2',1,true))
host,owner,state,current=fixture();assert(Bulk.clear(host,owner,current));confirm=assert(owner.menu._shelf_popup)
UI:close(confirm);confirm.ok_callback();assert(not owner.image_bulk_context and #tasks==0,'closed confirmation cleared images')
assert(state.online)
host,owner,state,current=fixture();assert(Bulk.clear(host,owner,current));confirm=assert(owner.menu._shelf_popup)
state.account='other';confirm.ok_callback();assert(not owner.image_bulk_context and #tasks==0,'account switch cleared old cache')
print('PASS: offline thought image batch, stale snapshots, cancellation and quota stop')
