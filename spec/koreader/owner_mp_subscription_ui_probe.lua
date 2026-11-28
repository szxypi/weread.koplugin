-- Public-account subscription UI with independently gated, bounded writes.
require('ffi').log=function() end
require('setupkoenv')
local ffi=require('ffi');require('ffi/posix_h')
local json=require('json')
local report={result='UNVERIFIED',phase='init',permit_writes=false,chooser=false,preview=false,cancel_no_post=false,
    heartbeat=false,cache_verified=false,journal_before_posts=false,local_import_preserved=false,credential_audit=false,
    guard_selftest=false,native_gets=0,adds=0,removes=0,denied=0,screenshots=0,failed_line=0}
local token,profile,plugin,counters,memory
local ok,reason=pcall(function()
    local home=assert(os.getenv('KO_HOME'));assert(ffi.os=='Linux' and home:match('^/dev/shm/weread%-mp%-subscription%-ui%-[%w_]+/profile$'))
    local length=assert(io.stdin:read('*l'));assert(length:match('^[1-9]%d*$') and #length<=6)
    length=tonumber(length);assert(length<=256*1024);local input=json.decode(assert(io.stdin:read(length)))
    token=assert(input.rpc_token);assert(type(token)=='string' and token:match('^[a-f0-9]+$') and #token==32)
    local grant=assert(input.credentials);local id=assert(input.account_id);local review=assert(input.review_id);local armed=input.permit_writes
    local mock=tonumber(os.getenv('WEREAD_MP_SUBSCRIPTION_UI_MOCK_PORT') or '')
    assert(type(armed)=='boolean' and armed==(os.getenv('WEREAD_MP_SUBSCRIPTION_UI_ARMED')=='1'))
    assert(type(id)=='string' and id:match('^MP_WXS_[1-9]%d*$') and #id<=27 and type(review)=='string' and review:sub(1,#id+1)==id..'_')
    assert(type(input.shelf_books)=='number' and input.shelf_books%1==0 and input.shelf_books>=1 and input.shelf_books<=5000)
    assert(type(input.members_digest)=='string' and #input.members_digest==64 and input.members_digest:match('^[a-f0-9]+$'))
    assert(type(grant.vid)=='string' and grant.vid:match('^[1-9]%d*$'));report.permit_writes=armed
    local source=home..'/plugins/weread.koplugin';package.path=source..'/?.lua;'..package.path
    G_defaults=require('luadefaults'):open();G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
    G_reader_settings:saveSetting('language','zh_CN');require('gettext').changeLang('zh_CN')
    local Device=require('device');require('document/canvascontext'):init(Device)
    Device.screen.shot=function() report.screenshots=report.screenshots+1;error('mp_subscription_ui/screenshots_disabled',0) end
    local UI=require('ui/uimanager');UI:setRunForeverMode();UI:setInputTimeout(0)
    profile=dofile(assert(debug.getinfo(1,'S').source:match('^@(.*/)'))..'native_account_profile.lua')
    profile.start(home,grant,input.shelf_books)
    if mock then
        assert(mock>=1 and mock<=65535 and grant.vid=='900000' and grant.accessToken=='mock-native-access' and id=='MP_WXS_900098')
        local Settings=require('weread.lib.settings');local factory=Settings.new
        function Settings:new() local value=factory(self);value.mock_endpoint='http://127.0.0.1:'..mock;return value end
    end
    pcall(ffi.cdef,'void *mmap(void *, unsigned long, int, int, int, long); int munmap(void *, unsigned long);')
    memory=ffi.C.mmap(nil,128,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1));counters=ffi.cast('int *',memory)
    local parent=tonumber(ffi.C.getpid());local base='https://i.weread.qq.com'
    local function classify(opts)
        local h=opts.headers or {}
        if not opts.sensitive or not opts.skip_cookie or opts.persist_response_cookies~=false or h.Cookie~=nil or h.Authorization~=nil
            or h.vid~=grant.vid or h.accessToken~=grant.accessToken then return end
        if opts.method=='GET' and opts.body==nil and opts.url==base..'/shelf/sync' then return 0 end
        if opts.method~='POST' or type(opts.body)~='string' then return end
        local parsed,body=pcall(json.decode,opts.body)
        if not parsed or type(body)~='table' or type(body.bookIds)~='table' or #body.bookIds~=1 or body.bookIds[1]~=id
            or type(body.albumIds)~='table' or next(body.albumIds)~=nil or type(body.archiveIds)~='table' or next(body.archiveIds)~=nil then return end
        if not opts.body:match('"albumIds"%s*:%s*%[%s*%]') or not opts.body:match('"archiveIds"%s*:%s*%[%s*%]') then return end
        for k in pairs(body) do if k~='bookIds' and k~='albumIds' and k~='archiveIds' then return end end
        for k in pairs(body.bookIds) do if k~=1 then return end end
        if opts.url==base..'/shelf/add' then return 1 elseif opts.url==base..'/shelf/delete' then return 2 end
    end
    local sample={url=base..'/shelf/sync',method='GET',skip_cookie=true,persist_response_cookies=false,sensitive=true,
        headers={vid=grant.vid,accessToken=grant.accessToken}}
    assert(classify(sample)==0);sample.url=base..'/login';assert(classify(sample)==nil);report.guard_selftest=true
    local Client=require('weread.lib.client');local request=Client.request
    function Client:request(opts)
        local kind=classify(opts)
        if kind==nil or tonumber(ffi.C.getpid())==parent or kind==0 and counters[0]>=16 or kind~=0 and (not armed or counters[kind]>=1)
            or kind==2 and counters[4]~=1 or kind==1 and counters[2]~=0 then
            counters[3]=counters[3]+1;error('mp_subscription_ui/transport_denied',0)
        end
        if kind~=0 then
            local scope=plugin.settings:get_auth_scope();local record=assert(plugin.shelf_membership.journal:read(scope))
            assert(record.phase=='pending' and record.book_id==id and record.operation==(kind==1 and 'add' or 'remove'))
            counters[5]=counters[5]+1
        end
        counters[kind]=counters[kind]+1;return request(self,opts)
    end
    plugin=dofile(source..'/main.lua'):new{ui={menu={registerToMainMenu=function() end}}}
    plugin.isNetworkConnected=function() return true end;plugin.isNetworkOnline=function() return true end
    plugin.fetchVisibleShelfCovers=function() end;plugin.prepareShelfProgress=function() end;plugin.refreshVisibleShelfProgress=function() end
    local Store=require('weread.lib.mp_link_store');local account=assert(plugin.library_db:accountKey())
    assert(Store.add(plugin.library_db,account,id,review,'Synthetic imported article'))
    local socket=require('socket');local function pump(predicate)
        local deadline=socket.gettime()+50
        while not predicate() do assert(socket.gettime()<deadline);UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01) end
    end
    plugin:applyShelfSnapshot({},{});plugin:showShelfView('public_account')
    local view=assert(plugin.shelf_view);view:showOptions();local options=assert(view._shelf_popup)
    local tr=require('weread.lib.plugin_util').tr;local action
    for _i,row in ipairs(options.buttons) do for _j,button in ipairs(row) do
        if button.text==tr('Manage public account subscriptions') then action=button end
    end end
    assert(action);action.callback();pump(function() return plugin._mp_link_menu~=nil end)
    local menu=assert(plugin._mp_link_menu);assert(#menu.item_table==1)
    menu:onMenuSelect(menu.item_table[1]);assert(plugin._shelf_state_menu);report.chooser=true
    local Task=require('weread.lib.shelf_membership_write')
    local function preview(before,digest)
        local item;for _i,row in ipairs(assert(plugin._shelf_state_menu).item_table) do if row.text==tr('Change cloud membership') then item=row end end
        assert(item);assert(plugin._shelf_state_menu):onMenuSelect(item)
        local beat=false;UI:scheduleIn(.1,function() beat=true end)
        pump(function() return beat and plugin._shelf_membership_ui and plugin._shelf_membership_ui.dialog end)
        report.heartbeat=true;local plan=assert(plugin.shelf_membership.preview)
        assert(plan.book_id==id and plan.before==before and Task.digest(assert(Task.members(plan.snapshot)))==digest)
        local dialog=assert(plugin._shelf_membership_ui.dialog)
        assert(dialog.ok_text==tr(before and 'Unsubscribe' or 'Subscribe'));return dialog
    end
    local function independent(sequence)
        io.stdout:write('\nWEREAD_NATIVE_THOUGHT_'..token..'_STEP='..json.encode{seq=sequence}..'\n');io.stdout:flush()
        local raw=assert(io.stdin:read('*l'));assert(#raw<=1024);local response=json.decode(raw)
        assert(type(response)=='table' and response.seq==sequence and response.ok==true)
        for key in pairs(response) do assert(key=='seq' or key=='ok') end
    end
    report.phase='preview';local dialog=preview(false,input.members_digest);report.preview=true
    dialog.cancel_callback();dialog.ok_callback();assert(not plugin._shelf_membership_ui and counters[1]==0 and counters[2]==0);report.cancel_no_post=true
    if armed then
        report.phase='add';dialog=preview(false,input.members_digest);dialog.ok_callback();pump(function() return not plugin._shelf_membership_ui end)
        assert(counters[1]==1 and counters[2]==0 and not plugin.shelf_membership:pending())
        assert(plugin.library_db:getShelfStatus(id).present==true)
        local members=assert(Task.members{books=plugin.library_db:getShelf()});local original={}
        for _i,value in ipairs(members) do if value~=id then original[#original+1]=value end end
        assert(#members==input.shelf_books+1 and Task.digest(original)==input.members_digest)
        local added=Task.digest(members);independent(1);counters[4]=1
        report.phase='remove';dialog=preview(true,added);dialog.ok_callback();pump(function() return not plugin._shelf_membership_ui end)
        assert(counters[1]==1 and counters[2]==1 and not plugin.shelf_membership:pending())
        assert(plugin.library_db:getShelfStatus(id).present==false)
        assert(Task.digest(assert(Task.members{books=plugin.library_db:getShelf()}))==input.members_digest)
        independent(2);report.cache_verified=true;report.journal_before_posts=counters[5]==2
    end
    local rows=assert(Store.list(plugin.library_db,account))
    assert(#rows==1 and rows[1].book_id==id and rows[1].review_id==review and rows[1].title=='Synthetic imported article')
    report.local_import_preserved=true;plugin:closeWeReadUI()
    local lfs=require('libs/libkoreader-lfs')
    local function audit(dir)
        for item in lfs.dir(dir) do if item~='.' and item~='..' and not (dir==home and item=='plugins') then
            local full=dir..'/'..item;local info=assert(lfs.symlinkattributes(full))
            if info.mode=='directory' then audit(full)
            elseif info.mode=='file' then
                assert(info.size<=16*1024*1024);local file=assert(io.open(full,'rb'));local bytes=file:read('*a');file:close()
                for _i,value in ipairs({grant.accessToken,grant.refreshToken,grant.deviceId}) do assert(not bytes:find(value,1,true)) end
            else error('mp_subscription_ui/profile_entry',0) end
        end end
    end
    report.phase='audit';audit(home);report.credential_audit=true;assert(counters[3]==0)
    report.phase,report.result='complete','PASS'
end)
if plugin then pcall(plugin.closeWeReadUI,plugin) end
if counters then
    report.native_gets,report.adds,report.removes,report.denied=tonumber(counters[0]),tonumber(counters[1]),tonumber(counters[2]),tonumber(counters[3])
    ffi.C.munmap(memory,128)
end
if profile then profile.close() end
if not ok then report.failed_line=tonumber(type(reason)=='string' and reason:match('owner_mp_subscription_ui_probe%.lua:(%d+):')) or 0 end
if token then io.stdout:write('\nWEREAD_NATIVE_THOUGHT_'..token..'_RESULT='..json.encode(report)..'\n');io.stdout:flush() end
os.exit(ok and 0 or 1)
