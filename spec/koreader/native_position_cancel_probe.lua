-- Synthetic-only interruption cases with real UI, fork workers and SQLite.
require('ffi').log=function() end
require('setupkoenv')
local ffi=require('ffi');require('ffi/posix_h');local json=require('json')
local report={result='UNVERIFIED',cases={},heartbeat=false,parent_guard_only=false,workers_reaped=false,account_data_posts=0,failed_line=0}
local services,allocations={},{}
local ok,reason=pcall(function()
    local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/weread%-position%-cancel%-[%w_]+/profile$'))
    local source=home..'/plugins/weread.koplugin';package.path=source..'/?.lua;'..package.path
    G_defaults=require('luadefaults'):open();G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
    local Device=require('device');require('document/canvascontext'):init(Device)
    Device.screen.shot=function() error('native_position/screenshots_disabled',0) end
    local UI=require('ui/uimanager');UI:setRunForeverMode();UI:setInputTimeout(0)
    UI:show(require('ui/widget/infomessage'):new{text='后台取消验证'});UI:forceRePaint()
    local Shelf=require('weread.lib.shelf_flag_change_contract')
    local Service=require('weread.lib.native_position_service');local lfs=require('libs/libkoreader-lfs');local socket=require('socket')
    local owner=tonumber(ffi.C.getpid());local guard_calls=0
    local grant={vid='900000',deviceId='eink334691225'..string.rep('1',19),accessToken='synthetic-access',refreshToken='synthetic-refresh'}
    local scope={vid=grant.vid,epoch=1}
    local before={book_id='41',chapter_uid='2',chapter_idx=3,chapter_offset=12,raw_percent=17,summary='synthetic original summary'}
    local after={book_id='41',chapter_uid='2',chapter_idx=3,chapter_offset=13,raw_percent=17,summary='synthetic desired summary'}
    local shelf={books={{bookId='41',secret=0,finishReading=0}},archive=json.decode('[]')}
    local metadata={book_id='41',before=before,desired=after,counts={readingTime=10,recordReadingTime=20,ttsTime=0},version=0,
        shelf_sha256=Shelf.state_hash(shelf),source_sha256=string.rep('a',64),file_id='synthetic-file',basis='raw_txt_utf16'}
    local function wait(predicate,pump)
        local deadline=socket.gettime()+15
        while not predicate() do
            assert(socket.gettime()<deadline)
            if pump~=false then UI:setInputTimeout(0);UI:handleInput() end
            socket.sleep(.005)
        end
    end
    for index,kind in ipairs({'before','pending','acknowledged','verified'}) do
        local directory=home..'/case-'..index;assert(lfs.mkdir(directory))
        local settings={data_dir=directory,get=function(_self,key,default) return key=='account' and {user_vid=grant.vid} or default end,
            get_auth_scope=function() return scope end,auth_scope_matches=function(_self,value) return value.vid==scope.vid and value.epoch==scope.epoch end}
        local credentials={read=function() return grant,1,nil,false end}
        local library=require('weread.lib.library_db'):new(settings)
        local memory=ffi.C.mmap(nil,4096,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1));allocations[#allocations+1]=memory
        local cell=ffi.cast('volatile int *',memory);cell[2]=1
        local context=true;local codec={json_encode=function(_self,value) return json.encode(value) end,json_decode=function(_self,value) return json.decode(value) end}
        function codec:request(options)
            assert(options.skip_cookie and options.sensitive and options.headers.accessToken==grant.accessToken)
            if options.method=='POST' then
                cell[0]=cell[0]+1;cell[3]=1
                if kind=='pending' then cell[1]=1;while cell[2]==1 do socket.sleep(.01) end end
                return json.encode{succ=1},200
            end
            cell[4]=cell[4]+1
            if options.url:find('/book/info?',1,true) then return json.encode{bookId='41',version=0},200 end
            if options.url:find('/shelf/sync',1,true) then return json.encode(shelf),200 end
            if options.url:find('/feature?',1,true) then
                if kind=='before' then cell[1]=1;while cell[2]==1 do socket.sleep(.01) end end
                return json.encode{feature={}},200
            end
            assert(options.url:find('/book/getProgress?',1,true))
            if cell[0]>0 and kind=='acknowledged' and cell[2]==1 then cell[1]=1;while cell[2]==1 do socket.sleep(.01) end end
            local point=cell[3]==1 and after or before
            return json.encode{book={bookId='41',chapterUid=2,chapterIdx=3,chapterOffset=point.chapter_offset,progress=17,
                summary=point.summary,readingTime=10,recordReadingTime=20,ttsTime=0}},200
        end
        local function guard() assert(tonumber(ffi.C.getpid())==owner);guard_calls=guard_calls+1;return context end
        local service=Service:new{settings=settings,client=codec,library=library,credentials=credentials,scheduler=UI};services[#services+1]=service
        local callback=false;local beat=false;UI:scheduleIn(.1,function() beat=true end)
        assert(service:start(metadata,guard,function() callback=true end))
        local pid=assert(service.worker.job.pid)
        if kind=='verified' then wait(function() local row=service.journal:read();return row and row.phase=='verified' end,false)
        else wait(function() return cell[1]==1 and beat end) end
        local phase=service.journal:read().phase;assert(phase==(kind=='before' and 'prepared' or kind))
        context=false;service:on_view_changed();cell[2]=0
        wait(function() return require('ffi/util').isSubProcessDone(pid) end)
        assert(not callback and not service.job);assert(service.journal:read().phase==(kind=='before' and 'idle' or kind))
        local posts=tonumber(cell[0]);assert(posts==(kind=='before' and 0 or 1))
        local fresh=Service:new{settings=settings,client=codec,library=library,credentials=credentials,scheduler=UI};services[#services+1]=fresh
        local outcome,token
        if kind=='acknowledged' then
            context=true;assert(fresh:resolve(guard,function(value,handle) outcome,token=value,handle end))
            local resolve_pid=assert(fresh.worker.job.pid);wait(function() return outcome~=nil end)
            assert(outcome.kind=='confirmed' and not outcome.attempted and outcome.readbacks==2 and fresh:accept(token))
            wait(function() return require('ffi/util').isSubProcessDone(resolve_pid) end)
        elseif kind=='verified' then
            cell[3]=2;local reads=tonumber(cell[4])
            assert(fresh:resolve(nil,function(value,handle) outcome,token=value,handle end))
            assert(outcome.kind=='completed' and not outcome.attempted and fresh:accept(token) and cell[4]==reads)
        elseif kind=='pending' then
            assert(not fresh:resolve(guard,function() error('unknown result replayed') end))
        else assert(not fresh:pending()) end
        assert(cell[0]==posts)
        report.cases[#report.cases+1]={kind=kind,preserved_phase=phase,synthetic_posts=posts,late_callback_rejected=not callback,
            final_phase=fresh.journal:read().phase,resolve_kind=outcome and outcome.kind or 'none'}
        report.heartbeat=report.heartbeat or beat
    end
    report.parent_guard_only=guard_calls>0;report.workers_reaped=true
    assert(report.heartbeat and #report.cases==4);report.result='PASS'
end)
for _i,service in ipairs(services) do pcall(service.cancel,service) end
for _i,memory in ipairs(allocations) do ffi.C.munmap(memory,4096) end
if not ok then report.failed_line=tonumber(type(reason)=='string' and reason:match('native_position_cancel_probe%.lua:(%d+):')) or 0 end
io.stdout:write('\nWEREAD_NATIVE_POSITION_CANCEL='..json.encode(report)..'\n');io.stdout:flush();os.exit(ok and 0 or 1)
