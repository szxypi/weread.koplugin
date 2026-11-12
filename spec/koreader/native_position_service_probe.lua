-- Actual KOReader UI loop, native service/SQLite/worker and guarded transport.
-- Private data enters through a pipe; output reports only fixed fields/counts.
require('ffi').log=function() end
require('setupkoenv')
local ffi=require('ffi');require('ffi/posix_h');local json=require('json')
local report={result='UNVERIFIED',phase='init',permit_writes=false,mock=false,native_gets=0,native_posts=0,denied=0,screenshots=0,
    failed_line=0,completed_steps=0,blocked_writes=0,heartbeat=false,parent_guard_only=false,sqlite_before_posts=false,
    ack_journal_checked=false,workers_reaped=false,credential_audit=false,body_guards=false}
local token,profile,service,memory,counters;local workers={}
local ok,reason=pcall(function()
    local home=assert(os.getenv('KO_HOME'));assert(ffi.os=='Linux' and home:match('^/dev/shm/weread%-native%-position%-flow%-[%w_]+/profile$'))
    local length=tonumber(assert(io.stdin:read('*l')));assert(length and length>0 and length<=256*1024)
    local input=json.decode(assert(io.stdin:read(length)));token=input.rpc_token
    assert(type(token)=='string' and #token==32 and token:match('^[a-f0-9]+$'))
    local armed=input.permit_writes;assert(type(armed)=='boolean' and armed==(os.getenv('WEREAD_POSITION_FLOW_ARMED')=='1'))
    report.permit_writes,report.mock=armed,input.mock
    assert(type(input.mock)=='boolean' and input.mock==(os.getenv('WEREAD_POSITION_FLOW_MOCK')=='1'))
    local grant,plan=input.credentials,input.plan;local id=plan.baseline.book_id
    local source=home..'/plugins/weread.koplugin';package.path=source..'/?.lua;'..package.path
    local P=require('weread.lib.native_position_protocol');local C=require('weread.lib.native_position_contract')
    assert(P.credentials(grant) and plan.target.book_id==id and plan.target.chapter_offset==plan.baseline.chapter_offset+1)
    if input.mock then assert(grant.vid=='900000' and grant.accessToken=='synthetic-native-access' and grant.refreshToken=='synthetic-native-refresh'
        and grant.deviceId=='eink334691225'..string.rep('1',19) and id=='41') end
    G_defaults=require('luadefaults'):open();G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
    local Device=require('device');require('document/canvascontext'):init(Device)
    Device.screen.shot=function() report.screenshots=report.screenshots+1;error('native_position/screenshots_disabled',0) end
    local UI=require('ui/uimanager');UI:setRunForeverMode();UI:setInputTimeout(0)
    UI:show(require('ui/widget/infomessage'):new{text='原生同步验证'});UI:forceRePaint()
    local path=debug.getinfo(1,'S').source:match('^@(.*/)')
    profile=dofile(path..'native_account_profile.lua');profile.start(home,grant,input.shelf_books)
    local settings=require('weread.lib.settings'):new();assert(not settings.mock_endpoint)
    assert(type(settings.data_dir)=='string' and settings.data_dir:sub(1,#home+1)==home..'/')
    local client=require('weread.lib.client'):new(settings);local library=require('weread.lib.library_db'):new(settings)
    local Service=require('weread.lib.native_position_service');local owner=tonumber(ffi.C.getpid())
    memory=ffi.C.mmap(nil,4096,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1));counters=ffi.cast('volatile int *',memory)
    counters[3]=1
    local function metadata(seq)
        local before=seq==1 and plan.baseline or plan.target;local desired=seq==1 and plan.target or plan.baseline
        return {book_id=id,before=before,desired=desired,counts=plan.counts,version=plan.version,shelf_sha256=input.native_shelf_sha256,
            source_sha256=plan.source_sha256,file_id='native-flow:'..plan.source_sha256,basis='raw_txt_utf16'}
    end
    local function rpc(kind,seq,body)
        local value={kind=kind,seq=seq};if body then value.body=body end
        io.stdout:write('\nWEREAD_NATIVE_THOUGHT_'..token..'_STEP='..json.encode(value)..'\n');io.stdout:flush()
        local line=assert(io.stdin:read('*l'));assert(#line<=16384);local reply=json.decode(line)
        assert(reply.kind==kind and reply.seq==seq and reply.ok==true)
        for key in pairs(reply) do assert(key=='kind' or key=='seq' or key=='ok') end
    end
    local allowed={['https://i.weread.qq.com/book/info?bookId='..id]=true,['https://i.weread.qq.com/book/getProgress?bookId='..id]=true,
        ['https://i.weread.qq.com/feature?synckey=0']=true,['https://i.weread.qq.com/shelf/sync']=true}
    local function valid(options)
        return options.headers and options.headers.vid==grant.vid and options.headers.accessToken==grant.accessToken
            and options.headers.Cookie==nil and options.skip_cookie==true and options.persist_response_cookies==false and options.sensitive==true
            and type(options.sink)=='function'
            and ((options.method=='GET' and options.body==nil and allowed[options.url]) or (options.method=='POST' and options.url=='https://i.weread.qq.com/book/read' and type(options.body)=='string'))
    end
    assert(not valid{method='GET',url='https://i.weread.qq.com/other'})
    report.body_guards=true
    local request=client.request
    function client:request(options)
        if not valid(options) then counters[2]=counters[2]+1;error('native_position/request_scope',0) end
        local seq=tonumber(counters[3]);assert(seq==1 or seq==2)
        if options.method=='POST' then
            local row=assert(service.journal:read());assert(row.phase=='pending' and C.same(row.metadata,metadata(seq)))
            local body=json.decode(options.body);assert(body.bookId==id and body.readingTime==0 and next(body.hours)==nil)
            assert(counters[1]==seq-1)
            rpc(armed and 'claim' or 'dry_body',seq,body)
            if not armed then counters[7]=counters[7]+1;error('native_position/disarmed',0) end
            counters[1]=counters[1]+1;counters[5]=counters[5]+1
            if input.mock then counters[4]=seq;counters[6]=1;rpc('ack',seq);options.sink(json.encode{succ=1});return nil,200 end
            local sink=options.sink;local chunks,size={},0
            options.sink=function(chunk)
                if chunk then size=size+#chunk;if size<=4*1024*1024 then chunks[#chunks+1]=chunk end end
                return sink(chunk)
            end
            local response={request(self,options)}
            local raw=type(response[1])=='string' and response[1] or table.concat(chunks)
            local decoded,ack=pcall(json.decode,raw);local status=tonumber(response[2])
            if decoded and status and status>=200 and status<300 and P.confirmed(ack) then rpc('ack',seq) end
            return response[1],response[2],response[3]
        else counters[0]=counters[0]+1 end
        if input.mock then
            if options.url:find('/book/info?',1,true) then return json.encode{bookId=id,version=plan.version},200 end
            if options.url:find('/feature?',1,true) then return json.encode{feature={guest_token=input.guest}},200 end
            if options.url:find('/shelf/sync',1,true) then return json.encode{books={{bookId=id,secret=0,finishReading=0}},archive=json.decode('[]')},200 end
            local point=counters[4]==1 and plan.target or plan.baseline
            if counters[6]==1 then point=seq==1 and plan.baseline or plan.target;counters[6]=0 end
            return json.encode{book={bookId=id,chapterUid=tonumber(point.chapter_uid),chapterIdx=point.chapter_idx,chapterOffset=point.chapter_offset,
                progress=point.raw_percent,summary=point.summary,readingTime=plan.counts.readingTime,recordReadingTime=plan.counts.recordReadingTime,ttsTime=plan.counts.ttsTime}},200
        end
        return request(self,options)
    end
    service=Service:new{settings=settings,client=client,library=library,scheduler=UI,task_options={zone=input.time_zone}}
    local function guard()
        assert(tonumber(ffi.C.getpid())==owner,'native_position/parent_guard_in_child');counters[8]=counters[8]+1;return true
    end
    local socket=require('socket');local function wait(predicate)
        local deadline=socket.gettime()+90
        while not predicate() do
            assert(socket.gettime()<deadline)
            if service.worker and service.worker.job then workers[service.worker.job.pid]=true end
            UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
        end
    end
    report.phase='start'
    for seq=1,armed and 2 or 1 do
        counters[3]=seq;report.phase=seq==1 and 'advance' or 'restore'
        local done,out,receipt,beat=false
        UI:scheduleIn(.1,function() beat=true end)
        assert(service:start(metadata(seq),guard,function(value,handle) out,receipt,done=value,handle,true end))
        wait(function() return done and beat end);report.heartbeat=true
        local row=assert(service.journal:read())
        if armed then
            assert(out.kind=='confirmed' and out.attempted and out.acknowledged and receipt and row.phase=='verified')
            report.ack_journal_checked=true;rpc('verified',seq);assert(service:accept(receipt));report.completed_steps=seq
        else
            assert(out.kind=='unconfirmed' and out.attempted and not receipt and row.phase=='pending' and counters[1]==0 and counters[7]==1)
            report.ack_journal_checked=true
        end
    end
    service:cancel()
    for pid in pairs(workers) do wait(function() return require('ffi/util').isSubProcessDone(pid) end) end
    report.workers_reaped=next(workers)~=nil;report.parent_guard_only=counters[8]>0
    report.sqlite_before_posts=armed and counters[5]==2 or not armed and counters[7]==1
    local lfs=require('libs/libkoreader-lfs')
    local function audit(dir)
        for name in lfs.dir(dir) do if name~='.' and name~='..' and not (dir==home and name=='plugins') then
            local full=dir..'/'..name;local info=assert(lfs.symlinkattributes(full))
            if info.mode=='directory' then audit(full)
            elseif info.mode=='file' then
                assert(info.size<=16*1024*1024);local file=assert(io.open(full,'rb'));local bytes=file:read('*a');file:close()
                for _i,value in ipairs({grant.accessToken,grant.refreshToken,grant.deviceId}) do assert(not bytes:find(value,1,true)) end
            else error('native_position/profile_entry',0) end
        end end
    end
    report.phase='audit';audit(home);report.credential_audit=true
    assert(counters[2]==0);report.phase,report.result='complete','PASS'
end)
if service then pcall(service.cancel,service) end
if profile then profile.close() end
if counters then
    report.native_gets,report.native_posts,report.denied,report.blocked_writes=tonumber(counters[0]),tonumber(counters[1]),tonumber(counters[2]),tonumber(counters[7])
    ffi.C.munmap(memory,4096)
end
if not ok then report.failed_line=tonumber(type(reason)=='string' and reason:match('native_position_service_probe%.lua:(%d+):')) or 0 end
if token then io.stdout:write('\nWEREAD_NATIVE_THOUGHT_'..token..'_RESULT='..json.encode(report)..'\n');io.stdout:flush() end
os.exit(ok and 0 or 1)
