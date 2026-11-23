package.path='./?.lua;./?/init.lua;'..package.path
local real=os.getenv('WEREAD_REAL_RUNTIME')=='1'
local H=real and {connect=require('lua-ljsqlite3/init').open} or require('spec.helpers.annotation_test_store')
if not real then package.preload['lua-ljsqlite3/init']=function() return {open=H.connect} end end
local Ledger=require('weread.lib.offline_time_store');local Coverage=require('weread.lib.readtime_coverage')
local Queue=require('weread.lib.readtime_transfer_queue');local Journal=require('weread.lib.readtime_transfer_store')
local Task=require('weread.lib.readtime_transfer_task')
local Native=require('weread.lib.native_read_access');local Web=require('weread.lib.read_access')
local Account=require('weread.lib.native_position_contract').account_key
local Dates=require('weread.lib.read_stats');local A=require('weread.lib.readtime_accounting')
local F=require('spec.helpers.thought_edit_fixture');local Json=require('json')

local M={}
function M.new(mode,expect,roots,cb,config)
    config=config or {}
    local f={posts=0,reads=0,clock=1700007200,current=true,source_reads=0,mode=mode,book_id=cb and 'CB_Synthetic' or '42'}
    f.file_id=config.file_id or string.rep('f',64)
    f.book_version=config.book_version or 7
    f.root=os.tmpname()..'-time-task';os.execute('mkdir -p '..string.format('%q',f.root));roots[#roots+1]=f.root
    local settings,credentials_store,state=F.access();f.settings,f.state=settings,state
    function settings:get(key,default) return key=='cookies' and {wr_vid='900000',wr_skey='synthetic-current-cookie'} or default end
    local grant={vid='900000',deviceId='eink334691225'..string.rep('1',19),accessToken='synthetic-access',refreshToken='synthetic-refresh'}
    function credentials_store:read() return grant,state.revision,nil,state.pending end
    f.native,f.web=Native.capture(settings,credentials_store),Web.capture(settings)
    f.account=Account(grant.vid);local start=f.clock-86400;local day=A.day(start);local month=Dates.period_start('monthly',start)
    f.ledger=Ledger:new(f.root);f.coverage=Coverage:new(f.root,function() return start-100 end);assert(f.coverage:initialize())
    local window=assert(f.ledger:begin(f.account,{book_id=f.book_id,stats_book=1,start_time=start,time_zone='+08:00',book_version=f.book_version,
        file_id=f.file_id,version_source=config.version_source or 'epub_snapshot'}))
    assert(f.ledger:collect(f.account,window,{{page='1',start_time=start,duration=2}},start+2,true))
    f.selection=assert(Queue:new{ledger=f.ledger,coverage=f.coverage,now=function() return f.clock end}:select(f.account,nil,
        {allow_cb=cb,allow_native=config.version_source=='native_direct'})).selection
    f.client={settings=settings,json_encode=function(_s,x) return Json.encode(x) end,json_decode=function(_s,x) return Json.decode(x) end}
    f.journal=Journal:new{coverage=f.coverage,ledger=f.ledger,codec=f.client,now=function() return f.clock end,nonce=function() return string.rep('1',32) end}
    local function progress(web)
        local co=(f.mode=='position' and f.posts>0) and 11 or 10
        local summary='Synthetic complete summary'
        if f.mode=='absent_summary' or f.mode=='summary_presence_changed' and f.posts==0 or f.mode=='summary_disappeared' and f.posts>0 then summary=nil end
        if f.mode=='empty_summary' or f.mode=='summary_presence_changed' and f.posts>0 then summary='' end
        if f.mode=='cb_summary_mismatch' and web then summary='Different summary' end
        if f.mode=='cb_summary_changed_before' and f.configs then summary='Changed before send' end
        local reading=20+(f.applied and 2 or 0)
        if web and (f.mode=='cb_web_counter_mismatch' or f.mode=='cb_web_counter_changed' and f.posts>0) then reading=reading+1 end
        if web and f.mode=='cb_web_counter_delay' and f.posts>0 and f.reads<=1 then reading=20 end
        return {timestamp=f.clock,book={bookId=f.book_id,chapterUid=7,chapterIdx=0,chapterOffset=co,progress=10,
            summary=summary,readingTime=reading,recordReadingTime=0,ttsTime=(f.mode=='tts' and f.posts>0) and 1 or 0}}
    end
    function f.client:get_progress_snapshot(book,access)
        expect(not cb and book==f.book_id and access.cookies.wr_vid=='900000');return progress(true)
    end
    function f.client:get_shelf_display_progress(book,access)
        expect(cb and book==f.book_id and access.cookies.wr_vid=='900000');return progress(true)
    end
    function f.client:request(options)
        expect(options.skip_cookie and options.persist_response_cookies==false and options.sensitive)
        expect(options.headers.vid=='900000' and options.headers.Cookie==nil and options.headers.accessToken=='synthetic-access')
        local data
        if options.method=='POST' then
            expect(options.url=='https://i.weread.qq.com/book/batchUploadProgress');f.posts=f.posts+1
            expect(f.posts==1 and f.journal:pending(f.account).phase=='claimed','POST did not follow durable claim')
            f.body=Json.decode(options.body);f.applied=f.mode~='no_delta'
            if f.mode=='lost' then error('synthetic lost reply') end
            if f.mode=='cancel_post' then f.current=false end
            data=f.mode=='no_ack' and {} or {succ=1}
        elseif options.url:find('/book/info?',1,true) then
            data={bookId=f.book_id,bookVersion=(f.mode=='metadata_version' or f.mode=='metadata_changed_after' and f.posts>0) and 8 or f.book_version}
            if f.mode=='metadata_conflict' then data.version=8 end
            if f.mode=='metadata_missing' then data.bookVersion=nil end
            if f.mode=='metadata_zero_string' then data.bookVersion='0' end
        elseif options.url:find('/book/getProgress?',1,true) then
            if f.posts>0 then
                expect(f.journal:pending(f.account).phase=='acknowledged','readback preceded durable ACK')
                f.reads=f.reads+1
                if f.mode=='delay' then f.applied=f.reads>1 end
            end
            data=progress(false)
        elseif options.url:find('/shelf/sync',1,true) then data={books={{bookId=f.book_id,secret=0,finishReading=0}},archive=real and Json.decode('[]') or {}}
        elseif options.url:find('/readdata/detail?',1,true) then
            data={baseTime=month,readTimes={[tostring(day)]=5},totalReadTime=5,readDays=1}
            if f.applied then
                data.totalReadTime=7
                if f.mode=='current_day' then data.readTimes[tostring(A.day(f.clock))]=2 else data.readTimes[tostring(day)]=7 end
            else data.readTimes[tostring(month)]=0;data.readTimes[tostring(month+86400)]=0 end
        elseif options.url:find('/config?',1,true) then f.configs=(f.configs or 0)+1;data={token='synthetic-config'}
        elseif options.url:find('/feature?',1,true) then data={feature={}};if f.mode=='cancel_pre' then f.current=false end
        else error('unexpected native route') end
        return Json.encode(data),200
    end
    f.options={account=f.account,experimental_cb=cb==true,is_current=function() return f.current end,now=function() return f.clock end,random=function() return 123 end,
        sleep=function(s) f.clock=f.clock+s end,observe_source=function(_client,_web,selection,_refs,previous)
            f.source_reads=f.source_reads+1;expect(selection.file_id==f.file_id)
            if f.mode=='source_changed' and previous then error('source changed') end
            return {file_id=selection.file_id,raw_hash=string.rep('b',64)}
        end}
    function f.run() return Task.run(f.client,settings,f.native,f.web,f.selection,{},f.journal,f.options) end
    return f
end
return M
