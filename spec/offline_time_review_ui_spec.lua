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
eq(host._offline_time_detail.buttons[3][1].text,'Skip this book for now')
host._offline_time_detail.buttons[3][1].callback();deliver()
eq(host._offline_time_detail.title:find('No locally verified time',1,true)~=nil,true)
eq(host._offline_time_detail.buttons[2][1].text,'Why some time was not selected')
host._offline_time_detail.buttons[2][1].callback()
eq(host._offline_time_detail.title:find('Books skipped in this session: 1500 s',1,true)~=nil,true)
host._offline_time_detail.buttons[1][1].callback();deliver()
eq(host._offline_time_detail.title:find('No locally verified time',1,true)~=nil,true)
eq(C.digest(ledger:pending(account)),original)
-- Scan reasons are descriptive only; opening details neither claims nor sends.
Review.show(host);deliver();choose('Check saved time')
jobs[#jobs].callback({selection=false,report={scanned=8,scan_complete=true,unsupported=1,conflicting=2,covered=3,untracked=4,
    deferred=18,deferred_today=5,deferred_zone=6,deferred_other_day=7,skipped=8}})
host._offline_time_detail.buttons[2][1].callback();local details=host._offline_time_detail.title
for _,label in ipairs({'Today in Beijing time: 5 s','Other time zones, not yet transferable: 6 s',
    'Other historical dates, for a later batch: 7 s','Source or time needs verification: 1 s','Before coverage tracking began: 4 s',
    'Reserved for other reports: 3 s','Overlapping local records: 2 s','Books skipped in this session: 8 s'}) do
    eq(details:find(label,1,true)~=nil,true)
end
eq(C.digest(ledger:pending(account)),original)
Review.show(host);deliver();choose('Check saved time')
jobs[#jobs].callback({selection=false,report={scanned=0,scan_complete=true,unsupported=0,conflicting=0,covered=0,untracked=0,
    deferred=1,deferred_today=0,deferred_zone=0,deferred_other_day=0,skipped=0}})
eq(host._offline_time_review,nil);eq(host.info,'Could not read saved time. The records are kept.')
Review.show(host);deliver();choose('Check saved time');deliver()
eq(host._offline_time_detail.title:find('Local duplicate check: 600 s',1,true)~=nil,true)
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
-- The explicit submit button passes the displayed immutable selection only.
local Json=require('json')
host.client.json_encode=function(_s,x) return Json.encode(x) end
host.client.json_decode=function(_s,x) return Json.decode(x) end
host.isNetworkConnected=function() return true end
host.settings.get_book=function() return {cached_file='/synthetic/book.epub',chapters={{chapterUid=7,chapterIdx=0}}} end
local dispatched
-- The normal UI creates a service that supports verified imported-book batches.
local saved_service_module=package.loaded['weread.lib.readtime_transfer_service']
local service_options
package.loaded['weread.lib.readtime_transfer_service']={new=function(_self,options)
    service_options=options
    return {start=function(_service,mode,scope,input,refs,guard,callback)
        dispatched={mode=mode,scope=scope,input=input,refs=refs,guard=guard,callback=callback};return true
    end,cancel=function() end}
end}
host.offline_time_transfer_service=nil
Review.show(host);deliver();choose('Check saved time');deliver()
host._offline_time_detail.buttons[2][1].callback()
eq(service_options.task_options.experimental_cb,true);eq(dispatched.mode,'send')
dispatched.callback({kind='unconfirmed'});Review.close(host)
host.offline_time_transfer_service=nil
package.loaded['weread.lib.readtime_transfer_service']=saved_service_module
host.offline_time_transfer_service={start=function(_self,mode,scope,input,refs,guard,callback)
    dispatched={mode=mode,scope=scope,input=input,refs=refs,guard=guard,callback=callback};return true
end,cancel=function() end}
Review.show(host);deliver();choose('Check saved time');deliver()
local selected=host._offline_time_detail;eq(selected.buttons[2][1].text,'Transfer this batch')
selected.buttons[2][1].callback();eq(dispatched.mode,'send');eq(dispatched.scope,account);eq(dispatched.input.seconds,600)
eq(dispatched.guard(),true);eq(host.busy_message~=nil,true)
dispatched.callback({kind='unconfirmed'});eq(host.busy_message,nil)
eq(host._offline_time_detail.title,'Cloud accounting is not confirmed. The request is kept and will not be sent again.')
Review.show(host);deliver();choose('Check saved time');deliver()
host._offline_time_detail.buttons[2][1].callback();dispatched.callback({kind='unsupported_source'})
eq(host._offline_time_detail.title,'This imported book format cannot transfer saved time yet. Its records are kept.')
eq(C.digest(ledger:pending(account)),original)
-- Large catalogs are checked in bounded workers before the transfer service.
-- Cancelled or stale workers must not dispatch, nor close a newer view.
local source=require('weread.lib.readtime_source');local old_scan=source.scan_page
local many={};for i=1,160 do many[i]={chapterUid=i,chapterIdx=i-1} end
host.settings.get_book=function() return {cached_file='/synthetic/book.epub',chapters=many} end
local scan_calls=0
source.scan_page=function(_book,_chapters,selection,previous,cursor)
    scan_calls=scan_calls+1;eq(selection.file_id,string.rep('f',64));eq(previous,nil)
    if cursor<129 then return {kind='more',cursor=cursor+32} end
    return {kind='found',reference={file='/synthetic/book.epub',chapter_uid='1',chapter_idx=0}}
end
dispatched=nil;Review.show(host);deliver();choose('Check saved time');deliver()
host._offline_time_detail.buttons[2][1].callback();eq(dispatched,nil)
local first_scan=#jobs;deliver();local next_scan=#jobs
jobs[first_scan].callback({kind='more',cursor=33});eq(#jobs,next_scan)
for _i=1,4 do deliver() end
eq(scan_calls,5);eq(dispatched.mode,'send');eq(#dispatched.refs,1);eq(dispatched.refs[1].file,'/synthetic/book.epub')
jobs[#jobs].callback({kind='found',reference={file='/synthetic/book.epub',chapter_uid='1',chapter_idx=0}})
eq(dispatched.mode,'send')
dispatched.callback({kind='unconfirmed'});eq(C.digest(ledger:pending(account)),original)
dispatched=nil;Review.show(host);deliver();choose('Check saved time');deliver()
host._offline_time_detail.buttons[2][1].callback();local old_scan_job=#jobs
host.busy_message.cancel();Review.show(host);deliver();eq(host._offline_time_menu.title,'Offline reading time')
deliver(old_scan_job);eq(dispatched,nil);eq(host._offline_time_menu.title,'Offline reading time')
source.scan_page=function() return {kind='unavailable'} end
Review.show(host);deliver();choose('Check saved time');deliver()
host._offline_time_detail.buttons[2][1].callback();deliver()
eq(dispatched,nil);eq(host.info,'Download source needs verification');deliver()
eq(host._offline_time_menu.title,'Offline reading time');eq(C.digest(ledger:pending(account)),original)
source.scan_page=function() return {kind='more',cursor=33} end
Review.show(host);deliver();choose('Check saved time');deliver()
host._offline_time_detail.buttons[2][1].callback();owner=string.rep('b',20);deliver()
eq(host._offline_time_review,nil);eq(dispatched,nil);owner=account
source.scan_page=old_scan
host.settings.get_book=function() return {cached_file='/synthetic/book.epub',chapters={{chapterUid=7,chapterIdx=0}}} end
-- Saved ACK views offer GET-only verification and explicit uncertain retention.
local attempt='offtime-v1:'..string.rep('d',32)
assert(coverage:_access(function(db)
    local q=db:prepare('INSERT INTO offline_time_records(attempt,scope,phase,metadata,rows,request_hash,created,evidence) VALUES(?,?,?,?,?,?,?,?)')
    local row=assert(ledger:review_page(account,'pending',0,nil,1)).rows[1].source
    q:bind(attempt,account,'acknowledged',Json.encode{book_id='42',seconds=2,request_hash=string.rep('b',64),
        source={ref={file='/synthetic/book.epub',chapter_uid='1',chapter_idx=0}}},Json.encode{row},
        string.rep('b',64),100,Json.encode{request_hash=string.rep('b',64),ack_at=101}):step();q:close();return true
end))
Review.show(host);deliver();choose('Review unfinished transfer');deliver()
eq(host._offline_time_detail.title:find('Receipt saved;',1,true)~=nil,true)
eq(host._offline_time_detail.buttons[2][1].text,'Check cloud result without sending again')
eq(host._offline_time_detail.buttons[3][1].text,'Keep as uncertain and continue')
host._offline_time_detail.buttons[2][1].callback();eq(dispatched.mode,'resolve');eq(dispatched.input.attempt,attempt)
local late=dispatched.callback;host._reader_session_gen=session+1;late({kind='confirmed'})
eq(host._offline_time_review,nil);eq(host._offline_time_detail,nil);eq(host.busy_message,nil)
host._reader_session_gen=session;host.settings.get_book=function() return {chapters=many} end
source.scan_page=function(_book,_chapters,_selection,previous,cursor)
    eq(previous.ref.file,'/synthetic/book.epub');eq(cursor,1)
    return {kind='found',reference=previous.ref}
end
dispatched=nil;Review.show(host);deliver();choose('Review unfinished transfer');deliver()
host._offline_time_detail.buttons[2][1].callback();eq(dispatched,nil);deliver()
eq(dispatched.mode,'resolve');eq(dispatched.refs[1].file,'/synthetic/book.epub')
source.scan_page=old_scan
Review.close(host)
-- An unknown-version imported row is only a candidate, not a proven source.
local zero_dir=root..'/zero';assert(os.execute('mkdir -p '..string.format('%q',zero_dir))==0)
local zero_ledger=Ledger:new(zero_dir);local zero_coverage=Coverage:new(zero_dir,function() return 100 end)
assert(zero_coverage:initialize())
local zero_window=assert(zero_ledger:begin(account,{book_id='CB_Synthetic',stats_book=1,start_time=100,time_zone='+08:00',book_version=0,
    file_id=string.rep('e',64),version_source='epub_unknown'}))
assert(zero_ledger:collect(account,zero_window,{{page='1',start_time=100,duration=2}},102,true))
host.offline_time.store=zero_ledger;host.readtime_coverage=zero_coverage
Review.show(host);deliver();choose('Pending local records');deliver()
host._offline_time_menu.item_table[1].callback();deliver()
eq(host._offline_time_detail.title:find('Cached source will be checked before transfer',1,true)~=nil,true)
eq(zero_ledger:summary(account).pending,2)
Review.close(host)
-- Native chapter time reaches source discovery without ordinary book metadata.
local direct_dir=root..'/direct';assert(os.execute('mkdir -p '..string.format('%q',direct_dir))==0)
local direct_ledger=Ledger:new(direct_dir);local direct_coverage=Coverage:new(direct_dir,function() return 100 end)
assert(direct_coverage:initialize())
local direct_window=assert(direct_ledger:begin(account,{book_id='42',stats_book=1,start_time=100,time_zone='+08:00',book_version=7,
    file_id=string.rep('e',64),version_source='native_direct'}))
assert(direct_ledger:collect(account,direct_window,{{page='1',start_time=100,duration=2}},102,true))
host.offline_time.store=direct_ledger;host.readtime_coverage=direct_coverage
host.settings.get_book=function() error('native source must not require Web cache metadata') end
local direct=require('weread.lib.native_direct_readtime_source');local saved_direct_scan=direct.scan_page
local direct_ref={kind='native_direct',file='/synthetic/native.epub',chapter_uid='7',source_sha256=string.rep('b',64)}
local direct_scans=0
direct.scan_page=function(_settings,selected_account,_scope,selection,cursor,prior,current)
    direct_scans=direct_scans+1;eq(selected_account,account);eq(selection.native_direct,true);eq(current(),true)
    if cursor==1 then return {kind='more',cursor=33,prior={stamp='fixture'}} end
    eq(cursor,33);eq(prior.stamp,'fixture');return {kind='found',reference=direct_ref}
end
dispatched=nil;Review.show(host);deliver();choose('Check saved time');deliver()
host._offline_time_detail.buttons[2][1].callback();eq(dispatched,nil);deliver();eq(dispatched,nil);deliver()
eq(direct_scans,2);eq(dispatched.mode,'send');eq(dispatched.input.native_direct,true);eq(dispatched.refs[1].file,direct_ref.file)
dispatched.callback({kind='unconfirmed'});eq(direct_ledger:summary(account).pending,2)
direct.scan_page=saved_direct_scan
Review.close(host);os.execute('rm -rf '..string.format('%q',root))
print('offline_time_review_ui_spec: '..checks..' checks')
