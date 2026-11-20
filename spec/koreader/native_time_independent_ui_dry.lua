-- Isolated real-account menu rehearsal. The HTTP guard cannot forward writes.
require('ffi').log=function() end
require('setupkoenv')
require('ffi/posix_h')
local json=require('json')
local length=assert(io.stdin:read('*l'))
assert(length:match('^[1-9]%d*$') and tonumber(length)<=65536)
local input=json.decode(assert(io.stdin:read(tonumber(length))))
assert(type(input.token)=='string' and #input.token==32 and input.token:match('^[a-f0-9]+$') and input.armed==false)
assert(type(arg[1])=='string' and type(arg[2])=='string' and type(arg[3])=='string' and type(arg[4])=='string')
local function emit(kind,value)
    io.stdout:write('\nWEREAD_NATIVE_THOUGHT_'..input.token..'_'..kind..'='..json.encode(value)..'\n');io.stdout:flush()
end
local function rpc(kind,extra)
    local value=extra or {};value.kind=kind;emit('STEP',value)
    local reply=json.decode(assert(io.stdin:read('*l')))
    assert(reply.kind==kind and type(reply.ok)=='boolean')
    return reply.ok
end
local worked,reason=pcall(function()
    local home=assert(os.getenv('KO_HOME'));package.path=home..'/plugins/weread.koplugin/?.lua;'..arg[1]..'/?.lua;'..package.path
    G_defaults=require('luadefaults'):open();G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
    G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
    G_reader_settings:saveSetting('language','zh_CN');require('gettext').changeLang('zh_CN')
    G_reader_settings:saveSetting('color_rendering',false)
    local Position=require('weread.lib.native_position_protocol')
    assert(Position.id(input.book_id)==input.book_id and input.owner==input.grant.vid and input.cookies.wr_vid==input.owner)
    if input.mock_port~=nil then
        assert(type(input.mock_port)=='number' and input.mock_port%1==0 and input.mock_port>=1 and input.mock_port<=65535
            and input.owner=='900000' and input.book_id=='900001' and input.cookies.wr_skey=='mock_key'
            and input.grant.accessToken=='mock-native-access' and input.grant.refreshToken=='mock-native-refresh')
    end
    local Client=require('weread.lib.client');local network=Client.request;local allowed_client
    function Client:request(options)
        assert(self==allowed_client,'independent_ui/other_network')
        if input.mock_port then
            self.settings.mock_endpoint='http://127.0.0.1:'..input.mock_port
            local result={pcall(network,self,options)}
            self.settings.mock_endpoint=nil
            assert(result[1]);return unpack(result,2)
        end
        return network(self,options)
    end
    local Device=require('device');require('document/canvascontext'):init(Device)
    Device.screen.shot=function() error('independent_ui/screenshot_disabled',0) end
    local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
    for _i,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
    assert(#Loader.enabled_plugins==1)
    package.path=home..'/plugins/weread.koplugin/?.lua;'..arg[1]..'/?.lua;'..package.path
    local UI=require('ui/uimanager');local socket=require('socket')
    UI:setRunForeverMode();UI:setInputTimeout(0)
    local function pump(predicate)
        local deadline=socket.gettime()+80
        while not predicate() do assert(socket.gettime()<deadline,'independent_ui/timeout');UI:handleInput();socket.sleep(.02) end
    end
    local reader=require('apps/reader/readerui'):new{dimen=Device.screen:getSize(),
        document=require('document/documentregistry'):openDocument(arg[2])}
    assert(reader and reader.weread and reader.document);UI:show(reader)
    local host=reader.weread
    host.settings:set('account',{user_vid=input.owner,name='Rehearsal'})
    host.settings:set('cookies',{});host.settings:set('auth_epoch',1);host.settings:flush()
    local account=assert(host.library_db:accountKey())
    assert(account==require('weread.lib.native_position_contract').account_key(input.owner))
    local Ledger=require('weread.lib.offline_time_store');local Coverage=require('weread.lib.readtime_coverage')
    local ledger=Ledger:new(arg[3]);local coverage=Coverage:new(arg[3]);assert(coverage:initialize()<=input.start_time)
    local C=require('weread.lib.readtime_transfer_contract');assert(C.digest(assert(ledger:pending(account)))==C.digest(input.rows))
    local available=assert(coverage:preview_individual(account,input.rows))
    assert(available.eligible==input.seconds and available.covered==0 and available.unverified==0)
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
        if id==input.book_id then return {title='Rehearsal book'} end
        return get_book_info(db,id)
    end
    local scope={vid=input.owner,epoch=1}
    local settings={get_auth_scope=function() return scope end,auth_scope_matches=function(_self,value)
        return type(value)=='table' and value.vid==scope.vid and value.epoch==scope.epoch
    end,get=function(_self,key,default) if key=='cookies' then return input.cookies end;return default end}
    local credentials={read=function() return input.grant,1,nil,false end}
    local client=Client:new(settings);allowed_client=client
    local Journal=require('weread.lib.readtime_transfer_store')
    local journal=Journal:new{coverage=coverage,ledger=ledger,codec=client}
    local selected;local months={};for month in pairs(input.months) do months[#months+1]=assert(tonumber(month)) end;table.sort(months)
    require('spec.koreader.native_time_http_guard').install(client,{
        grant=input.grant,book_id=input.book_id,chapter_uid=input.chapter_uid,cookies=input.cookies,months=months,
        now=os.time,current=function() return host._offline_time_review~=nil end,
        selection=function() return selected end,record=function()
            local record=assert(journal:pending(account));assert(record.phase=='claimed');return record
        end,rpc=function(kind,value)
            local allowed=rpc(kind,value)
            if kind=='claim' then return false end
            return allowed
        end})
    local service=require('weread.lib.readtime_transfer_service'):new{settings=settings,client=client,journal=journal,
        credentials=credentials,scheduler=UI,acquire=function(book)
            return require('weread.lib.readtime_transfer_lease').acquire(host,book,function() return host._offline_time_review~=nil end)
        end}
    local start=service.start;local background=false
    function service:start(mode,owner,selection,refs,guard,callback)
        assert(mode=='send' and owner==account);selected=selection
        if not rpc('selection',{selection=selection}) then return false,'unavailable' end
        local started,why=start(self,mode,owner,selection,refs,guard,callback)
        if started then
            local worker=assert(self.worker and self.worker.job)
            assert(type(worker.pid)=='number' and worker.pid~=tonumber(require('ffi').C.getpid()));background=true
        end
        return started,why
    end
    host.offline_time_transfer_service=service
    host:showOfflineTimeStatus();pump(function() return host._offline_time_menu~=nil end)
    local tr=require('weread.lib.i18n').tr;local chosen
    for _i,item in ipairs(host._offline_time_menu.item_table) do if item.text==tr('Check saved time') then chosen=item;break end end
    assert(chosen,'independent_ui/menu');host._offline_time_menu:onMenuSelect(chosen)
    pump(function() return host._offline_time_detail~=nil end)
    local detail=host._offline_time_detail;local transfer_button
    for _i,row in ipairs(detail.buttons) do for _j,button in ipairs(row) do
        if button.text==tr('Transfer this batch') then assert(not transfer_button);transfer_button=button end
    end end
    assert(transfer_button and type(transfer_button.callback)=='function','independent_ui/button')
    transfer_button.callback();pump(function() return host._offline_time_detail~=nil and service.job==nil end)
    assert(host._offline_time_detail.title==tr('Cloud accounting is not confirmed. The request is kept and will not be sent again.'))
    local pending=assert(journal:pending(account));local summary=assert(ledger:summary(account))
    assert(pending.phase=='claimed' and summary.confirmed==0 and background and not host._offline_time_transfer_lock,
        'independent_ui/boundary')
    host:closeOfflineTimeUI();reader:onClose(false)
    local ffi=require('ffi');local status=ffi.new('int[1]')
    pump(function()
        local child=tonumber(ffi.C.waitpid(-1,status,ffi.C.WNOHANG))
        while child>0 do child=tonumber(ffi.C.waitpid(-1,status,ffi.C.WNOHANG)) end
        return child==-1
    end)
    emit('RESULT',{result='PASS',native_menu=true,background_service=true,local_phase='claimed',workers_reaped=true})
end)
if not worked then
    local module,line
    if type(reason)=='string' then module,line=reason:match('([%w_%-]+%.lua):(%d+):') end
    emit('RESULT',{result='UNVERIFIED',failed_module=module or 'unknown',failed_line=tonumber(line) or 0})
    os.exit(1)
end
