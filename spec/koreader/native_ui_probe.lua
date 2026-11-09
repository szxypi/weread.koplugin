-- Explicit owner read probe: private data stays in RAM, never screenshots.
require('ffi').log=function() end
require('setupkoenv')
local ffi=require('ffi');require('ffi/posix_h')
local json=require('json')
local report={result='UNVERIFIED',phase='init',anonymous_credentials=false,volatile_settings=false,
    volatile_sqlite=false,transport_guard_selftest=false,worker_heartbeat=false,metadata_projection_matches=false,
    paged_shelf=false,shelf_books=0,shelf_groups=0,search_books=0,similar_books=0,recommend_books=0,
    painted_views=0,profile_files_audited=0,screenshots=0,forbidden_requests=0,request_counts={0,0,0,0,0}}
local descriptors,connection,counters,plugin={},nil,nil,nil
local ok=pcall(function()
    assert(ffi.os=='Linux','anonymous credential descriptors require Linux')
    local source,home=assert(arg[1]),assert(os.getenv('KO_HOME'))
    local lfs=require('libs/libkoreader-lfs')
    assert(lfs.symlinkattributes(home,'mode')=='directory' and source==home..'/plugins/weread.koplugin')
    assert(lfs.symlinkattributes(source,'mode')=='directory' and not lfs.symlinkattributes(home..'/weread')
        and not lfs.symlinkattributes(home..'/settings/weread.lua')
        and not lfs.symlinkattributes(home..'/settings/weread-mock.lua'),'fresh isolated profile required')
    local input
    do local raw=assert(io.stdin:read(256*1024+1));assert(#raw<=256*1024);input=json.decode(raw) end
    local grant=assert(input.credentials)
    assert(type(grant.vid)=='string' and grant.vid:match('^[1-9]%d*$'))
    assert(type(input.book_id)=='string' and input.book_id:match('^[1-9]%d*$') and #input.book_id<=20)
    assert(type(input.expected_metadata)=='table' and input.expected_metadata.bookId==input.book_id)
    package.path=source..'/?.lua;'..package.path
    G_defaults=require('luadefaults'):open()
    local LuaSettings=require('luasettings')
    G_reader_settings=LuaSettings:open(home..'/settings.reader.lua')
    G_reader_settings:saveSetting('language','zh_CN');require('gettext').changeLang('zh_CN')
    local Device=require('device');require('document/canvascontext'):init(Device)
    Device.screen.shot=function() report.screenshots=report.screenshots+1;error('screenshots disabled',0) end
    local UIManager=require('ui/uimanager')
    pcall(ffi.cdef,'int memfd_create(const char *name, unsigned int flags);')
    local function anonymous(data)
        local fd=tonumber(ffi.C.memfd_create('weread-owner-probe',1));assert(fd>=0)
        descriptors[#descriptors+1]=fd
        local bytes='return '..require('dump')(data,nil,true);local offset=0
        while offset<#bytes do
            local n=tonumber(ffi.C.write(fd,ffi.cast('const char *',bytes)+offset,#bytes-offset))
            assert(n>0);offset=offset+n
        end
        return '/proc/self/fd/'..fd
    end
    local settings_data={auth_schema_version=1,auth_epoch=1,account={user_vid=grant.vid,name=''},cookies={},
        api_key='',shelf={source='native',view_mode='list',paginated=true},home={view_mode='list'}}
    local scope_path=anonymous(settings_data)
    local saved={};for key,value in pairs(grant) do saved[key]=value end
    saved.epoch,saved.verified_at,saved.book_count=1,os.time(),input.shelf_books
    local grant_path=anonymous({revision=1,authorization=saved})
    local Settings=require('weread.lib.settings');local create_settings=Settings.new
    function Settings:new()
        local value=create_settings(self)
        assert(not value.mock_endpoint)
        value.store=LuaSettings:wrap(settings_data)
        value.store.flush=function() return true end
        value.settings_file=scope_path
        local get,set=Settings.get,Settings.set
        local books={}
        value.get=function(instance,key,...)
            if key=='books' then return books end
            return get(instance,key,...)
        end
        value.get_book=function(_instance,id) return books[tostring(id)] end
        value.set=function(instance,key,data)
            if key=='books' then books=data;return end
            return set(instance,key,data)
        end
        report.volatile_settings=value.store.file==nil
        return value
    end
    local Credentials=require('weread.lib.native_credentials');local create_credentials=Credentials.new
    function Credentials:new(settings,...)
        local value=create_credentials(self,settings,...);value.path=grant_path;return value
    end
    report.anonymous_credentials=true
    local SQ3=require('lua-ljsqlite3/init');local open=SQ3.open
    SQ3.open=function(path,...)
        if path:find('/weread/library-',1,true) then
            if not connection then
                connection=open(':memory:')
                local seq,name,file=connection:rowexec('PRAGMA database_list')
                assert(seq==0 and name=='main' and file=='');report.volatile_sqlite=true
            end
            return setmetatable({close=function() end},{__index=function(_self,key)
                local method=connection[key]
                return type(method)=='function' and function(_instance,...) return method(connection,...) end or method
            end})
        end
        return open(path,...)
    end
    pcall(ffi.cdef,'void *mmap(void *, unsigned long, int, int, int, long); int munmap(void *, unsigned long);')
    local memory=ffi.C.mmap(nil,64,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1))
    counters=ffi.cast('int *',memory)
    local Protocol=require('weread.lib.protocol')
    local base='https://i.weread.qq.com'
    local urls={base..'/shelf/sync',base..'/book/info?bookId='..input.book_id,
        base..'/store/search?count=20&keyword='..Protocol.urlencode('鲁迅')..'&maxIdx=0&scope=10',
        base..'/book/detailinfo?bookId='..input.book_id..'&count=20&listtypes=2&maxIdx=0&synckey=0',
        base..'/book/recommend?count=20&maxIdx=0'}
    local allowed={};for index,url in ipairs(urls) do allowed[url]=index-1 end
    local function classify(options)
        local headers=options.headers or {}
        if options.method~='GET' or options.body~=nil or not options.skip_cookie or options.persist_response_cookies~=false
            or not options.sensitive or headers.vid~=grant.vid or headers.accessToken~=grant.accessToken
            or headers.Cookie~=nil or headers.Authorization~=nil then return nil end
        return allowed[options.url]
    end
    local permitted={url=urls[1],method='GET',skip_cookie=true,persist_response_cookies=false,sensitive=true,
        headers={vid=grant.vid,accessToken=grant.accessToken}}
    assert(classify(permitted)==0)
    for _,change in ipairs({'post','body','url','cookie','owner','token','persist'}) do
        local value={};for key,item in pairs(permitted) do value[key]=item end
        value.headers={vid=grant.vid,accessToken=grant.accessToken}
        if change=='post' then value.method='POST' elseif change=='body' then value.body='{}'
        elseif change=='url' then value.url=base..'.invalid/shelf/sync'
        elseif change=='cookie' then value.headers.Cookie='forbidden'
        elseif change=='owner' then value.headers.vid='0' elseif change=='token' then value.headers.accessToken='invalid'
        else value.persist_response_cookies=true end
        assert(classify(value)==nil)
    end
    report.transport_guard_selftest=true
    local Client=require('weread.lib.client');local request=Client.request
    function Client:request(options)
        local index=classify(options)
        if index==nil or counters[index]>=1 then counters[5]=counters[5]+1;error('owner UI read scope rejected',0) end
        counters[index]=counters[index]+1
        return request(self,options)
    end
    local Plugin=dofile(source..'/main.lua')
    plugin=Plugin:new{ui={menu={registerToMainMenu=function() end}}}
    plugin.isNetworkOnline,plugin.isNetworkConnected=function() return true end,function() return true end
    -- Cover fetching and visible progress are separate acceptance cases.
    plugin.fetchVisibleShelfCovers=function() end
    plugin.prepareShelfProgress=function() return nil end
    plugin.refreshVisibleShelfProgress=function() end
    assert(plugin.settings:auth_scope_matches(plugin.settings:get_auth_scope()))
    assert(Credentials:new(plugin.settings):read().vid==grant.vid)
    local socket=require('socket')
    local function pump(predicate)
        local deadline=socket.gettime()+30
        while not predicate() do
            assert(socket.gettime()<deadline)
            UIManager:setInputTimeout(0);UIManager:handleInput();socket.sleep(.01)
        end
    end
    local function paint()
        UIManager:forceRePaint();report.painted_views=report.painted_views+1
    end
    report.phase='shelf'
    local loaded=false
    plugin:refreshBookshelf(nil,{on_loaded=function(success) loaded=success end})
    UIManager:scheduleIn(.1,function() report.worker_heartbeat=plugin.shelf_refreshing==true end)
    pump(function() return not plugin.shelf_refreshing end)
    assert(loaded and plugin.shelf_active_source=='native')
    local books=plugin.library_db:getShelf()
    assert(#books==input.shelf_books)
    report.shelf_books,report.shelf_groups=#books,#plugin.shelf_groups
    plugin:showShelfView('books');assert(plugin.shelf_view);paint()
    if plugin.shelf_view.page_count>1 then
        plugin:showShelfView('books',nil,nil,{page=2});assert(plugin.shelf_view.page==2)
        report.paged_shelf=true;paint()
    end
    report.phase='home';plugin:closeWeReadUI();plugin:showHome();assert(plugin.shelf_view);paint()
    report.phase='book';plugin:closeWeReadUI()
    local target;for _,book in ipairs(books) do if book.bookId==input.book_id then target=book end end
    assert(target);plugin:showBookRecord(target)
    pump(function() return not plugin.book_metadata_context end)
    local record=assert(plugin.settings:get_book(input.book_id))
    assert(record.detail_source=='native' and plugin._book_detail_view)
    for key,value in pairs(input.expected_metadata) do assert(record[key]==value) end
    assert(plugin._book_detail_view.data.title==input.expected_metadata.title)
    assert(plugin._book_detail_view.data.intro==input.expected_metadata.intro)
    report.metadata_projection_matches=true;paint()
    for _,kind in ipairs({'search','similar','recommend'}) do
        report.phase=kind;plugin:closeWeReadUI()
        plugin:loadDiscoveryBatch(kind,kind=='search' and '鲁迅' or nil,0,false,false,
            kind=='similar' and {book_id=input.book_id,book_title=record.title} or nil)
        pump(function() return not plugin.discovery_loading and not plugin.discovery_request_context end)
        local state=assert(plugin.discovery_state)
        assert(state.kind==kind and state.source_kind=='native' and plugin.shelf_view)
        report[kind..'_books']=#state.books;paint()
    end
    plugin:closeWeReadUI();report.phase='audit'
    local private={grant.vid,grant.accessToken,grant.refreshToken,grant.deviceId,input.book_id,input.expected_metadata.title}
    for _,book in ipairs(books) do private[#private+1]=book.bookId end
    local function audit(path)
        for name in lfs.dir(path) do
            if name~='.' and name~='..' and not (path==home and name=='plugins') then
                local file=path..'/'..name;local info=assert(lfs.symlinkattributes(file))
                if info.mode=='directory' then audit(file)
                elseif info.mode=='file' then
                    report.profile_files_audited=report.profile_files_audited+1
                    assert(report.profile_files_audited<=512 and info.size<=4*1024*1024)
                    local handle=assert(io.open(file,'rb'));local bytes=handle:read('*a');handle:close()
                    for _,value in ipairs(private) do
                        if type(value)=='string' and #value>=6 then assert(not bytes:find(value,1,true)) end
                    end
                else error('unexpected profile entry',0) end
            end
        end
    end
    audit(home)
    for index=1,5 do assert(counters[index-1]==1) end
    assert(counters[5]==0 and report.worker_heartbeat)
    report.phase,report.result='complete','PASS'
end)
if plugin then pcall(plugin.closeWeReadUI,plugin) end
if connection then pcall(connection.close,connection) end
if counters then
    for index=1,5 do report.request_counts[index]=tonumber(counters[index-1]) end
    report.forbidden_requests=tonumber(counters[5]);ffi.C.munmap(counters,64)
end
for _,fd in ipairs(descriptors) do ffi.C.close(fd) end
if not ok then report.result='UNVERIFIED' end
io.stdout:write('\nWEREAD_NATIVE_UI_RESULT='..json.encode(report)..'\n')
os.exit(ok and 0 or 1)
