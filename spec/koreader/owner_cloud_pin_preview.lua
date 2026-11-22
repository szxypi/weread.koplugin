-- Read-only real-account cloud-pin preview. Every POST is blocked before transport.
require('ffi').log=function() end
require('setupkoenv')
local ffi=require('ffi');require('ffi/posix_h')
local json=require('json')
local flags={'anonymous_credentials','guard_selftest','native_detail','first_preview','second_preview','native_confirmations',
    'worker_heartbeat','cancel_no_post','local_state_preserved','cache_verified','journal_before_posts','workers_reaped','credential_audit'}
local report={result='UNVERIFIED',phase='init',permit_writes=false,native_gets=0,native_posts=0,denied=0,screenshots=0,
    failed_line=0,shelf_books=0,profile_files_audited=0}
for _i,key in ipairs(flags) do report[key]=false end
local plugin,profile,counters,token;local workers={}
local ok,reason=pcall(function()
    local home=assert(os.getenv('KO_HOME'));assert(ffi.os=='Linux' and home:match('^/dev/shm/weread%-cloud%-pin%-preview%-[%w_]+/profile$'))
    local length=assert(io.stdin:read('*l'));assert(#length<=8 and length:match('^[1-9]%d*$'))
    length=tonumber(length);assert(length<=256*1024)
    local raw=assert(io.stdin:read(length));assert(#raw==length);local input=json.decode(raw)
    token=assert(input.rpc_token);assert(type(token)=='string' and #token==32 and token:match('^[a-f0-9]+$'))
    local armed=input.permit_writes;assert(armed==false and os.getenv('WEREAD_CLOUD_PIN_PREVIEW_ARMED')=='0')
    report.permit_writes=armed
    local grant=input.credentials;local id=input.book_id
    assert(type(id)=='string' and #id<=20 and id:match('^[1-9]%d*$') and type(grant.vid)=='string' and grant.vid:match('^[1-9]%d*$'))
    assert(input.expected_metadata.bookId==id and input.shelf_books>=1 and input.shelf_books<=5000)
    report.shelf_books=input.shelf_books
    local source=home..'/plugins/weread.koplugin';package.path=source..'/?.lua;'..package.path
    assert(require('libs/libkoreader-lfs').symlinkattributes(source,'mode')=='directory')
    G_defaults=require('luadefaults'):open();G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
    G_reader_settings:saveSetting('language','zh_CN');require('gettext').changeLang('zh_CN')
    local Device=require('device');require('document/canvascontext'):init(Device)
    Device.screen.shot=function() report.screenshots=report.screenshots+1;error('owner_probe/screenshots_disabled',0) end
    local UI=require('ui/uimanager');UI:setRunForeverMode();UI:setInputTimeout(0)
    local path=debug.getinfo(1,'S').source:match('^@(.*/)')
    profile=dofile(path..'native_account_profile.lua');profile.start(home,grant,input.shelf_books);report.anonymous_credentials=true
    assert(input.mock_port==nil and not os.getenv('WEREAD_CLOUD_PIN_PREVIEW_MOCK'))
    local C=require('weread.lib.shelf_flag_change_contract');assert(C.valid_metadata(input.mark) and C.valid_metadata(input.restore))
    assert(input.mark.book_id==id and (input.mark.before=='missing' or input.mark.before==false) and input.mark.desired==true
        and input.restore.book_id==id and input.restore.before==true and input.restore.desired==false
        and (input.mark.before_hash==input.restore.after_hash or input.mark.before_hash==input.restore.alternate_hash)
        and input.mark.after_hash==input.restore.before_hash and input.mark.position_hash==input.restore.position_hash)
    pcall(ffi.cdef,'void *mmap(void *, unsigned long, int, int, int, long); int munmap(void *, unsigned long);')
    local memory=ffi.C.mmap(nil,128,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1));counters=ffi.cast('int *',memory)
    local parent=tonumber(ffi.C.getpid());local base='https://i.weread.qq.com'
    local function classify(options)
        local h=options.headers or {}
        if not options.sensitive or not options.skip_cookie or options.persist_response_cookies~=false or h.Cookie~=nil or h.Authorization~=nil
            or h.vid~=grant.vid or h.accessToken~=grant.accessToken then return end
        if options.method=='GET' and options.body==nil then
            if options.url==base..'/shelf/sync' or options.url==base..'/book/getProgress?bookId='..id or options.url==base..'/book/info?bookId='..id then return 'get' end

        end
    end
    local sample={url=base..'/shelf/sync',method='GET',sensitive=true,skip_cookie=true,persist_response_cookies=false,
        headers={vid=grant.vid,accessToken=grant.accessToken}}
    assert(classify(sample)=='get');sample.url=base..'/login';assert(not classify(sample));sample.url=base..'/shelf/sync';sample.headers.Cookie='forbidden';assert(not classify(sample));sample.headers.Cookie=nil;sample.method='POST';assert(not classify(sample))
    report.guard_selftest=true
    local Client=require('weread.lib.client');local request=Client.request
    function Client:request(options)
        local kind=classify(options)
        if kind~='get' or tonumber(ffi.C.getpid())==parent or counters[0]>=40 then
            counters[2]=counters[2]+1;error('owner_probe/transport_denied',0)
        end
        counters[0]=counters[0]+1
        return request(self,options)
    end
    plugin=dofile(source..'/main.lua'):new{ui={menu={registerToMainMenu=function() end}}}
    plugin.isNetworkConnected=function() return true end;plugin.isNetworkOnline=function() return true end
    plugin.fetchVisibleShelfCovers=function() end;plugin.prepareShelfProgress=function() return nil end;plugin.refreshVisibleShelfProgress=function() end
    local tr=require('weread.lib.plugin_util').tr;local Crypto=require('weread.lib.crypto');local socket=require('socket')
    local function wait(predicate)
        local deadline=socket.gettime()+40
        while not predicate() do
            assert(socket.gettime()<deadline)
            for _i,worker in ipairs({plugin.book_metadata_worker or {},plugin._shelf_flag_change_service and plugin._shelf_flag_change_service.worker or {}}) do
                if worker.job then workers[worker.job.pid]=true end
            end
            UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
        end
    end
    local function file(name) local f=assert(io.open(name,'rb'));local value=f:read('*a');f:close();return value end
    plugin.settings:set('books',{[id]={book_id=id,title=input.expected_metadata.title,progress=.12,
        pending_upload_position={book_id=id,chapter_uid=1,chapter_offset=7,percent=12}}});plugin.settings:flush()
    report.phase='detail';plugin:showBookRecord(input.expected_metadata);wait(function() return not plugin.book_metadata_context end)
    local detail=assert(plugin._book_detail_view);assert(detail.data.title==input.expected_metadata.title);report.native_detail=true
    local state_path=assert(plugin.settings:get_book(id)).cache_dir..'/.weread-accounts/'
        ..plugin.settings:account_state_scope()..'/reading_state.json';local original=Crypto.sha256_hex(file(state_path))
    for _i,buttons in ipairs({detail._action_buttons or {},detail._footer_actions or {}}) do
        for _j,button in ipairs(buttons) do if button.text==tr('Shelf status') then button.callback() end end
    end
    local function preview(metadata)
        local beat=false;UI:scheduleIn(.1,function() beat=true end)
        local menu=assert(plugin._shelf_state_menu);local invoked=false
        for _i,item in ipairs(menu.item_table) do if item.text==tr('Change cloud pin') then item.callback();invoked=true;break end end
        assert(invoked);wait(function() return beat and plugin._shelf_flag_change_ui and plugin._shelf_flag_change_ui.dialog end)
        report.worker_heartbeat=true
        local service=assert(plugin._shelf_flag_change_service);assert(C.same(service.preview.metadata,metadata))
        local dialog=plugin._shelf_flag_change_ui.dialog
        assert(dialog.ok_text==tr('Pin in WeRead'))
        assert(dialog.text:find(input.expected_metadata.title,1,true));UI:forceRePaint();return dialog
    end
    report.phase='preview';local dialog=preview(input.mark);report.first_preview=true;report.native_confirmations=true
    dialog.cancel_callback();dialog.ok_callback();assert(not plugin._shelf_flag_change_ui and counters[1]==0)
    report.cancel_no_post=true
    dialog=preview(input.mark);dialog.cancel_callback();assert(counters[1]==0)
    assert(Crypto.sha256_hex(file(state_path))==original)
    local latest=assert(plugin.settings:get_book(id));assert(latest.progress==.12 and latest.pending_upload_position.chapter_offset==7)
    report.local_state_preserved=true;plugin:closeWeReadUI()
    for pid in pairs(workers) do wait(function() return require('ffi/util').isSubProcessDone(pid) end) end
    report.workers_reaped=next(workers)~=nil
    local lfs=require('libs/libkoreader-lfs')
    local function audit(dir)
        for name in lfs.dir(dir) do if name~='.' and name~='..' and not (dir==home and name=='plugins') then
            local full=dir..'/'..name;local info=assert(lfs.symlinkattributes(full))
            if info.mode=='directory' then audit(full)
            elseif info.mode=='file' then
                report.profile_files_audited=report.profile_files_audited+1;assert(report.profile_files_audited<=1024 and info.size<=16*1024*1024)
                local bytes=file(full);for _i,value in ipairs({grant.accessToken,grant.refreshToken,grant.deviceId}) do assert(not bytes:find(value,1,true)) end
            else error('owner_probe/profile_entry',0) end
        end end
    end
    report.phase='audit';audit(home);report.credential_audit=true
    assert(counters[2]==0 and counters[0]>=5);report.phase,report.result='complete','PASS'
end)
if plugin then pcall(plugin.closeWeReadUI,plugin) end
if counters then report.native_gets,report.native_posts,report.denied=tonumber(counters[0]),tonumber(counters[1]),tonumber(counters[2]);ffi.C.munmap(counters,128) end
if profile then profile.close() end
if not ok then report.failed_line=tonumber(type(reason)=='string' and reason:match('owner_cloud_pin_preview%.lua:(%d+):')) or 0 end
if token then io.stdout:write('\nWEREAD_NATIVE_THOUGHT_'..token..'_RESULT='..json.encode(report)..'\n');io.stdout:flush() end
os.exit(ok and 0 or 1)
