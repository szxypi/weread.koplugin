-- Real ReaderUI, ButtonDialog, workers and SQLite; all HTTP is synthetic.
return function(reader,flush_tasks,fixture_dir)
    assert(os.getenv('WEREAD_REAL_RUNTIME')=='1')
    local host=reader.weread;local UI=require('ui/uimanager');local socket=require('socket')
    package.path=package.path..';'..fixture_dir..'../../?.lua'
    local F=require('spec.helpers.readtime_transfer_fixture')
    local Service=require('weread.lib.readtime_transfer_service')
    local Lease=require('weread.lib.readtime_transfer_lease');local Json=require('json');local C=require('weread.lib.readtime_transfer_contract')
    local Wire=require('weread.lib.readtime_protocol');local zone=Wire.time_zone;Wire.time_zone=function() return '+08:00' end
    local original={ledger=host.offline_time.store,coverage=host.readtime_coverage,get_book=host.settings.get_book,
        getBook=host.library_db.getBook,connected=host.isNetworkConnected}
    local roots={};local count=0;local reports={};local home=assert(os.getenv('KO_HOME'))
    local function expect(v,reason) count=count+1;assert(v,reason or 'native time UI fixture failed') end
    local function pump(predicate)
        local deadline=socket.gettime()+20
        while not predicate() do expect(socket.gettime()<deadline,'native time UI timeout');flush_tasks();socket.sleep(.02) end
    end
    local function choose(label)
        local text=require('weread.lib.i18n').tr(label)
        for _i,item in ipairs(assert(host._offline_time_menu).item_table) do
            if item.text==text then host._offline_time_menu:onMenuSelect(item);return end
        end
        error('native time menu missing: '..label)
    end
    local function button(row)
        local widget=assert(host._offline_time_detail);local item=assert(widget.buttons[row][1])
        expect(item.callback~=nil);item.callback()
    end
    local function detail() pump(function() return host._offline_time_detail~=nil end) end
    local function menu() pump(function() return host._offline_time_menu~=nil end) end
    local function show() host:showOfflineTimeStatus();menu() end
    local function shot(name)
        UI:forceRePaint();require('device').screen:shot(home..'/../evidence/native-time-'..name..'.png')
    end
    local function setup(mode)
        host:closeOfflineTimeUI();host.offline_time_transfer_service=nil
        local f=F.new(mode,expect,roots);expect(f.account==host.library_db:accountKey())
        local native_open=require('lua-ljsqlite3/init').open
        local db=native_open(f.coverage.path);db:exec('CREATE TABLE synthetic_dispatch(id INTEGER PRIMARY KEY CHECK(id=1))');db:close()
        local request=f.client.request
        function f.client:request(options)
            if options.method=='POST' then
                local database=native_open(f.coverage.path);local statement=database:prepare('INSERT INTO synthetic_dispatch VALUES(1)')
                statement:step();statement:close();database:close()
            end
            return request(self,options)
        end
        function f.posts_count()
            local database=native_open(f.coverage.path);local q=database:prepare('SELECT COUNT(*) FROM synthetic_dispatch')
            local value=tonumber(q:step()[1]);q:close();database:close();return value
        end
        host.offline_time.store,host.readtime_coverage=f.ledger,f.coverage
        host.settings.get_book=function(settings,id)
            if id=='42' then return {cached_file='/synthetic-time/book.epub',chapters={{chapterUid=7,chapterIdx=0}}} end
            return original.get_book(settings,id)
        end
        host.library_db.getBook=function(library,id)
            if id=='42' then return {title='合成书籍 · 历史阅读时长'} end
            return original.getBook(library,id)
        end
        host.isNetworkConnected=function() return true end
        host.offline_time_transfer_service=Service:new{settings=f.settings,client=f.client,journal=f.journal,credentials=f.native.store,
            now=function() return f.clock end,scheduler=UI,task_options=f.options,acquire=function(book)
                return Lease.acquire(host,book,function() return host._offline_time_review~=nil end)
            end}
        return f
    end
    local function select_batch()
        show();choose('Check saved time');detail()
        expect(#host._offline_time_detail.buttons==2,'historical batch has no explicit action')
    end
    -- One native action -> real child, durable claim+ACK+two checks+settlement.
    local f=setup();select_batch();shot('selection');button(2);detail();shot('confirmed')
    expect(f.posts_count()==1 and f.ledger:summary(f.account).confirmed==2 and not f.journal:pending(f.account))
    expect(not host._offline_time_transfer_lock and not host.offline_time_transfer_service.job)
    reports[#reports+1]='confirmed'
    -- A later GET-only inspection settles the saved ACK without another POST.
    f=setup('no_delta');select_batch();button(2);detail();local saved=assert(f.journal:pending(f.account))
    expect(saved.phase=='acknowledged' and f.posts_count()==1);local metadata=C.digest(saved.metadata)
    f.posts=1;f.mode=nil;f.applied=true
    show();choose('Review unfinished transfer');detail();shot('acknowledged');button(2);detail()
    expect(f.posts_count()==1 and f.ledger:summary(f.account).confirmed==2)
    expect(C.digest(assert(f.journal:get(f.account,saved.attempt)).metadata)==metadata)
    reports[#reports+1]='read_only_recovery'
    -- A lost reply stays unknown, and explicit retirement retains its seal.
    f=setup('lost');select_batch();button(2);detail();saved=assert(f.journal:pending(f.account))
    expect(saved.phase=='claimed' and f.posts_count()==1)
    show();choose('Review unfinished transfer');detail();shot('unknown')
    expect(#host._offline_time_detail.buttons==2,'lost ACK incorrectly offered cloud confirmation')
    button(2);detail();expect(not f.journal:pending(f.account) and f.ledger:summary(f.account).unknown==2)
    expect(assert(f.journal:get(f.account,saved.attempt)).phase=='retired' and f.posts_count()==1)
    reports[#reports+1]='lost_ack_no_replay'
    -- A failed local settlement is completed later without any new HTTP.
    f=setup();local db=require('lua-ljsqlite3/init').open(f.coverage.path)
    local trigger=db:prepare([[CREATE TRIGGER fail_settle BEFORE UPDATE ON offline_time_records
        WHEN NEW.phase='settled' BEGIN SELECT RAISE(ABORT,'synthetic'); END]])
    trigger:step();trigger:close();db:close()
    select_batch();button(2);detail();saved=assert(f.journal:pending(f.account))
    expect(saved.phase=='confirmed' and saved.evidence.audit and f.posts_count()==1 and f.ledger:summary(f.account).confirmed==2)
    db=require('lua-ljsqlite3/init').open(f.coverage.path);db:exec('DROP TRIGGER fail_settle');db:close()
    show();choose('Review unfinished transfer');detail()
    expect(host._offline_time_detail.title:find(require('weread.lib.i18n').tr('Cloud accounting is confirmed. Only local bookkeeping remains.'),1,true)~=nil)
    shot('local-recovery');button(2);detail()
    expect(not f.journal:pending(f.account) and f.posts_count()==1 and f.ledger:summary(f.account).confirmed==2)
    reports[#reports+1]='local_settlement_recovery'
    -- Close while the child waits after ACK. Its record survives and is sealed.
    f=setup('no_delta');f.options.sleep=function(seconds) socket.sleep(seconds);f.clock=f.clock+seconds end
    select_batch();button(2)
    pump(function() local row=f.journal:pending(f.account);return row and row.phase=='acknowledged' end)
    local worker=assert(host.offline_time_transfer_service.worker.job);local pid=worker.pid
    host:closeOfflineTimeUI()
    pump(function() return require('ffi/util').isSubProcessDone(pid) end)
    expect(not host._offline_time_review and not host.busy_message and not host._offline_time_transfer_lock)
    expect(f.posts_count()==1 and f.journal:pending(f.account).phase=='acknowledged' and f.ledger:summary(f.account).confirmed==0)
    reports[#reports+1]='cancel_after_ack'
    host:closeOfflineTimeUI();host.offline_time_transfer_service=nil
    host.offline_time.store,host.readtime_coverage=original.ledger,original.coverage
    host.settings.get_book,host.library_db.getBook,host.isNetworkConnected=original.get_book,original.getBook,original.connected
    Wire.time_zone=zone
    for _i,root in ipairs(roots) do os.execute('rm -rf '..string.format('%q',root)) end
    local report={result='PASS',synthetic_only=true,account_data_posts=0,authentication_posts=0,
        screen_width=require('device').screen:getWidth(),actual_native_reader=true,actual_memory_workers=true,actual_sqlite=true,
        cases=reports,duplicate_dispatches=0,old_metadata_unchanged=true,checks=count}
    local file=assert(io.open(home..'/../evidence/native-time-transfer.json','w'));file:write(Json.encode(report));file:close()
    print('PASS: native time menu -> child -> durable ACK -> accounting; GET-only recovery, lost reply retirement, cancel after ACK')
end
