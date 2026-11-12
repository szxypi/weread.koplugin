package.path='./?.lua;./?/init.lua;'..package.path
local checks=0
local function expect(v,m) checks=checks+1;assert(v,m) end
local captures,writes,account,offline,read_query,read_cursor,available=0,0,'a',true,nil,nil,true
local closed=0
package.preload['ui/uimanager']=function() return {close=function() closed=closed+1 end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(s) return s end} end
package.preload['weread.lib.discovery_cache']=function() return {new=function() return {
    read=function(_self,query,cursor)
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
    isNetworkOnline=function() return not offline end,
    showBookstore=function() rendered=rendered+1 end,showInfo=function(_self,text) message=text end,
    runOnlineTask=function(_self,_label,fn) started=started+1;fn();return true end,
    discovery_worker={start=function(_self,fn,done) task=fn;callback=done;return true end,cancel=function() end}}
host._book_detail_view={}
Request.load(host,'search','三体',0)
expect(closed==1 and not host._book_detail_view,'offline batch retained detail overlay')
expect(captures==0 and started==0 and rendered==1 and read_query.keyword=='三体','offline search required auth/network')
local saved=host.discovery_state
Request.load(host,'search','三体',20,false,false,saved)
expect(read_cursor==20 and rendered==2 and captures==0,'offline next batch')
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
local old={account='other'};local before=captures
Request.load(host,'recommend',nil,0,false,false,old)
expect(captures==before,'stale cached widget started request')
print('discovery_offline_spec: '..checks..' checks')
