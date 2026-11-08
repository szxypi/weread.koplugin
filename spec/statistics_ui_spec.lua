package.path="./?.lua;./?/init.lua;"..package.path
package.preload["weread.lib.native_credentials"]=function() return {new=function(_self,settings) return settings.native_store end} end
local login_tasks={}
package.preload["ui/uimanager"]=function() return {close=function() end,
    scheduleIn=function(_self,delay,task) assert(delay>=0.1);login_tasks[#login_tasks+1]=task end} end
package.preload["weread.lib.plugin_util"]=function() return {tr=function(value) return value end} end
package.preload["weread.ui.read_stats_view"]=function() return {show=function(data,callbacks) return {data=data,callbacks=callbacks} end} end
local Stats=require("weread.lib.read_stats")
local Source=require("weread.lib.statistics_source")
local Request=require("weread.ui.statistics_request")
local Profile=require("weread.ui.profile")
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local function fixture()
    local scope={vid="900000",epoch=1}
    local state={revision=1,pending=false,key="",present=true,valid=true,online=true,owner="a",cache={},writes=0,
        native=0,gateway=0,renewals=0,codes={},save_ok=true,credentials={vid="900000",accessToken="synthetic-old",
            refreshToken="synthetic-refresh",deviceId=string.rep("1",32)}}
    local settings={data_dir="/unused",get=function(_self,key,default)
        if key=="api_key" then return state.key end
        if key=="account" then return {name="Synthetic"} end
        return default
    end,get_auth_scope=function() return scope end,auth_scope_matches=function(_self,candidate) return state.valid and candidate==scope end}
    settings.native_store={read=function() return state.present and state.credentials or nil,state.revision,nil,state.pending end}
    local function raw(mode,base)
        local canonical=mode=="overall" and 0 or Stats.period_start(mode,base and base>0 and base or os.time())
        return {baseTime=canonical,readTimes={},totalReadTime=0,readDays=0}
    end
    local decoded
    local client={settings=settings,json_decode=function() return decoded end,
        request=function(_self,options)
            state.native=state.native+1
            local mode=options.url:match("mode=([a-z]+)")
            local base=tonumber(options.url:match("baseTime=(%d+)"))
            decoded=raw(mode,base)
            return "fixture",table.remove(state.codes,1) or 200
        end,get_gateway_read_stats=function(_self,mode,base) state.gateway=state.gateway+1;return raw(mode,base) end}
    client.get_read_stats=function(self,mode,base,selected,options) return Source.fetch(self,mode,base,selected,options) end
    local queue,scheduled={},{}
    local function worker() return {start=function(_self,task,callback) queue[#queue+1]={task=task,callback=callback};return true end,cancel=function() end} end
    local host={settings=settings,client=client,
        library_db={accountKey=function() return state.owner end,getProfileState=function(_self,key) return (state.cache[state.owner] or {})[key] end,
            putProfileState=function(_self,key,value)
                if not state.save_ok then return false end
                state.cache[state.owner]=state.cache[state.owner] or {};state.cache[state.owner][key]=value;state.writes=state.writes+1;return true
            end},
        statistics_worker=worker(),profile_worker=worker(),
        isNetworkOnline=function() return state.online end,
        showInfo=function(_self,text) state.info=text end,showOffline=function() state.offline=true end,
        showBusy=function(self,_text,cancel) self.busy_message={};state.cancel=cancel end,
        closeBusy=function(self) self.busy_message=nil end,
        requireLogin=function() state.login=true end,
        discoveryNavigation=function() return {} end,
        runOnlineTask=function(_self,_label,task) scheduled[#scheduled+1]=task;return true end,
        loadReadStats=function(self,...) return Request.load(self,...) end,
        cancelProfileRefresh=function(self) Profile.cancelProfileRefresh(self) end,
        showProfile=function(self) return Profile.showProfile(self) end,
        refreshProfile=function(self,...) return Profile.refreshProfile(self,...) end,
        closeWeReadUI=function(self) Request.cancel(self);Profile.cancelProfileRefresh(self);self.discovery_epoch=(self.discovery_epoch or 0)+1 end}
    host.native_renewal={start=function(_self,options,callback)
        assert(options.expected_revision==state.revision);state.revision=state.revision+1;state.pending=true;state.renewals=state.renewals+1
        state.renew=function(success)
            if success then
                state.credentials={vid="900000",accessToken="synthetic-new",refreshToken="synthetic-refresh",deviceId=string.rep("1",32)}
                state.pending=false;state.revision=state.revision+1
            end
            callback(success)
        end
        return true,{}
    end,cancel=function() end}
    return {state=state,host=host,
        schedule=function() while #scheduled>0 do table.remove(scheduled,1)() end end,
        tick=function() local job=assert(table.remove(queue,1));job.callback(job.task()) end,
        queued=function() return #queue end}
end
local f=fixture()
f.host:loadReadStats("monthly");f.schedule()
expect(f.state.native==0 and f.queued()==1 and f.host.busy_message,"statistics HTTP escaped worker")
f.tick()
local first=f.host._read_stats_view
expect(first and first.data.source_kind=="native" and f.state.writes==1 and not f.host.busy_message,"keyless native statistics not displayed/cached")
f.state.online=false
f.host:loadReadStats("monthly")
expect(f.host._read_stats_view.data.cached and f.state.native==1,"offline period did not use scoped cache")
local cached=f.host._read_stats_view
f.host:loadReadStats("annually")
expect(f.host._read_stats_view==cached and f.state.offline,"uncached period replaced visible statistics")
f.state.owner="b";f.host:loadReadStats("monthly")
expect(f.host._read_stats_view==cached and not f.state.cache.b,"offline cache crossed accounts")
f=fixture();f.host:loadReadStats("monthly");f.schedule();f.state.cancel();f.tick()
expect(f.state.writes==0 and not f.host._read_stats_view and not f.host.busy_message,"cancelled statistics applied late response")
f=fixture();f.host:loadReadStats("monthly");f.schedule();f.state.key="changed-key";f.tick()
expect(f.state.writes==0 and not f.host._read_stats_view,"changed credentials applied statistics")
f=fixture();f.host:loadReadStats("monthly");f.schedule();f.state.owner="b";f.tick()
expect(f.state.writes==0 and not f.host._read_stats_view,"late result crossed owner")
f=fixture();f.host:loadReadStats("monthly");f.schedule();f.tick();first=f.host._read_stats_view
f.host:loadReadStats("weekly",nil,first);f.schedule()
local busy=f.host.busy_message
expect(not f.host:loadReadStats("overall",nil,{}) and f.host.busy_message==busy,"stale tab cancelled current request")
f.tick();expect(f.host._read_stats_view.data.mode=="weekly","latest statistics mode lost")
f=fixture();f.state.codes={401};f.host:loadReadStats("monthly");f.schedule();f.tick()
expect(f.state.pending and f.state.renewals==1 and f.host.statistics_request.renewing,"statistics 401 did not own renewal")
f.state.renew(true);f.tick()
expect(f.host._read_stats_view.data.source_kind=="native" and f.state.native==2 and f.state.gateway==0,"renewed statistics did not retry original native request")
f=fixture();f.state.key="synthetic-key";f.state.codes={401};f.host:loadReadStats("monthly");f.schedule();f.tick();f.state.renew(false);f.tick()
expect(f.host._read_stats_view.data.source_kind=="gateway" and f.state.pending and f.state.renewals==1,"unconfirmed renewal lost pending state or standard fallback")
f=fixture();f.state.codes={429};f.host:loadReadStats("monthly");f.schedule();f.tick()
expect(f.state.renewals==0 and f.state.gateway==0 and f.state.writes==0,"rate limiting renewed or cached false data")
f=fixture();f.state.save_ok=false;f.host:loadReadStats("monthly");f.schedule();f.tick()
expect(f.host._read_stats_view and not f.host._read_stats_view.data.cached and f.state.writes==0 and f.state.info,"cache failure discarded successful fetched data")
f=fixture();f.host:showProfile()
expect(f.host.profile_request and f.queued()==1,"keyless native profile did not refresh automatically")
f.tick()
expect(f.host._profile_view.data.has_data and f.state.cache.a.statistics.source_kind=="native" and not f.host.profile_request,"native profile did not persist/show calendar")
f=fixture();f.state.codes={401};f.host:showProfile();f.tick()
expect(f.state.renewals==1 and f.host.profile_request.renewing,"profile 401 did not renew")
f.state.renew(true);f.tick()
expect(f.host._profile_view.data.has_data and f.state.native==2,"profile did not refetch whole snapshot after renewal")
f=fixture();f.state.valid=false
f.host.qr_login={start=function() f.state.scan_started=true end}
f.host.showTransientInfo=function() f.state.login_hint=true end
f.host:loadReadStats("monthly")
expect(f.state.login_hint and not f.state.scan_started and not f.host.busy_message and f.queued()==0,
    "invalid login started statistics instead of showing QR guidance")
table.remove(login_tasks,1)()
expect(f.state.scan_started,"statistics login guidance did not start QR login")
f.state.scan_started=false
f.host:refreshProfile(true)
expect(#login_tasks==0 and not f.state.scan_started,"automatic profile refresh prompted login")
f.host:refreshProfile(false)
table.remove(login_tasks,1)()
expect(f.state.scan_started,"manual profile refresh did not start QR login")
f.state.scan_started=false;f.state.owner=nil
Profile.showReadingGoal(f.host)
table.remove(login_tasks,1)()
expect(f.state.scan_started and f.state.writes==0,"anonymous goal input bypassed login")
print("PASS: "..checks.." native statistics/profile worker/cache/owner/renewal checks")
