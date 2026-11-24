package.path='./?.lua;'..package.path
package.loaded['ui/uimanager']={}
package.loaded['weread.lib.plugin_util']={tr=function(value) return value end,
    T=function(value,arg) return (value:gsub('%%1',function() return tostring(arg) end)) end}
package.loaded['weread.lib.crypto']={sha256_hex=function(value)
    assert(value=='weread-library:900001');return string.rep('a',64)
end}
local access_ok=true
local selected={scope={vid='900001',epoch=1},credentials={accessToken='private'},revision=4,store={}}
package.loaded['weread.lib.native_read_access']={capture=function() return selected end,
    matches=function() return access_ok end}
local reads,last_recover=0,nil
package.loaded['weread.lib.reading_state_cache']={new=function(_self,library,account)
    return {read=function() return library.state.cache end,write=function(_cache,id,value,expected)
        assert(id=='42' and account==library.state.account and expected==library.state.cache)
        library.state.saved=value;return true
    end}
end}
package.loaded['weread.lib.reading_state']={id=function(id) return id=='42' and id or nil end,
    read=function(_client,_settings,token,id,options)
        assert(token==selected and id=='42');reads=reads+1;last_recover=options.recover_auth;return {kind='known',started=false}
    end}
local jobs={}
package.loaded['weread.lib.memory_worker']={new=function()
    local worker={}
    function worker:start(task,done) self.task,self.done=task,done;jobs[#jobs+1]=self;return true end
    function worker:cancel() self.cancelled=true end
    return worker
end}
local Reading=require('weread.ui.reading_state')
local function fixture()
    local state={account=string.rep('a',20),notices={},offline=0,online=true}
    local host={settings={auth_scope_matches=function(_self,scope) return scope.vid==selected.scope.vid and scope.epoch==selected.scope.epoch end},client={},_reader_session_gen=1,discovery_epoch=1,ui={document={}},
        _book_detail_view={},_shelf_state_menu={},library_db={state=state,accountKey=function() return state.account end},
        isNetworkOnline=function() return state.online end,
        showOffline=function() state.offline=state.offline+1 end,
        showInfo=function(_self,message) state.notices[#state.notices+1]=message end,
        showBusy=function(self,_text,cancel) self.busy_message={cancel=cancel} end,
        closeBusy=function(self) self.busy_message=nil end}
    return host,state
end
local function open(host)
    assert(Reading.open(host,'42',host._shelf_state_menu));return jobs[#jobs]
end
local host,state=fixture();local job=open(host)
local value=job.task();assert(reads==1 and value.kind=='known')
job.done(value)
assert(job.cancelled and not host._reading_state_ui and not host.busy_message)
assert(#state.notices==1 and state.notices[1]:find('has not marked',1,true) and state.saved==false)
job.done({kind='known',started=true});assert(#state.notices==1,'duplicate callback rendered')
host,state=fixture();job=open(host);job.done({kind='known',started=true})
assert(state.notices[1]=='WeRead records this book as started.')
host,state=fixture();job=open(host);job.done({kind='missing'})
assert(state.notices[1]=='WeRead did not provide a started-reading status for this book.' and state.saved=='missing')
host,state=fixture();job=open(host);job.done({kind='known',started='false'})
assert(state.notices[1]=='Could not check started-reading status.')
for _,change in ipairs({'account','epoch','session','document','parent','menu','access'}) do
    host,state=fixture();access_ok=true;job=open(host)
    if change=='account' then state.account='foreign'
    elseif change=='epoch' then host.discovery_epoch=2
    elseif change=='session' then host._reader_session_gen=2
    elseif change=='document' then host.ui.document={}
    elseif change=='parent' then host._book_detail_view={}
    elseif change=='menu' then host._shelf_state_menu={}
    else access_ok=false end
    job.done({kind='known',started=true})
    assert(#state.notices==0 and state.saved==nil and not host._reading_state_ui and not host.busy_message,change..' exposed stale result')
end
access_ok=true;host,state=fixture();local old=open(host);local new=open(host)
assert(old.cancelled and not new.cancelled)
old.done({kind='known',started=true})
assert(not new.cancelled and host._reading_state_ui,'old callback cancelled newer request')
new.done({kind='known',started=false});assert(#state.notices==1)
host,state=fixture();job=open(host);host.busy_message.cancel()
assert(job.cancelled and not host._reading_state_ui and not host.busy_message)
job.done({kind='known',started=true});assert(#state.notices==0,'cancelled task rendered')
host,state=fixture();state.online=false
assert(not Reading.open(host,'42',host._shelf_state_menu) and state.offline==1,'offline request started')
host,state=fixture();state.online=false;state.cache={started=true,checked_at=1234}
assert(Reading.open(host,'42',host._shelf_state_menu) and state.offline==0
    and state.notices[1]:find('marked as started',1,true) and state.notices[1]:find('out of date',1,true))
host,state=fixture();state.online=false;state.cache={started=false,checked_at=1234}
assert(Reading.open(host,'42',host._shelf_state_menu) and state.notices[1]:find('not marked as started',1,true))
host,state=fixture();state.online=false;state.cache={started='missing',checked_at=1234}
assert(Reading.open(host,'42',host._shelf_state_menu) and state.notices[1]:find('did not provide',1,true))
host,state=fixture();host._reading_state_change_ui={}
assert(not Reading.open(host,'42',host._shelf_state_menu) and state.notices[1]:find('Wait',1,true))
host,state=fixture();state.account='foreign'
assert(not Reading.open(host,'42',host._shelf_state_menu) and #state.notices==1,'foreign account accepted')
local function renewal_fixture()
    selected={scope={vid='900001',epoch=1},credentials={accessToken='private',refreshToken='refresh',deviceId='device'},revision=4,store={}}
    local h,s=fixture();local service={}
    function service:start(options,callback) assert(options.expected_revision==4);self.callback=callback;self.count=(self.count or 0)+1;return true,{} end
    function service:cancel() self.cancelled=true end
    h.native_renewal=service
    return h,s,service
end
local service
host,state,service=renewal_fixture();job=open(host)
job.task();assert(last_recover==true)
local first_done=job.done;first_done({kind='native_expired'})
assert(service.count==1 and host._reading_state_ui and host.busy_message)
first_done({kind='known',started=true});assert(#state.notices==0,'duplicate expired request changed UI')
selected={scope=selected.scope,credentials={accessToken='renewed',refreshToken='new',deviceId='device'},revision=6,store=selected.store}
service.callback(true);assert(job.done~=first_done and host._reading_state_ui)
job.task();assert(last_recover==false,'renewed request allowed another recovery')
first_done({kind='known',started=true});assert(#state.notices==0,'old result superseded renewal')
job.done({kind='known',started=false});assert(state.saved==false and #state.notices==1 and not host._reading_state_ui)
host,state,service=renewal_fixture();job=open(host);job.done({kind='native_expired'});service.callback(false)
assert(service.count==1 and #state.notices==1 and state.notices[1]:find('Authorize',1,true) and not state.saved)
host,state,service=renewal_fixture();job=open(host);job.done({kind='native_expired'})
selected={scope=selected.scope,credentials={accessToken='renewed',refreshToken='new',deviceId='device'},revision=6,store=selected.store}
service.callback(true);job.done({kind='native_expired'})
assert(service.count==1 and #state.notices==1 and state.notices[1]:find('Authorize',1,true))
host,state,service=renewal_fixture();job=open(host);job.done({kind='native_expired'});host.busy_message.cancel()
assert(service.cancelled and not host._reading_state_ui);service.callback(false)
assert(#state.notices==0 and not state.saved,'cancelled renewal delivered result')
host,state,service=renewal_fixture();job=open(host);job.done({kind='native_expired'});state.account='other';service.callback(false)
assert(not host._reading_state_ui and #state.notices==0 and not state.saved,'account switch delivered renewal')
print('PASS: started-reading menu ownership and cancellation')
