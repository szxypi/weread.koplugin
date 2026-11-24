package.path='./?.lua;'..package.path
package.loaded['ui/uimanager']={}
package.loaded['weread.lib.plugin_util']={tr=function(value) return value end,
    T=function(value,arg) return (value:gsub('%%1',function() return tostring(arg) end)) end}
package.loaded['weread.lib.crypto']={sha256_hex=function(value)
    assert(value=='weread-library:900001');return string.rep('a',64)
end}
local access_ok=true
local selected={scope={vid='900001'},credentials={accessToken='private'}}
package.loaded['weread.lib.native_read_access']={capture=function() return selected end,
    matches=function() return access_ok end}
local reads=0
package.loaded['weread.lib.reading_state_cache']={new=function(_self,library,account)
    return {read=function() return library.state.cache end,write=function(_cache,id,value,expected)
        assert(id=='42' and account==library.state.account and expected==library.state.cache)
        library.state.saved=value;return true
    end}
end}
package.loaded['weread.lib.reading_state']={id=function(id) return id=='42' and id or nil end,
    read=function(_client,_settings,token,id)
        assert(token==selected and id=='42');reads=reads+1;return {kind='known',started=false}
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
    local host={settings={},client={},_reader_session_gen=1,discovery_epoch=1,ui={document={}},
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
print('PASS: started-reading menu ownership and cancellation')
