-- Packaged native UI, isolated synthetic file, and tightly bounded transport.
-- Account data and the returned test-book identifier stay on the private pipe.
require('ffi').log=function() end
require('setupkoenv')
local ffi=require('ffi');require('ffi/posix_h')
local json=require('json')
local report={result='UNVERIFIED',phase='init',permit_writes=false,chooser=false,cancel_no_request=false,
    heartbeat=false,journal_idle=false,cache_verified=false,file_unchanged=false,credential_audit=false,
    guard_selftest=false,native_gets=0,credential_gets=0,puts=0,notifies=0,denied=0,screenshots=0,failed_line=0}
local input,token,profile,plugin,counters,memory,target,combined
local ok,reason=pcall(function()
    local home=assert(os.getenv('KO_HOME'));assert(ffi.os=='Linux' and home:match('^/dev/shm/weread%-upload%-ui%-[%w_]+/profile$'))
    local length=assert(io.stdin:read('*l'));assert(length:match('^[1-9]%d*$') and #length<=6)
    length=tonumber(length);assert(length<=256*1024);input=json.decode(assert(io.stdin:read(length)))
    token=assert(input.rpc_token);assert(type(token)=='string' and token:match('^[a-f0-9]+$') and #token==32)
    local grant=assert(input.credentials);local name=assert(input.name);local armed=input.permit_writes
    local mock=tonumber(os.getenv('WEREAD_UPLOAD_UI_MOCK_PORT') or '')
    combined=input.combined_fixture==true
    local large=input.fixture=='large_epub';local near=input.fixture=='near_epub';local exact=input.fixture=='exact_epub'
    local reading_epub=input.fixture=='reading_epub'
    local external=large or near or exact;local epub=input.fixture=='epub' or reading_epub or external
    local format_fixtures={pdf={965,'bb52baf0dfb75cf83e6ae4e5e70d093d047fbc4c58f46e49c9f7ece8efbb3dcd'},
        mobi={13272,'f3a6e2fb8d65ee053672dc420eefe1f7494e37fa91ddf66713a1c4d0104f54e6'},
        azw3={14657,'d49af83424ec29d2068559c6692ca6e2ae8e71118b0d2b622660e0b30a341d57'}}
    local format=format_fixtures[input.fixture] and input.fixture or nil
    assert(type(armed)=='boolean' and armed==(os.getenv('WEREAD_UPLOAD_UI_ARMED')=='1'))
    assert(not combined or mock and armed and reading_epub and grant.vid=='900000' and grant.accessToken=='mock-native-access')
    if combined then report.continuous_reading=false;report.read_text_visible=false;report.read_page_turn=false;report.source_bytes_bound=false end
    assert(type(input.shelf_books)=='number' and input.shelf_books%1==0 and input.shelf_books>=1 and input.shelf_books<=5000)
    local extension=format or (epub and 'epub' or 'txt')
    local expected_mock=format and 'SyntheticUpload.'..format or exact and 'SyntheticExactEpub.epub' or near and 'SyntheticNearEpub.epub' or large and 'SyntheticLargeEpub.epub' or epub and 'SyntheticUploadEpub.epub' or 'SyntheticUpload.txt'
    local expected_pattern='^KOReaderSynthetic%-[a-f0-9]+%.'..extension..'$'
    assert(type(name)=='string' and (mock and name==expected_mock or not mock and name:match(expected_pattern) and #name==35+#extension))
    assert(type(grant.vid)=='string' and grant.vid:match('^[1-9]%d*$'))
    report.permit_writes=armed
    local source=home..'/plugins/weread.koplugin';package.path=source..'/?.lua;'..package.path
    G_defaults=require('luadefaults'):open();G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
    G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'});G_reader_settings:saveSetting('language','zh_CN')
    require('gettext').changeLang('zh_CN')
    local Device=require('device');require('document/canvascontext'):init(Device)
    Device.screen.shot=function() report.screenshots=report.screenshots+1;error('upload_ui/screenshots_disabled',0) end
    local UI=require('ui/uimanager');UI:setRunForeverMode();UI:setInputTimeout(0)
    profile=dofile(assert(debug.getinfo(1,'S').source:match('^@(.*/)'))..'native_account_profile.lua')
    profile.start(home,grant,input.shelf_books,combined and {wr_vid='900000',wr_skey='mock_key'} or nil)
    if mock then
        assert(mock>=1 and mock<=65535 and grant.vid=='900000' and grant.accessToken=='mock-native-access')
        local Settings=require('weread.lib.settings');local factory=Settings.new
        function Settings:new() local value=factory(self);value.mock_endpoint='http://127.0.0.1:'..mock;return value end
    end
    local body=not external and ((epub or format) and require('mime').unb64(assert(input.body_base64)) or 'Synthetic upload for KOReader.\n') or nil
    if epub and not external then
        local size=reading_epub and 13601 or 2177
        local hash=reading_epub and 'd3688feb3e04e785a7fe7afa2e95b9771790467c99b6cda624dd54a13a145840'
            or '0c58af1f071704f101504f58b51866b2d479ca08cd75c2a4211ece763ae6b684'
        assert(#body==size and require('weread.lib.crypto').sha256_hex(body)==hash)
    end
    if format then assert(#body==format_fixtures[format][1] and require('weread.lib.crypto').sha256_hex(body)==format_fixtures[format][2]) end
    local stem=assert(name:match('^(.+)%.%w+$'));local path=home..'/'..name
    local expected_size=exact and 209715200 or near and 208668972 or large and 9439532 or #body
    local expected_hash=exact and 'ded3a507b8d0938e186e3a8e8e96903c7921afd411f47abf414af36a689728a0'
        or near and '3ccb192b4c9cb842ed43b5b87f45e94bd03de59c4a7d96b86f0f063dfa774a52'
        or large and 'c358d2de1a9e477618811ab3d5a7bf3e5100617b20bd3742ae2585a7918ba960' or require('weread.lib.crypto').sha256_hex(body)
    local f
    if not external then f=assert(io.open(path,'wb'));assert(f:write(body));f:close() end
    local function verify_file()
        local file=assert(io.open(path,'rb'));local sha=require('ffi/sha2').sha256();local size=0
        while true do local part=file:read(65536);if not part then break end;size=size+#part;assert(size<=expected_size);sha(part) end
        file:close();return size==expected_size and sha()==expected_hash
    end
    assert(verify_file())
    pcall(ffi.cdef,'void *mmap(void *, unsigned long, int, int, int, long); int munmap(void *, unsigned long);')
    memory=ffi.C.mmap(nil,128,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1));counters=ffi.cast('int *',memory)
    local parent=tonumber(ffi.C.getpid());local base='https://i.weread.qq.com'
    local protocol=require('weread.lib.protocol');local Cos=require('weread.lib.cos_sign');local temporary
    local Auth=require('weread.lib.native_authorization');local old_auth=Auth._request
    function Auth:_request(stage,...)
        local value=old_auth(self,stage,...)
        if stage=='personal_upload_credential' then assert(not temporary);temporary=value end
        return value
    end
    local Client=require('weread.lib.client');local request=Client.request
    local reading_enabled,read_requests=false,0
    function Client:request(opts)
        local h=opts.headers or {};local kind
        if combined and reading_enabled and target=='CB_SyntheticResume' then
            local url=opts.url or '';local allowed=false
            if opts.method=='GET' and not opts.body then
                allowed=url=='https://weread.qq.com/web/shelf/sync'
                    or url=='https://weread.qq.com/web/book/getProgress?bookId='..target
                    or url==protocol.reader_url(target) or url=='https://weread.qq.com/mock/illustration.png'
                    or url==base..'/book/info?bookId='..protocol.urlencode(target) and h.vid==grant.vid and h.accessToken==grant.accessToken
                for uid=1,6 do if url==protocol.reader_url(target,tostring(uid)) then allowed=true end end
            elseif opts.method=='POST' and type(opts.body)=='string' and #opts.body<=16384 then
                local decoded,payload=pcall(json.decode,opts.body)
                if decoded and type(payload)=='table' then
                    if url=='https://weread.qq.com/web/book/chapterInfos' then
                        allowed=type(payload.bookIds)=='table' and #payload.bookIds==1 and payload.bookIds[1]==target
                    else
                        local shard=url:match('^https://weread%.qq%.com/web/book/chapter/([et]_%d)$')
                        allowed=shard and ({e_0=true,e_1=true,e_2=true,e_3=true,t_0=true,t_1=true})[shard]
                            and payload.b==protocol.e(target)
                    end
                end
            end
            if allowed then read_requests=read_requests+1;assert(read_requests<=50);return request(self,opts) end
        end
        if opts.sensitive and opts.skip_cookie and opts.persist_response_cookies==false and h.Cookie==nil then
            if opts.method=='GET' and opts.body==nil and h.vid==grant.vid and h.accessToken==grant.accessToken then
                if opts.url==base..'/shelf/sync' then kind=0
                elseif opts.url==base..'/cos/getcredential?name='..protocol.urlencode(stem)..'&from=' then kind=1 end
            elseif temporary and opts.method=='PUT' and opts.body==nil then
                local prepared=assert(Cos.prepare(temporary,expected_size,os.time()));local signed=assert(Cos.sign(prepared))
                if opts.url==signed.url and h.Host==signed.headers.Host and h['Content-Length']==tostring(expected_size)
                    and h['x-cos-security-token']==signed.headers['x-cos-security-token'] and type(h.Authorization)=='string'
                    and h.vid==nil and h.accessToken==nil and type(opts.source)=='function' then kind=2 end
            elseif temporary and opts.method=='POST' and h.vid==grant.vid and h.accessToken==grant.accessToken
                and opts.url==base..'/cos/notify?name='..protocol.urlencode(name)..'&path='..protocol.urlencode(temporary.ObjectName)..'&cancel=0'
                and opts.body=='{}' then kind=3 end
        end
        local ctx=plugin and plugin._personal_upload_ui
        if kind==nil or not armed or tonumber(ffi.C.getpid())==parent or kind==0 and counters[0]>=17 or kind~=0 and counters[kind]>=1
            or not ctx or not ctx.record or not ctx.journal:owns(ctx.selected.scope,ctx.record) then
            if combined and reading_enabled then
                local url=opts.url or ''
                counters[5]=url:find('/web/book/read',1,true) and 1 or url:find('/web/book/getProgress',1,true) and 2
                    or url:find('/web/reader/',1,true) and 3 or url:find('/web/book/chapter',1,true) and 4
                    or url:find('/mock/',1,true) and 6 or url:find('/web/shelf',1,true) and 7
                    or url:find('/web/book',1,true) and 8
                    or url:find('i.weread.qq.com/read',1,true) and 10 or url:find('i.weread.qq.com/book/info',1,true) and 13
                    or url:find('i.weread.qq.com/book/getProgress',1,true) and 14 or url:find('i.weread.qq.com/book/read',1,true) and 15
                    or url:find('i.weread.qq.com/book',1,true) and 11
                    or url:find('i.weread.qq.com/shelf',1,true) and 12 or url:find('i.weread.qq.com',1,true) and 9 or 5
            end
            counters[4]=counters[4]+1;error('upload_ui/transport_denied',0)
        end
        counters[kind]=counters[kind]+1
        if kind==2 then
            local stream=opts.source;local sent=0;local sha=require('ffi/sha2').sha256()
            opts.source=function()
                local part,err=stream()
                if part then sent=sent+#part;assert(sent<=expected_size);sha(part)
                else assert(sent==expected_size and sha()==expected_hash) end
                return part,err
            end
        end
        return request(self,opts)
    end
    local denied=pcall(Client.request,Client:new({}),{url=base..'/login',method='POST',body='{}',headers={},
        sensitive=true,skip_cookie=true,persist_response_cookies=false})
    assert(not denied and counters[4]==1);counters[4]=0;report.guard_selftest=true
    local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
    for _i,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
    assert(#Loader.enabled_plugins==1)
    local FM=require('apps/filemanager/filemanager');FM:showFiles(home);plugin=assert(FM.instance.weread)
    plugin.isNetworkConnected=function() return true end;plugin.isNetworkOnline=function() return true end
    plugin.fetchVisibleShelfCovers=function() end;plugin.prepareShelfProgress=function() end;plugin.refreshVisibleShelfProgress=function() end
    local Worker=require('weread.lib.memory_worker');local Upload=require('weread.ui.personal_upload')
    plugin.personal_upload_worker=Worker:new{scheduler=UI,codec=plugin.client,max_bytes=8*1024*1024,timeout=1800}
    local start=plugin.personal_upload_worker.start
    function plugin.personal_upload_worker:start(task,callback)
        return start(self,task,function(result)
            if Upload.confirmed(result) then target=result.book_id end
            callback(result)
        end)
    end
    local socket=require('socket');local function pump(test)
        local deadline=socket.gettime()+((near or exact) and 850 or 100)
        repeat UI:setInputTimeout(0);UI:handleInput();if test() then return end
            assert(socket.gettime()<deadline,'upload_ui/deadline');socket.sleep(.01) until false
    end
    local tr=require('weread.lib.plugin_util').tr;local Journal=require('weread.lib.personal_upload_journal')
    local scope=assert(plugin.settings:get_auth_scope())
    local function choose()
        local found=false
        for _i,item in ipairs(plugin:getMainMenuItems()) do if item.text==tr('Upload local book') then item.callback();found=true;break end end
        assert(found);local chooser=assert(plugin._personal_upload_ui.chooser)
        chooser:onMenuHold({path=path});assert(chooser.button_dialog).buttons[1][2].callback()
        pump(function() return plugin._personal_upload_ui and plugin._personal_upload_ui.dialog~=nil end)
        return assert(plugin._personal_upload_ui.dialog)
    end
    report.phase='chooser';local dialog=choose();report.chooser=true;dialog.cancel_callback()
    assert(not plugin._personal_upload_ui and Journal:new(plugin.settings,plugin.client):read(scope).phase=='idle')
    assert(counters[0]==0 and counters[1]==0 and counters[2]==0 and counters[3]==0);report.cancel_no_request=true
    if armed then
        report.phase='upload';dialog=choose();dialog.ok_callback()
        local beat=false;UI:scheduleIn(.1,function() beat=true end)
        pump(function() return not plugin._personal_upload_ui and beat end);report.heartbeat=true
        assert(target and Journal:new(plugin.settings,plugin.client):read(scope).phase=='idle');report.journal_idle=true
        local status=assert(plugin.library_db:getShelfStatus(target));assert(status.present==true);report.cache_verified=true
        if combined then
            reading_enabled=true
            local Reader=require('apps/reader/readerui')
            plugin:showBookshelf();local view=assert(plugin.shelf_view);local index
            for position,book in ipairs(view.books) do if tostring(book.bookId)==target then index=position end end
            assert(index and view.paged)
            local page=math.floor((index-1)/view.page_size)+1
            if page~=view.page then plugin:showShelfView('books',nil,nil,{page=page});view=assert(plugin.shelf_view) end
            local visible
            for _i,book in ipairs(view:getVisibleBooks()) do if tostring(book.bookId)==target then visible=book end end
            assert(visible);view.on_select(visible,'books')
            pump(function() return plugin._book_detail_view and not plugin.book_metadata_context end)
            local detail=assert(plugin._book_detail_view);local label=tr('▤ Read');local pressed=false
            for _i,buttons in ipairs({detail._action_buttons or {},detail._footer_actions or {}}) do
                for _j,button in ipairs(buttons) do if button.text==label then assert(button.enabled~=false);button.callback();pressed=true;break end end
                if pressed then break end
            end
            assert(pressed);pump(function() return Reader.instance and Reader.instance.weread and Reader.instance.document end)
            local reader=Reader.instance;assert(reader.weread:detectWeReadBook()==target)
            local document=reader.document;assert(document.file:sub(1,#home)==home and document:getPageCount()>1)
            local source_receipt=assert(require('weread.lib.position_source').read_document(document,target,'1'))
            assert(source_receipt.format=='web_xhtml' and source_receipt.raw_bytes==11797
                and source_receipt.raw_sha256=='1eb9fd7f6ac033fc0f757b361b5c01414863e7f67c355871a175192e7369a8b9')
            report.source_bytes_bound=true
            local matches=assert(document:findAllText('This synthetic chapter verifies',false,0,4,false,0));assert(matches[1] and matches[1].start)
            local last=assert(document:findAllText('Passage 48 has an individual opening',false,0,4,false,0));assert(last[1] and last[1].start)
            reader.rolling:onGotoXPointer(matches[1].start);UI:handleInput();assert(document:isXPointerInCurrentPage(matches[1].start))
            report.read_text_visible=true
            local next_page=reader:getCurrentPage()==1 and 2 or 1;reader.rolling:onGotoPage(next_page);UI:handleInput()
            assert(reader:getCurrentPage()==next_page);report.read_page_turn=true;report.continuous_reading=true
            reader:onClose(false)
        end
    end
    assert(verify_file());report.file_unchanged=true
    plugin:closeWeReadUI()
    local lfs=require('libs/libkoreader-lfs')
    local function audit(dir)
        for item in lfs.dir(dir) do if item~='.' and item~='..' and not (dir==home and item=='plugins') then
            local full=dir..'/'..item;local info=assert(lfs.symlinkattributes(full))
            if info.mode=='directory' then audit(full)
            elseif info.mode=='file' and (near or exact) and full==path then assert(verify_file())
            elseif info.mode=='file' then
                assert(info.size<=16*1024*1024);local file=assert(io.open(full,'rb'));local bytes=file:read('*a');file:close()
                for _i,value in ipairs({grant.accessToken,grant.refreshToken,grant.deviceId}) do assert(not bytes:find(value,1,true)) end
            else error('upload_ui/profile_entry',0) end
        end end
    end
    report.phase='audit';audit(home);report.credential_audit=true
    assert(counters[4]==0 and (not armed or counters[0]>=2 and counters[1]==1 and counters[2]==1 and counters[3]==1))
    report.phase,report.result='complete','PASS'
end)
if plugin then pcall(plugin.closeWeReadUI,plugin) end
if counters then
    report.native_gets,report.credential_gets,report.puts,report.notifies,report.denied=tonumber(counters[0]),tonumber(counters[1]),tonumber(counters[2]),tonumber(counters[3]),tonumber(counters[4])
    if combined and report.denied>0 then report.denied_kind=tonumber(counters[5]) end
    ffi.C.munmap(memory,128)
end
if profile then profile.close() end
if not ok then report.failed_line=tonumber(type(reason)=='string' and reason:match('owner_personal_upload_ui_probe%.lua:(%d+):')) or 0 end
if target and report.result=='PASS' then report.target=target end
if token then io.stdout:write('\nWEREAD_NATIVE_THOUGHT_'..token..'_RESULT='..json.encode(report)..'\n');io.stdout:flush() end
os.exit(ok and 0 or 1)
