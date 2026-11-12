package.path='./?.lua;./?/init.lua;'..package.path
local H=require('spec.helpers.annotation_test_store')
package.preload['lua-ljsqlite3/init']=function() return {open=H.connect} end
local shown={};local UI={show=function(_self,w) shown[#shown+1]=w end,close=function(_self,w) if w.close_callback then w.close_callback() end end}
package.preload['ui/uimanager']=function() return UI end
package.preload['weread.lib.plugin_util']=function() return {tr=function(x) return x end,T=function(pattern,...)
    local args={...};return (pattern:gsub('%%(%d+)',function(n) return tostring(args[tonumber(n)]) end)) end} end
package.preload['ui/widget/buttondialog']=function() return {new=function(_self,x) return x end} end
local Ledger=require('weread.lib.offline_time_store')
local Coverage=require('weread.lib.readtime_coverage')
local Review=require('weread.ui.offline_time_review')
local C=require('weread.lib.readtime_transfer_contract')
local checks=0;local function eq(a,b) checks=checks+1;assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local account=string.rep('a',20);local root=os.tmpname()..'-time-review';assert(os.execute('mkdir -p '..string.format('%q',root))==0)
local ledger=Ledger:new(root);local coverage=Coverage:new(root,function() return 100 end);assert(coverage:initialize())
local window=assert(ledger:begin(account,{book_id='42',stats_book=1,start_time=100,time_zone='+08:00',book_version=7,
    file_id=string.rep('f',64),version_source='epub_snapshot'}))
assert(ledger:collect(account,window,{{page='1',start_time=100,duration=1500}},1600,true))
local original=C.digest(assert(ledger:pending(account)))
for _i,key in ipairs({'claim_parts','finish','recover','release_unsent','settle_confirmed','mark_unknown'}) do ledger[key]=function() error('unexpected ledger mutation') end end
coverage.reserve=function() error('unexpected outgoing reservation') end
local owner,epoch,session,document=account,0,1,{}
local host={settings={data_dir=root,get_auth_scope=function() return {epoch=epoch} end,auth_scope_matches=function(_self,scope) return scope.epoch==epoch end},
    discovery_epoch=0,_reader_session_gen=session,ui={document=document},readtime_coverage=coverage,
    library_db={accountKey=function() return owner end,getBook=function() return {title='合成书籍 '..string.rep('很长的标题',30)} end},
    client={request=function() error('unexpected HTTP') end},offline_time={store=ledger,state='disabled',update=function() end}}
function host:closeWeReadUI() Review.close(self);self.discovery_epoch=self.discovery_epoch+1 end
function host:showBusy(text,cancel) self.busy_message={text=text,cancel=cancel} end
function host:closeBusy() self.busy_message=nil end
function host:showInfo(text) self.info=text end
function host:showList(title,items) return {title=title,item_table=items} end
local jobs={};host.offline_time_review_worker={start=function(self,task,callback)
    local job={task=task,callback=callback};jobs[#jobs+1]=job;self.job=job;return true
end,cancel=function(self) self.job=nil end}
local function deliver(index)
    local job=jobs[index or #jobs];local ok,value=pcall(job.task)
    job.callback(ok and value or {error='worker_failed'})
end
local function choose(label)
    for _i,item in ipairs(assert(host._offline_time_menu).item_table) do if item.text==label then return item.callback() end end
    error('missing menu row: '..label)
end
Review.show(host);eq(host._offline_time_menu,nil);eq(host.busy_message~=nil,true);deliver()
eq(host._offline_time_menu.title,'Offline reading time');choose('Pending local records');deliver()
eq(#host._offline_time_menu.item_table,22);choose('Next batch');deliver()
eq(#host._offline_time_menu.item_table,7);choose('Previous batch');deliver()
eq(host._offline_time_menu.item_table[1].text:match('^%d%d%d%d%-%d%d%-%d%d')~=nil,true)
eq(host._offline_time_menu.item_table[1].text~=host._offline_time_menu.item_table[2].text,true)
local menu=host._offline_time_menu;local open=menu.item_table[1].callback;open();deliver()
eq(host._offline_time_detail.title:find('Captured download source is available',1,true)~=nil,true)
eq(host._offline_time_detail.title:find('+08:00',1,true)~=nil,true)
host._offline_time_detail.buttons[1][1].callback();deliver();eq(host._offline_time_menu.title,'Pending local records')
choose('Offline reading time');deliver();choose('Check saved time');deliver()
eq(host._offline_time_detail.title:find('Local duplicate check: 600 s',1,true)~=nil,true)
eq(C.digest(ledger:pending(account)),original)
-- Busy dismissal and all late results leave newer views untouched.
host._offline_time_detail.buttons[1][1].callback();local old=#jobs
host.busy_message.cancel();eq(host._offline_time_review,nil);deliver(old);eq(host._offline_time_menu,nil)
Review.show(host);local first=#jobs;Review.show(host);local second=#jobs
deliver(first);eq(host.busy_message~=nil,true);deliver(second);eq(host._offline_time_menu~=nil,true)
open();eq(host._offline_time_menu.title,'Offline reading time') -- stale first-page callback
-- Account, same-account auth, document and reader session changes cancel local results.
for _i,change in ipairs({'account','auth','document','session'}) do
    Review.show(host);local job=#jobs
    if change=='account' then owner=string.rep('b',20)
    elseif change=='auth' then epoch=epoch+1
    elseif change=='document' then host.ui.document={}
    else host._reader_session_gen=host._reader_session_gen+1 end
    deliver(job);eq(host._offline_time_review,nil);eq(host.busy_message,nil);eq(host._offline_time_menu,nil)
    owner=account;host.ui.document=document;host._reader_session_gen=session
end
-- Malformed/failed background reads keep original records, and no busy dialog leaks.
Review.show(host);jobs[#jobs].callback({error='worker_failed'});eq(host._offline_time_review,nil);eq(host.busy_message,nil)
eq(host.info,'Could not read saved time. The records are kept.')
Review.show(host);jobs[#jobs].callback({summary={}});eq(host._offline_time_review,nil);eq(host.busy_message,nil)
Review.show(host);deliver();host._offline_time_menu.close_callback();eq(host._offline_time_review,nil)
Review.show(host);deliver();choose('Check saved time');deliver()
local dismissed=host._offline_time_detail;dismissed.tap_close_callback()
eq(host._offline_time_review,nil);eq(host._offline_time_detail,nil)
dismissed.buttons[1][1].callback();eq(host.busy_message,nil)
eq(C.digest(ledger:pending(account)),original);eq(ledger:summary(account).pending,1500)
Review.close(host);os.execute('rm -rf '..string.format('%q',root))
print('offline_time_review_ui_spec: '..checks..' checks')
