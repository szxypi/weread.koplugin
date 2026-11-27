package.path='./?.lua;./?/init.lua;'..package.path
local checks=0
local function expect(v,m) checks=checks+1;assert(v,m) end
local captures,writes,account,offline,read_query,read_cursor,available=0,0,'a',true,nil,nil,true
local closed,reads=0,0
package.preload['ui/uimanager']=function() return {close=function() closed=closed+1 end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(s) return s end} end
package.preload['weread.lib.discovery_cache']=function() return {new=function() return {
    read=function(_self,query,cursor)
        reads=reads+1
        read_query,read_cursor=query,cursor
        if available then return {kind=query and query.kind or 'recommend',cursor=cursor or 0,cached=true,books={}} end
    end,
    write=function() writes=writes+1;return string.rep('a',32) end,
} end} end
package.preload['weread.lib.discovery_source']=function() return {
    capture=function() captures=captures+1;return {revision='new'} end,matches=function() return true end,
    fetch=function(_client,request)
        expect(request.cursor==0 and not request.session_id and not request.source_revision,'refresh reused saved remote session')
        return {books={},next_cursor=0,has_more=false,source_kind='native',source_revision='new'}
    end,
} end
local Request=require('weread.ui.discovery_request')
local task,callback,message,rendered,started=nil,nil,nil,0,0
local host={library_db={accountKey=function() return account end},settings={},client={},
    isNetworkConnected=function() return not offline end,
    isNetworkOnline=function() error('bookstore requested DNS on the UI thread') end,
    showBookstore=function() rendered=rendered+1 end,showInfo=function(_self,text) message=text end,
    runOnlineTask=function(_self,_label,fn,_delay,options)
        assert(options.link_only and options.silent_offline)
        started=started+1;fn();return true
    end,
    discovery_worker={start=function(_self,fn,done) task=fn;callback=done;return true end,cancel=function() end}}
host._book_detail_view={}
Request.load(host,'search','三体',0)
expect(closed==1 and not host._book_detail_view,'offline batch retained detail overlay')
expect(captures==0 and started==0 and rendered==1 and read_query.keyword=='三体','offline search required auth/network')
local saved=host.discovery_state
Request.load(host,'search','三体',20,false,false,saved)
expect(read_cursor==20 and rendered==2 and captures==0,'offline next batch')
saved=host.discovery_state
local before_refresh=reads
Request.load(host,'search','三体',20,false,true,saved)
expect(host.discovery_state==saved and reads==before_refresh and captures==0 and rendered==2
    and message:find('Connect to Wi-Fi to refresh',1,true),'offline refresh reset the visible batch')
available=false;saved=host.discovery_state
Request.load(host,'search','三体',40,false,false,saved)
expect(host.discovery_state==saved and message:find('No saved books',1,true) and captures==0,'missing cache replaced current batch')
offline=false;available=true
Request.load(host,'search','三体',0,false,false,saved)
expect(captures==0 and rendered==3,'online navigation reused remote session of saved batch')
saved=host.discovery_state
Request.load(host,'search','三体',20,false,true,saved)
expect(captures==1 and started==1,'explicit refresh did not return to network')
callback(task())
expect(writes==1 and host.discovery_state._cache_generation and not host.discovery_state.cached,'fresh result not saved')
local live=host.discovery_state
Request.load(host,'search','三体',0);local result=task();account='b';callback(result)
expect(writes==1 and host.discovery_state==live,'late account result saved cache')
account='a'
Request.load(host,'search','三体',0);result=task();Request.cancel(host);callback(result)
expect(writes==1,'cancelled result saved cache')
Request.load(host,'search','三体',0);callback({ok=false})
expect(host.discovery_state==live and captures==4,'failed refresh discarded current batch')
host.discovery_state=nil
Request.load(host,'search','三体',0);callback({ok=false})
expect(host.discovery_state.cached and captures==5 and message:find('Cached books',1,true),'initial failure did not open matching saved batch')
local earlier_query=host.discovery_state
Request.load(host,'search','新词',0);callback({ok=false})
expect(host.discovery_state~=earlier_query and host.discovery_state.cached and read_query.keyword=='新词' and read_cursor==0,
    'failed new search did not restore its own saved results')
local cached=host.discovery_state
Request.load(host,'search','限流',0);callback({ok=false,rate_limited=true})
expect(host.discovery_state==cached and message:find('requests are limited',1,true),
    'rate limiting switched the current list or omitted the notice')
available=false
Request.load(host,'search','无缓存',0);callback({ok=false})
expect(host.discovery_state==cached,'missing cache replaced the visible query on network failure')
available=true
local later={kind='search',keyword='现有列表',account='a',source_kind='native',cursor=20,history={0},books={}}
host.discovery_state=later
before_refresh=reads
Request.load(host,'search',later.keyword,20,false,true,later);callback({ok=false})
expect(host.discovery_state==later and reads==before_refresh and message:find('Cached books',1,true),
    'failed explicit refresh replaced the active batch from storage')
host.runOnlineTask=function() return false end
Request.load(host,'search',later.keyword,20,false,true,later)
expect(host.discovery_state==later and reads==before_refresh and not host.discovery_loading
    and message:find('Connect to Wi-Fi to refresh',1,true),'link loss while starting refresh replaced the active batch')
Request.load(host,'search','断网',0)
expect(not host.discovery_loading and host.discovery_state.cached and read_query.keyword=='断网',
    'link loss before background scheduling did not reopen the saved search')
local old={account='other'};local before=captures
Request.load(host,'recommend',nil,0,false,false,old)
expect(captures==before,'stale cached widget started request')
print('discovery_offline_spec: '..checks..' checks')
