package.path='./?.lua;./?/init.lua;'..package.path
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local account,epoch,auth,reason='a',1,{vid='a',epoch=1},'native_required'
local fetches,rendered,notices,captures=0,0,0,0
local task,callback,request
package.preload['weread.lib.discovery_source']=function() return {
    capture=function() captures=captures+1;return nil,reason end,
    matches=function() return false end,
    fetch=function(_client,query)
        request=query;fetches=fetches+1
        return {books={{bookId='900001'}},next_cursor=query.cursor+20,has_more=true,
            source_kind='public',source_revision='public'}
    end,
} end
package.preload['ui/uimanager']=function() return {close=function() end,scheduleIn=function() end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(value) return value end} end
local Controller=require('weread.ui.discovery_request')
local host={client={},settings={
    get=function(_self,key,default) if key=='auth_epoch' then return epoch end return default end,
    get_auth_scope=function() return auth end,
    auth_scope_matches=function(_self,scope) return auth==scope end,
},library_db={accountKey=function() return account end},runOnlineTask=function(_self,_label,run) run();return true end,
    showBookstore=function() rendered=rendered+1 end,showInfo=function() notices=notices+1 end,
    discovery_worker={start=function(_self,work,done) task=work;callback=done;return true end,cancel=function() end}}
local function load(cursor,refresh,context) Controller.load(host,'search','term',cursor,false,refresh,context) end
local function complete() callback(task()) end
account=nil;auth=nil;reason='login_required'
load(0);expect(host.discovery_loading and captures==1,'guest did not select public search')
complete();expect(request.source_kind=='public' and request.cursor==0 and rendered==1,'guest first page failed')
local page=host.discovery_state
load(20,false,page);complete()
expect(request.source_kind=='public' and host.discovery_state.history[1]==0,'public continuation lost its source or history')
page=host.discovery_state;load(20,true,page);complete()
expect(request.source_kind=='public' and request.cursor==0 and #host.discovery_state.history==0,'refresh changed public source')
account='a';auth={vid='a',epoch=1};reason='native_required'
local before=captures
load(0,false,{public_search=true});complete()
expect(captures==before and request.source_kind=='public','explicit public search consulted authorization')
page=host.discovery_state;load(0,false,{public_search=true});local late=task();account='b';callback(late)
expect(host.discovery_state==page and not host.discovery_loading,'late result crossed account boundary')
account='a';load(0,false,{public_search=true});late=task();auth={vid='a',epoch=2};callback(late)
expect(host.discovery_state==page and not host.discovery_loading,'late result crossed login boundary')
auth={vid='a',epoch=1};local old_fetches=fetches
load(20,false,{source_kind='native',source_revision=1})
expect(fetches==old_fetches and not host.discovery_loading,'native continuation changed source')
reason='login_required';old_fetches=fetches
load(0);expect(fetches==old_fetches and not host.discovery_loading,'stale logged-in account used guest fallback')
reason='native_required';load(0,false,{public_search=true});callback({ok=false})
expect(host.discovery_state==page and notices>0,'failure replaced existing results')
print('discovery_public_search_spec: '..checks..' checks')
