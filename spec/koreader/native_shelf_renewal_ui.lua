-- Installed plugin, real FileManager and a host-claimed single renewal.
require('jit').off();require('ffi').log=function() end;require('setupkoenv');require('ffi/posix_h')
local ffi=require('ffi');local json=require('json')
local size=assert(tonumber(io.stdin:read('*l')));assert(size>0 and size<=262144)
local input=json.decode(assert(io.stdin:read(size)));local token=assert(input.token)
assert(token:match('^[a-f0-9]+$') and #token==32 and type(input.armed)=='boolean')
local function emit(kind,value)
    io.stdout:write('\nWEREAD_NATIVE_THOUGHT_'..token..'_'..kind..'='..json.encode(value)..'\n');io.stdout:flush()
end
local function rpc(kind,value)
    value=value or {};value.kind=kind;emit('STEP',value)
    local reply=json.decode(assert(io.stdin:read('*l')))
    assert(reply.kind==kind and type(reply.ok)=='boolean');return reply.ok
end
pcall(ffi.cdef,'void *mmap(void *, unsigned long, int, int, int, long); int memfd_create(const char *, unsigned int);')
local memory=ffi.C.mmap(nil,4096,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1));local counts=ffi.cast('int *',memory)
local ok,reason=xpcall(function()
    local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/'))
    local plugin=home..'/plugins/weread.koplugin';package.path=plugin..'/?.lua;'..assert(arg[1])..'/?.lua;'..package.path
    local P=require('weread.lib.native_position_protocol');assert(P.credentials(input.credentials))
    assert(input.credentials.vid==input.cookies.wr_vid and type(input.expected_count)=='number' and input.expected_count>=1)
    if input.mock_endpoint then
        assert(input.mock_endpoint:match('^http://127%.0%.0%.1:%d+$') and input.credentials.vid=='12345678'
            and input.credentials.accessToken=='synthetic-access' and input.cookies.wr_skey=='synthetic-web-access')
    end
    local auth={auth_schema_version=1,auth_epoch=1,account={user_vid=input.credentials.vid,name=''},cookies=input.cookies,api_key=''}
    local fd=tonumber(ffi.C.memfd_create('weread-shelf-auth',1));assert(fd>=0)
    local encoded='return '..require('dump')(auth,nil,true);local at=0
    while at<#encoded do local n=tonumber(ffi.C.write(fd,ffi.cast('const char *',encoded)+at,#encoded-at));assert(n>0);at=at+n end
    G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua');G_defaults=require('luadefaults'):open()
    G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
    local Settings=require('weread.lib.settings');local new=Settings.new
    function Settings:new()
        local value=new(self);local flush=value.store.flush
        function value.store.flush(store,...)
            local held={};local keys={'account','cookies','api_key','wr_ticket','wr_wrpa','device_fingerprint'}
            for _,key in ipairs(keys) do held[key]=store.data[key];store.data[key]=nil end
            local result={pcall(flush,store,...)}
            for key,item in pairs(held) do store.data[key]=item end
            assert(result[1]);return unpack(result,2)
        end
        for key,item in pairs(auth) do value.store:saveSetting(key,item) end
        value.settings_file='/proc/self/fd/'..fd
        local shelf=value:get('shelf',{});shelf.source='native';shelf.view_mode='list';value:set('shelf',shelf)
        return value
    end
    local Device=require('device');require('document/canvascontext'):init(Device);Device.screen.shot=function() error('screenshots disabled',0) end
    local Common=require('weread.ui.common');Common.isNetworkOnline=function() return true end;Common.isNetworkConnected=Common.isNetworkOnline
    local loader=require('pluginloader');loader.enabled_plugins,loader.disabled_plugins,loader.loaded_plugins={},{},{}
    for _,item in ipairs(loader:_discover()) do if item.name=='weread' then loader:_load{item} end end
    assert(#loader.enabled_plugins==1)
    local UI=require('ui/uimanager');local socket=require('socket');local FM=require('apps/filemanager/filemanager')
    local function wait(predicate)
        local deadline=socket.gettime()+180
        while not predicate() do assert(socket.gettime()<deadline,'shelf_renewal/timeout');UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01) end
    end
    FM:showFiles(home);local host=assert(FM.instance.weread);local scope=assert(host.settings:get_auth_scope())
    host.isNetworkConnected=function() return true end;host.fetchVisibleShelfCovers=function() end
    host.refreshVisibleShelfProgress=function() end;host.showInfo=function(self,message) self.test_message=message end
    local store=assert(host.native_renewal.store);assert(store:save(input.credentials,scope,0,input.expected_count))
    local save=store.save;local expected_new
    store.save=function(active,credentials,active_scope,revision,count)
        assert(revision==2 and counts[2]==1 and type(count)=='number' and count>=1 and count<=5000)
        assert(rpc('verified',{credentials=credentials,book_count=count}),'shelf_renewal/verification')
        expected_new=credentials;return save(active,credentials,active_scope,revision,count)
    end
    local client=host.client;local request=client.request;local base='https://i.weread.qq.com'
    function client:request(options)
        assert(self==client and type(options)=='table' and options.skip_cookie==true
            and options.persist_response_cookies==false and options.sensitive==true and type(options.sink)=='function')
        local headers=options.headers or {}
        if options.url==base..'/shelf/sync' and options.method=='GET' then
            assert(not options.body and headers.vid==input.credentials.vid and type(headers.accessToken)=='string'
                and not headers.Cookie and not headers.Authorization and counts[3]<8)
            counts[3]=counts[3]+1
        elseif options.url==base..'/login' and options.method=='POST' then
            local grant,revision,err,pending=store:read()
            assert(counts[1]==1 and counts[2]==0 and not err and grant and pending and revision==2
                and not headers.vid and not headers.accessToken and not headers.Cookie and not headers.Authorization)
            assert(rpc('claim',{body=json.decode(options.body)}),'shelf_renewal/denied');counts[2]=1
        else error('shelf_renewal/route',0) end
        if input.mock_endpoint then self.settings.mock_endpoint=input.mock_endpoint end
        local result={pcall(request,self,options)}
        if input.mock_endpoint then self.settings.mock_endpoint=nil end
        assert(result[1]);local code=tonumber(result[3])
        if options.url==base..'/shelf/sync' and code==401 and counts[1]==0 then
            counts[1]=1;assert(rpc('expiry',{status=401}),'shelf_renewal/expiry')
        end
        return unpack(result,2)
    end
    local done,snapshot;host:refreshBookshelf(nil,{on_loaded=function(saved,value)
        assert(saved==true);snapshot=value;done=true
    end})
    wait(function() return done or host.test_message~=nil end)
    assert(done and snapshot and counts[1]==1 and counts[2]==1 and counts[3]>=3)
    local fresh,revision,err,pending=store:read();assert(fresh and not err and not pending and revision==3)
    assert(expected_new)
    for _,key in ipairs({'vid','accessToken','refreshToken','deviceId'}) do assert(fresh[key]==expected_new[key]) end
    local native_record=assert(store:_read());local record_fields={revision=true,authorization=true}
    for key in pairs(native_record) do assert(record_fields[key]) end
    local allowed={vid=true,accessToken=true,refreshToken=true,deviceId=true,epoch=true,verified_at=true,book_count=true}
    for key in pairs(native_record.authorization) do assert(allowed[key]) end
    local projection={books=json.decode('[]'),archives=json.decode('[]')}
    for _,book in ipairs(snapshot.books) do
        projection.books[#projection.books+1]={bookId=book.bookId,title=book.title,author=book.author or ''}
    end
    for _,group in ipairs(snapshot.archives) do
        local members=json.decode('[]');for _,id in ipairs(group.bookIds) do members[#members+1]=id end
        projection.archives[#projection.archives+1]={archiveId=group.archiveId,name=group.name,bookIds=members}
    end
    assert(rpc('shelf',{snapshot=projection}),'shelf_renewal/shelf')
    host:showShelfView('books',nil,nil,{skip_cover_fetch_once=true,skip_progress_fetch_once=true})
    assert(host.shelf_view and host.shelf_active_source=='native');UI:forceRePaint()
    host:closeWeReadUI();if FM.instance then FM.instance:onClose() end
    local status=ffi.new('int[1]')
    wait(function() local child=tonumber(ffi.C.waitpid(-1,status,ffi.C.WNOHANG))
        while child>0 do child=tonumber(ffi.C.waitpid(-1,status,ffi.C.WNOHANG)) end;return child==-1 end)
    emit('RESULT',{result='PASS',native_ui=true,one_renewal=true,shelf_rendered=true,workers_reaped=true})
end,function(err) return debug.traceback(tostring(err),2) end)
if not ok then
    local file,line
    if type(reason)=='string' then file,line=reason:match('([%w_%-]+%.lua):(%d+):') end
    local value={result='UNVERIFIED',failed_module=file or 'unknown',failed_line=tonumber(line) or 0}
    if input.mock_endpoint then value.synthetic_error=reason end
    emit('RESULT',value);os.exit(1)
end
