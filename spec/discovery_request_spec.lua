package.path="./?.lua;./?/init.lua;"..package.path
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local revision,fetches,request=1,0
package.preload["weread.lib.discovery_source"]=function() return {
    capture=function() return {revision=revision} end,
    matches=function(_settings,selected) return selected.revision==revision end,
    fetch=function(_client,query)
        fetches=fetches+1;request=query
        return {books={{bookId="900001"}},next_cursor=query.cursor+20,has_more=true,
            source_kind="native",source_revision=revision,session_id="session-a"}
    end,
} end
package.preload["ui/uimanager"]=function() return {close=function() end} end
package.preload["weread.lib.plugin_util"]=function() return {tr=function(value) return value end} end
local Controller=require("weread.ui.discovery_request")
local pending,task,callback,account,rendered,message,cancels=nil,nil,nil,"a",0,nil,0
local host={settings={},client={},library_db={accountKey=function() return account end},
    runOnlineTask=function(_self,_label,fn) pending=fn;return true end,
    showBookstore=function() rendered=rendered+1 end,showInfo=function(_self,text) message=text end,
    showBusy=function(self,_label,on_cancel) self.busy_message={};self.cancel_button=on_cancel end,
    closeBusy=function(self) self.busy_message=nil end,
    discovery_worker={start=function(_self,work,done) task=work;callback=done;return true end,
        cancel=function() cancels=cancels+1 end}}
local function load(cursor,refresh,context) Controller.load(host,"recommend",nil,cursor,nil,refresh,context) end
load(0)
expect(host.discovery_loading and fetches==0 and not task,"network task only scheduled")
pending()
expect(host.discovery_loading and fetches==0 and task,"HTTP remains in child task")
local old_callback=callback
local result=task()
host.cancel_button()
expect(not host.discovery_loading and not host.busy_message and cancels==1,"cancel clears owned busy/worker")
load(0);pending()
local new_busy=host.busy_message
old_callback(result)
expect(host.discovery_loading and host.busy_message==new_busy and rendered==0,"old child cannot cancel replacement")
callback(task())
expect(rendered==1 and host.discovery_state.source_kind=="native" and not host.discovery_loading,"current child displayed")
local state=host.discovery_state
revision=2
load(20,false,state)
expect(not host.discovery_loading and message:find("access changed",1,true),"changed credentials block continuation")
load(20,true,state);pending();callback(task())
expect(request.cursor==0 and not request.source_kind and not request.source_revision
    and #host.discovery_state.history==0,"refresh resets old source/cursor")
state=host.discovery_state
load(20,false,state);pending();result=task();account="b";callback(result)
expect(host.discovery_state==state and rendered==2 and not host.discovery_loading,"late result cannot cross owner")
load(0);pending();result=task();host.discovery_epoch=1;callback(result)
expect(host.discovery_state==state and rendered==2,"closed screen cannot reopen")
load(0);pending();result=task();revision=3;callback(result)
expect(host.discovery_state==state and not host.discovery_loading,"renewal during read invalidates child")
load(0);pending();callback({ok=false})
expect(host.discovery_state==state and message:find("Cached books",1,true),"failure preserves visible page")
local count=fetches
load(20,false,{account="a",kind="recommend"})
expect(fetches==count and not host.discovery_loading,"stale widget callback ignored")
host.runOnlineTask=function() return false end
load(0)
expect(not host.discovery_loading and not host.busy_message,"offline scheduling releases lock")
print("discovery_request_spec: "..checks.." checks")
