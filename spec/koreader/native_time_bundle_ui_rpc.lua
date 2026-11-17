-- Synthetic-only real ReaderUI -> time menu -> background task -> RPC gate.
-- All HTTP is blocked and task responses are synthetic in-memory fixtures.
require('ffi').log=function() end
require('setupkoenv')
require('ffi/posix_h')
local json=require('json')
local length=assert(io.stdin:read('*l'))
assert(length:match('^[1-9]%d*$') and tonumber(length)<=65536)
local input=json.decode(assert(io.stdin:read(tonumber(length))))
assert(input.owner=='900000' and input.book_id=='900001' and input.grant.vid=='900000'
    and input.grant.accessToken=='mock-native-access' and input.grant.refreshToken=='mock-native-refresh'
    and input.guest=='synthetic-guest' and input.config=='synthetic-config')
assert(input.mode=='success' or input.mode=='tamper_selection' or input.mode=='tamper_body' or input.mode=='lost_reply' or input.mode=='duplicate' or input.mode=='no_ack' or input.mode=='kill_worker' or input.mode=='no_delta')
assert(type(input.token)=='string' and #input.token==32 and input.token:match('^[a-f0-9]+$'))
assert(type(arg[1])=='string' and type(arg[2])=='string' and type(arg[3])=='string' and type(arg[4])=='string')
local worked,reason=pcall(function()
local home=assert(os.getenv('KO_HOME'));package.path=home..'/plugins/weread.koplugin/?.lua;'..arg[1]..'/?.lua;'..package.path
local function rpc(kind,extra)
    local value=extra or {};value.kind=kind
    io.stdout:write('\nWEREAD_NATIVE_THOUGHT_'..input.token..'_STEP='..json.encode(value)..'\n');io.stdout:flush()
    local reply=json.decode(assert(io.stdin:read('*l')))
    assert(reply.kind==kind and type(reply.ok)=='boolean')
    return reply.ok
end
local function blocked() error('synthetic_ui/network_disabled',0) end
local http=require('socket.http');http.request=blocked
local ok_https,https=pcall(require,'ssl.https');if ok_https then https.request=blocked end
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
G_reader_settings:saveSetting('language','zh_CN');require('gettext').changeLang('zh_CN')
G_reader_settings:saveSetting('color_rendering',false)
local Client=require('weread.lib.client');Client.request=blocked
local Device=require('device');require('document/canvascontext'):init(Device)
Device.screen.shot=blocked
local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
for _i,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
assert(#Loader.enabled_plugins==1)
package.path=home..'/plugins/weread.koplugin/?.lua;'..arg[1]..'/?.lua;'..package.path
local UI=require('ui/uimanager');local socket=require('socket')
UI:setRunForeverMode();UI:setInputTimeout(0)
local function flush() UI:shiftScheduledTasksBy(-1e9);UI:setInputTimeout(0);UI:handleInput() end
local function pump(predicate)
    local deadline=socket.gettime()+40
    while not predicate() do assert(socket.gettime()<deadline,'synthetic_ui/timeout');flush();socket.sleep(.02) end
end
local reader=require('apps/reader/readerui'):new{dimen=Device.screen:getSize(),
    document=require('document/documentregistry'):openDocument(arg[2])}
assert(reader and reader.weread and reader.document)
UI:show(reader);flush()
local host=reader.weread
host.settings:set('account',{user_vid=input.owner,name='Synthetic'})
host.settings:set('cookies',{wr_vid = input.owner,wr_skey='synthetic-current-cookie'})
host.settings:set('auth_epoch',1);host.settings:flush()
local account=assert(host.library_db:accountKey())
assert(account==require('weread.lib.native_position_contract').account_key(input.owner))
local Ledger=require('weread.lib.offline_time_store');local Coverage=require('weread.lib.readtime_coverage')
local ledger=Ledger:new(arg[3]);local coverage=Coverage:new(arg[3],function() return input.start_time end)
assert(coverage:initialize()==input.start_time)
local window=assert(ledger:begin(account,{book_id=input.book_id,stats_book=1,start_time=input.start_time,
    time_zone='+08:00',book_version=input.book_version,file_id=input.file_id,version_source='epub_snapshot'}))
local spans={};for i,row in ipairs(input.rows) do spans[i]={page=tostring(i),start_time=row.start_time,duration=row.duration} end
assert(ledger:collect(account,window,spans,input.ended_at,true).seconds==input.seconds)
local C=require('weread.lib.readtime_transfer_contract');assert(C.digest(assert(ledger:pending(account)))==C.digest(input.rows))
host.offline_time.store=ledger;host.readtime_coverage=coverage;host.offline_time.update=function() end
host.isNetworkConnected=function() return true end
local chapters={{chapterUid=input.chapter_uid,chapterIdx=input.chapter_idx}}
local get_book=host.settings.get_book
host.settings.get_book=function(settings,id)
    if id==input.book_id then return {cached_file=arg[4],chapters=chapters} end
    return get_book(settings,id)
end
local get_book_info=host.library_db.getBook
host.library_db.getBook=function(db,id)
    if id==input.book_id then return {title='Synthetic time record'} end
    return get_book_info(db,id)
end
local F=require('spec.helpers.thought_edit_fixture');local settings,credentials,state=F.access()
function settings:get(key,default) return key=='cookies' and {wr_vid = input.owner,wr_skey='synthetic-current-cookie'} or default end
function credentials:read() return input.grant,state.revision,nil,false end
local client={settings=settings,json_encode=function(_self,x) return json.encode(x) end,json_decode=function(_self,x) return json.decode(x) end}
local Journal=require('weread.lib.readtime_transfer_store')
local journal=Journal:new{coverage=coverage,ledger=ledger,codec=client}
local sqlite=require('lua-ljsqlite3/init');local source_db=sqlite.open(coverage.path)
source_db:exec('CREATE TABLE synthetic_source_calls(id INTEGER PRIMARY KEY)');source_db:close()
local A=require('weread.lib.readtime_accounting');local Stats=require('weread.lib.read_stats')
local captured_day=A.day(input.start_time);local captured_month=Stats.period_start('monthly',input.start_time)
local applied=false;local sent=0
local function progress()
    return {timestamp=os.time(),book={bookId=input.book_id,chapterUid=tonumber(input.chapter_uid),chapterIdx=input.chapter_idx,
        chapterOffset=10,progress=10,summary='Synthetic summary',readingTime=20+(applied and input.seconds or 0),recordReadingTime=0,ttsTime=0}}
end
function client:get_progress_snapshot(book,access)
    assert(book==input.book_id and access.cookies.wr_vid == input.owner);return progress()
end
local selected
function client:request(options)
    assert(options.skip_cookie and options.persist_response_cookies==false and options.sensitive
        and options.headers.vid==input.owner and options.headers.accessToken==input.grant.accessToken and not options.headers.Cookie)
    local value
    if options.method=='POST' then
        assert(options.url=='https://i.weread.qq.com/book/batchUploadProgress' and sent==0)
        assert(assert(journal:pending(account)).phase=='claimed','synthetic_ui/native_claim')
        local body=json.decode(options.body)
        if input.mode=='tamper_body' then body.books[1].summary='synthetic-change' end
        if not rpc('claim',{body=body,selection=selected}) then error('synthetic_ui/claim_denied',0) end
        sent=sent+1
        if input.mode=='lost_reply' then error('synthetic_ui/lost_reply',0) end
        if input.mode=='kill_worker' then os.exit(1) end
        if input.mode=='no_ack' then return json.encode({}),200 end
        if input.mode=='duplicate' and not rpc('claim',{body=body,selection=selected}) then error('synthetic_ui/duplicate_denied',0) end
        applied=input.mode~='no_delta';value={succ=1}
        assert(rpc('ack',{response=value}))
    elseif options.url:find('/book/info?',1,true) then value={bookId=input.book_id,bookVersion=input.book_version}
    elseif options.url:find('/book/getProgress?',1,true) then value=progress()
    elseif options.url:find('/shelf/sync',1,true) then value={books={{bookId=input.book_id,secret=0,finishReading=0}},archive={}}
    elseif options.url:find('/readdata/detail?',1,true) then
        local month=assert(tonumber(options.url:match('baseTime=(%d+)$')))
        value={baseTime=month,readTimes={},totalReadTime=0,readDays=0}
        if month==captured_month then value.readTimes[tostring(captured_day)]=5+(applied and input.seconds or 0);value.totalReadTime=5+(applied and input.seconds or 0);value.readDays=1 end
    elseif options.url:find('/config?',1,true) then value={token=input.config}
    elseif options.url:find('/feature?',1,true) then value={feature={guest_token=input.guest}}
    else error('synthetic_ui/route',0) end
    return json.encode(value),200
end
local service=require('weread.lib.readtime_transfer_service'):new{settings=settings,client=client,journal=journal,
    credentials=credentials,scheduler=UI,task_options={observe_source=function(observed_client,web,selection,refs,previous)
        assert(selection.file_id==input.file_id and #refs==1 and refs[1].file==arg[4])
        local db=sqlite.open(coverage.path);db:exec('INSERT INTO synthetic_source_calls DEFAULT VALUES');db:close()
        local Source=require('weread.lib.position_source');local Current=require('weread.lib.source_currentness')
        local key=Source.raw_path(input.raw_sha256)
        local members=assert(require('weread.lib.source_archive').read(arg[4],{[key]=Source.MAX_BYTES}))
        local raw=assert(members[key])
        return require('weread.lib.readtime_source').observe(observed_client,web,selection,refs,previous,
            {fetch=function(_client,expected,_web,format,options)
                assert(format=='web_xhtml')
                local catalog={{bookId=input.book_id,book={bookVersion=input.book_version},updated=chapters}}
                options.verify_catalog(catalog)
                return Current.project(expected,catalog,{book_id=input.book_id,psvts='synthetic-session'},raw,catalog)
            end})
    end,sleep=function() end},acquire=function(book)
        return require('weread.lib.readtime_transfer_lease').acquire(host,book,function() return host._offline_time_review~=nil end)
    end}
local start=service.start;local background=false;local task_results={}
function service:start(mode,scope,selection,refs,guard,callback)
    assert((mode=='send' or mode=='resolve' and input.mode=='no_delta') and scope==account)
    if mode=='send' then
        selected=selection
        local offered=selection
        if input.mode=='tamper_selection' then offered=json.decode(json.encode(selection));offered.file_id=string.rep('f',64) end
        if not rpc('selection',{selection=offered}) then return false,'unavailable' end
    end
    local started,why=start(self,mode,scope,selection,refs,guard,function(value)
        task_results[#task_results+1]=value;callback(value)
    end)
    if started then
        local worker=assert(self.worker and self.worker.job)
        assert(type(worker.pid)=='number' and worker.pid~=tonumber(require('ffi').C.getpid()))
        background=true
    end
    return started,why
end
host.offline_time_transfer_service=service
host:showOfflineTimeStatus();pump(function() return host._offline_time_menu~=nil end)
local label=require('weread.lib.i18n').tr('Check saved time');local chosen
for _i,item in ipairs(host._offline_time_menu.item_table) do if item.text==label then chosen=item;break end end
assert(chosen,'synthetic_ui/menu');host._offline_time_menu:onMenuSelect(chosen)
pump(function() return host._offline_time_detail~=nil end)
local detail=host._offline_time_detail;assert(#detail.buttons==2 and detail.buttons[2][1].callback)
detail.buttons[2][1].callback()
pump(function() return host._offline_time_detail~=nil and service.job==nil end)
local result_label=input.mode=='success' and 'This batch is independently confirmed in cloud reading time.'
    or input.mode=='tamper_selection' and 'Could not complete this operation. Saved records are kept.'
    or 'Cloud accounting is not confirmed. The request is kept and will not be sent again.'
assert(host._offline_time_detail.title==require('weread.lib.i18n').tr(result_label),'synthetic_ui/dialog')
local recovery_checked=false
if input.mode=='no_delta' then
    host._offline_time_detail.buttons[1][1].callback()
    pump(function() return host._offline_time_menu~=nil end)
    local review_label=require('weread.lib.i18n').tr('Review unfinished transfer');local review
    for _i,item in ipairs(host._offline_time_menu.item_table) do if item.text==review_label then review=item;break end end
    assert(review,'synthetic_ui/review_menu');host._offline_time_menu:onMenuSelect(review)
    pump(function() return host._offline_time_detail~=nil end)
    assert(host._offline_time_detail.title:find(require('weread.lib.i18n').tr('Receipt saved; cloud accounting still needs checking.'),1,true))
    assert(host._offline_time_detail.buttons[2][1].text==require('weread.lib.i18n').tr('Check cloud result without sending again'))
    host._offline_time_detail.buttons[2][1].callback()
    pump(function() return host._offline_time_detail~=nil and service.job==nil end)
    assert(host._offline_time_detail.title==require('weread.lib.i18n').tr('Cloud accounting is not confirmed. The request is kept and will not be sent again.'))
    recovery_checked=true
end
local summary=assert(ledger:summary(account));local pending=journal:pending(account)
local phase=pending and pending.phase or 'none'
local expected_phase=(input.mode=='success' or input.mode=='tamper_selection') and 'none' or input.mode=='no_ack' and 'unknown' or input.mode=='no_delta' and 'acknowledged' or 'claimed'
assert(phase==expected_phase,'synthetic_ui/pending')
assert(summary.confirmed==(input.mode=='success' and input.seconds or 0),'synthetic_ui/confirmed')
assert(summary.pending==(input.mode=='tamper_selection' and input.seconds or 0),'synthetic_ui/remaining')
assert(summary.in_flight==((input.mode~='success' and input.mode~='tamper_selection') and input.seconds or 0),'synthetic_ui/in_flight')
assert(not host._offline_time_transfer_lock and not service.job)
local count_db=sqlite.open(coverage.path);local count_query=count_db:prepare('SELECT COUNT(*) FROM synthetic_source_calls')
local source_reads=tonumber(assert(count_query:step())[1]);count_query:close();count_db:close()
assert(source_reads>=(input.mode=='tamper_selection' and 0 or (input.mode=='success' or input.mode=='no_delta') and 2 or 1))
if input.mode=='success' then
    assert(#task_results==1 and task_results[1].kind=='confirmed' and task_results[1].attempted==true
        and task_results[1].acknowledged==true and task_results[1].stable_reads==2 and task_results[1].readbacks>=2)
    local settled=assert(journal:get(account,task_results[1].attempt))
    assert(settled.phase=='settled' and settled.evidence and settled.evidence.audit
        and settled.evidence.audit.readbacks==2 and settled.evidence.audit.seconds==input.seconds)
elseif input.mode=='no_delta' then
    assert(#task_results==2 and task_results[1].kind=='unconfirmed' and task_results[1].acknowledged==true
        and task_results[2].kind=='unconfirmed' and task_results[2].acknowledged==true)
end
host:closeOfflineTimeUI();reader:onClose(false)
local ffi=require('ffi');local status=ffi.new('int[1]')
pump(function()
    local child=tonumber(ffi.C.waitpid(-1,status,ffi.C.WNOHANG))
    while child>0 do child=tonumber(ffi.C.waitpid(-1,status,ffi.C.WNOHANG)) end
    return child<0 and ffi.errno()==10
end)
io.stdout:write('\nWEREAD_NATIVE_THOUGHT_'..input.token..'_RESULT='..json.encode({result='PASS',mode=input.mode,
    native_menu=true,background_service=background,dialog_correct=true,workers_reaped=true,recovery_checked=recovery_checked,source_reads=source_reads,local_phase=phase,local_confirmed=summary.confirmed})..'\n');io.stdout:flush()

end)
if not worked then
    local module,line
    if type(reason)=='string' then module,line=reason:match('([%w_%-]+%.lua):(%d+):') end
    line=tonumber(line) or 0;module=module or 'unknown'
    io.stdout:write('\nWEREAD_NATIVE_THOUGHT_'..input.token..'_RESULT='..json.encode({result='UNVERIFIED',failed_line=line,failed_module=module})..'\n');io.stdout:flush()
    os.exit(1)
end
