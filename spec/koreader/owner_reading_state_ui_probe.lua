-- Actual plugin UI with owner credentials in anonymous memory only.
require('ffi').log=function() end
require('setupkoenv')
local ffi,json=require('ffi'),require('json');require('ffi/posix_h')
local stage,profile,requests='input',nil,0
local ok,result=pcall(function()
    local input
    do local raw=io.stdin:read(2*1024*1024+1);assert(#raw<=2*1024*1024);input=json.decode(raw) end
    assert(type(input.samples)=='table' and #input.samples==1 and type(input.credentials)=='table')
    local sample,grant=input.samples[1],input.credentials
    local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/weread%-reading%-owner%-[%w_]+/profile$'))
    local source=home..'/plugins/weread.koplugin';package.path=source..'/?.lua;'..package.path
    G_defaults=require('luadefaults'):open();G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
    G_reader_settings:saveSetting('language','zh_CN');require('gettext').changeLang('zh_CN')
    local Device=require('device');require('document/canvascontext'):init(Device)
    Device.screen.shot=function() error('owner_reading_state/screenshots_disabled',0) end
    local Data=require('weread.lib.reading_state');local id=assert(Data.id(sample.book_id))
    local expected,why=Data.project(sample.raw,id,grant.vid);assert(not why and type(expected)=='boolean')
    local path=debug.getinfo(1,'S').source:match('^@(.*/)')
    profile=dofile(path..'native_account_profile.lua');profile.start(home,grant,1)
    local parent=tonumber(ffi.C.getpid())
    pcall(ffi.cdef,'void *mmap(void *, unsigned long, int, int, int, long); int munmap(void *, unsigned long);')
    local memory=ffi.C.mmap(nil,4096,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1))
    local counters=ffi.cast('int *',memory);counters[0]=0;counters[1]=0
    local Client=require('weread.lib.client');local request=Client.request
    function Client:request(options)
        local headers=options.headers or {}
        local allowed=options.url=='https://i.weread.qq.com/book/getProgress?bookId='..id
            and options.method=='GET' and not options.body and options.skip_cookie and options.persist_response_cookies==false
            and options.sensitive and headers.vid==grant.vid and headers.accessToken==grant.accessToken
            and not headers.Cookie and not headers.Authorization and tonumber(ffi.C.getpid())~=parent and counters[0]==0
        if not allowed then counters[1]=counters[1]+1;error('owner_reading_state/transport_scope',0) end
        counters[0]=counters[0]+1
        return request(self,options)
    end
    local plugin=dofile(source..'/main.lua'):new{ui={menu={registerToMainMenu=function() end}}}
    plugin.isNetworkOnline=function() return true end
    local notices={};local show=plugin.showInfo
    function plugin:showInfo(text) notices[#notices+1]=text;return show(self,text) end
    local UI=require('ui/uimanager');UI:setRunForeverMode();UI:setInputTimeout(0)
    local socket=require('socket');local tr=require('weread.lib.plugin_util').tr
    local function wait(test)
        local deadline=socket.gettime()+50
        while not test() do assert(socket.gettime()<deadline);UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01) end
    end
    stage='menu';assert(plugin:showShelfState(id));local menu=assert(plugin._shelf_state_menu)
    local action
    for _,item in ipairs(menu.item_table) do if item.text==tr('Check started-reading status') then action=item end end
    assert(action);menu:onMenuSelect(action)
    local beat=false;UI:scheduleIn(.1,function() beat=true end)
    wait(function() return beat and not plugin._reading_state_ui end)
    stage='result'
    local message=expected and 'WeRead records this book as started.'
        or 'WeRead has not marked this book as started. Its saved position and finished status may be different.'
    assert(#notices==1 and notices[1]==tr(message) and counters[0]==1 and counters[1]==0)
    stage='offline_cache'
    local cache=require('weread.lib.reading_state_cache'):new(plugin.library_db,plugin.library_db:accountKey())
    local saved=assert(cache:read(id));assert(saved.started==expected)
    local top=UI:getTopmostVisibleWidget();if top then UI:close(top) end
    plugin.isNetworkOnline=function() return false end
    menu:onMenuSelect(action)
    local cached=expected and 'Saved on %1: this book was marked as started. This saved status may be out of date.'
        or 'Saved on %1: this book was not marked as started. This saved status may be out of date.'
    assert(#notices==2 and notices[2]==require('weread.lib.plugin_util').T(tr(cached),os.date('%Y-%m-%d %H:%M',saved.checked_at)))
    assert(counters[0]==1 and counters[1]==0)
    requests=tonumber(counters[0])
    require('weread.ui.shelf_state').cancel(plugin)
    top=UI:getTopmostVisibleWidget();if top then UI:close(top) end
    -- All persisted profile files must omit the owner's credentials.
    local lfs=require('libs/libkoreader-lfs')
    local function audit(dir)
        for name in lfs.dir(dir) do
            if name~='.' and name~='..' then
                local file=dir..'/'..name;local mode=lfs.symlinkattributes(file,'mode')
                if mode=='directory' then audit(file)
                elseif mode=='file' then
                    local handle=assert(io.open(file,'rb'));local bytes=handle:read('*a');handle:close()
                    for _,secret in ipairs({grant.vid,grant.accessToken,grant.refreshToken,grant.deviceId}) do
                        if type(secret)=='string' and #secret>=6 then assert(not bytes:find(secret,1,true)) end
                    end
                end
            end
        end
    end
    stage='audit';audit(assert(home:match('^(.*)/profile$')));profile.close();profile=nil;ffi.C.munmap(memory,4096)
    return {model={expected},native={expected},requests=requests,ui=true}
end)
if profile then pcall(profile.close) end
io.stdout:write('\nWEREAD_OWNER_READING_STATE='..json.encode(ok and result or {error='probe_failed',stage=stage,requests=requests})..'\n')
os.exit(ok and 0 or 1)
