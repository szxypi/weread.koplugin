-- Packaged native menus, SQLite journal and closed synthetic transport.
require('ffi').log=function() end
require('setupkoenv')
local ffi,json=require('ffi'),require('json');require('ffi/posix_h')
local report={result='UNVERIFIED',phase='init',checks=0,posts=0,screenshots=0}
local function expect(value)
    report.checks=report.checks+1
    if not value then error('reading_state_change_ui:'..debug.getinfo(2,'l').currentline,0) end
end
local ok,reason=pcall(function()
    local home=assert(os.getenv('KO_HOME'));local source=home..'/plugins/weread.koplugin'
    package.path=source..'/?.lua;'..package.path
    G_defaults=require('luadefaults'):open();G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
    G_reader_settings:saveSetting('language','zh_CN');require('gettext').changeLang('zh_CN')
    G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
    local Device=require('device');require('document/canvascontext'):init(Device)
    local SQ3=require('lua-ljsqlite3/init');local remote_path=home..'/synthetic-reading-state.db'
    local function remote(task)
        local db=SQ3.open(remote_path);db:exec('PRAGMA busy_timeout=3000')
        local good,value=pcall(task,db);db:close();assert(good);return value
    end
    local function load(db) return json.decode(db:rowexec('SELECT payload FROM remote WHERE id=1')) end
    local function save(db,value)
        local stmt=db:prepare('UPDATE remote SET payload=? WHERE id=1');stmt:bind(json.encode(value)):step();stmt:close()
    end
    local function change(task) remote(function(db)
        db:exec('BEGIN IMMEDIATE');local value=load(db);task(value);save(db,value);db:exec('COMMIT')
    end) end
    local function state() return remote(load) end
    local function shelf()
        return {books={{bookId='41',title='合成普通书',finishReading=0,secret=0},
            {bookId='42',title='合成其他书',finishReading=0,secret=0},
            {bookId='CB_abc',title='合成导入书',finishReading=0,secret=0}},
            archive={{archiveId=1,name='合成分组',bookIds={'41','CB_abc'}}}}
    end
    remote(function(db)
        db:exec('CREATE TABLE remote(id INTEGER PRIMARY KEY,payload TEXT NOT NULL)');db:exec("INSERT INTO remote VALUES(1,'{}')")
        save(db,{books={['41']=0,CB_abc=0},posts=0,requests=0,forbidden=0,fault='normal'})
    end)
    local Settings=require('weread.lib.settings');local new=Settings.new
    function Settings:new()
        local value=new(self)
        value.store:saveSetting('auth_schema_version',1);value.store:saveSetting('auth_epoch',1)
        value.store:saveSetting('account',{user_vid='900000',name='合成用户'});value:flush()
        assert(require('weread.lib.native_credentials'):new(value):save({vid='900000',accessToken='synthetic-reading-access',
            refreshToken='synthetic-reading-refresh',deviceId=string.rep('1',32)},value:get_auth_scope(),0,2))
        return value
    end
    local parent=tonumber(ffi.C.getpid());local base='https://i.weread.qq.com';local plugin
    local Client=require('weread.lib.client');local Contract=require('weread.lib.reading_state_change_contract')
    function Client:request(options)
        local headers=options.headers or {};local id=options.url:match('^https://i%.weread%.qq%.com/book/getProgress%?bookId=(.+)$')
        local writing=options.url==base..'/book/markstatus';local data=writing and json.decode(options.body)
        if writing then id=data.bookId end
        local kind=options.url==base..'/shelf/sync' and 'shelf' or id and not writing and 'progress' or writing and 'write'
        local allowed=kind and (kind=='shelf' or id=='41' or id=='CB_abc')
            and options.method==(writing and 'POST' or 'GET') and options.skip_cookie
            and options.persist_response_cookies==false and options.sensitive and headers.vid=='900000'
            and headers.accessToken=='synthetic-reading-access' and not headers.Cookie and not headers.Authorization
            and tonumber(ffi.C.getpid())~=parent
        if writing then
            local record=require('weread.lib.reading_state_change_store'):new(plugin.library_db,self):read()
            local fields=0;for _ in pairs(data) do fields=fields+1 end
            allowed=allowed and record and record.phase=='pending' and record.metadata.book_id==id
                and Contract.valid_metadata(record.metadata) and fields==5 and data.status==2
                and data.isCancel==(record.metadata.desired and 0 or 1)
                and data.auto==0 and data.finishInfo==0
        end
        local result=remote(function(db)
            db:exec('BEGIN IMMEDIATE');local value=load(db);value.requests=value.requests+1
            if not allowed then value.forbidden=value.forbidden+1;save(db,value);db:exec('COMMIT');return {reject=true} end
            if writing then
                value.posts=value.posts+1
                if value.fault~='no_change' then value.books[id]=data.isCancel==0 and 1 or 0 end
            end
            save(db,value);db:exec('COMMIT');return value
        end)
        assert(not result.reject);require('socket').sleep(.15)
        if writing and result.fault=='lost' then error('synthetic lost receipt',0) end
        if kind=='shelf' then return json.encode(shelf()),200 end
        if kind=='progress' then
            local flag=result.books[id]
            return json.encode({book={bookId=id,isStartReading=flag,startReadingTime=flag==1 and 123 or 0,
                chapterUid=0,chapterIdx=0,chapterOffset=0,progress=0,summary='',readingTime=0,recordReadingTime=0,ttsTime=0}}),200
        end
        return json.encode({status=1}),200
    end
    local UI=require('ui/uimanager');local socket=require('socket')
    local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
    for _,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
    expect(#Loader.enabled_plugins==1)
    local FM=require('apps/filemanager/filemanager');FM:showFiles(home);plugin=assert(FM.instance.weread)
    plugin.isNetworkOnline=function() return true end;plugin.isNetworkConnected=plugin.isNetworkOnline
    expect(plugin.library_db:cacheShelf(shelf().books,shelf().archive))
    local notices={};local old_info=plugin.showInfo
    function plugin:showInfo(text) notices[#notices+1]=text;return old_info(self,text) end
    local tr=require('weread.lib.plugin_util').tr
    local function tick() UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01) end
    local function wait(test) local deadline=socket.gettime()+45;while not test() do assert(socket.gettime()<deadline);tick() end end
    local function close_notice()
        local top=UI:getTopmostVisibleWidget();if top and top~=plugin._shelf_state_menu and top~=plugin.ui then UI:close(top) end
    end
    local function row(menu,label)
        for _,item in ipairs(menu.item_table) do if item.text==tr(label) then return item end end
        error('missing reading status action')
    end
    local function open(id,resolving)
        notices={};assert(plugin:showShelfState(id));local menu=assert(plugin._shelf_state_menu)
        menu:onMenuSelect(row(menu,resolving and 'Check pending started-reading change' or 'Change started-reading status'))
        wait(function() return plugin._reading_state_change_ui and plugin._reading_state_change_ui.dialog end)
        return plugin._reading_state_change_ui.dialog
    end
    local function submit(id,fault,expected_flag)
        change(function(value) value.fault=fault end)
        local dialog=open(id,false)
        expect(dialog.ok_text==tr(expected_flag==1 and 'Mark as started' or 'Mark as not started'))
        UI:forceRePaint();Device.screen:shot(assert(os.getenv('WEREAD_READING_CHANGE_SHOTS'))..'/'..id..'-'..fault..'-'..expected_flag..'.png')
        report.screenshots=report.screenshots+1
        local heartbeat=false;UI:scheduleIn(.1,function() heartbeat=true end)
        dialog.ok_callback();wait(function() return heartbeat and not plugin._reading_state_change_ui end)
        expect(notices[#notices]==tr('The current started-reading status was verified in WeRead.'))
        expect(state().books[id]==expected_flag and plugin._reading_state_change_service:pending()==nil)
        close_notice();require('weread.ui.shelf_state').cancel(plugin)
    end
    report.phase='roundtrip'
    submit('41','normal',1);submit('41','normal',0)
    submit('CB_abc','normal',1);submit('CB_abc','normal',0)
    submit('41','lost',1);submit('41','lost',0)
    report.phase='pending'
    change(function(value) value.fault='no_change' end)
    local before=state().posts;local dialog=open('41',false);dialog.ok_callback()
    wait(function() return not plugin._reading_state_change_ui end)
    expect(state().posts==before+1 and plugin._reading_state_change_service:pending()~=nil)
    expect(notices[#notices]==tr('The started-reading change is unconfirmed. It will not be sent again automatically.'))
    close_notice()
    local menu=assert(plugin._shelf_state_menu)
    for _,label in ipairs({'Change finished mark','Change private reading','Change cloud pin','Change cloud membership'}) do
        menu:onMenuSelect(row(menu,label))
        expect(state().posts==before+1 and notices[#notices]==tr('A previous started-reading change is unconfirmed. Check it before making another change.'))
        close_notice()
    end
    require('weread.ui.shelf_state').cancel(plugin)
    plugin._reading_state_change_service=nil
    dialog=open('41',true);expect(dialog.ok_text==tr('Keep current reading status'))
    dialog.ok_callback();expect(plugin._reading_state_change_ui.dialog~=dialog)
    plugin._reading_state_change_ui.dialog.ok_callback();expect(not plugin._reading_state_change_ui)
    expect(state().posts==before+1 and plugin._reading_state_change_service:pending()==nil)
    close_notice();require('weread.ui.shelf_state').cancel(plugin)
    local remote_state=state();expect(remote_state.forbidden==0 and remote_state.posts==7)
    report.posts=remote_state.posts;report.requests=remote_state.requests;report.result='PASS';report.phase='complete'
end)
if not ok then report.reason=tostring(reason):gsub('[\r\n]',' '):sub(1,150) end
print('\nWEREAD_READING_CHANGE_RESULT='..json.encode(report))
os.exit(ok and 0 or 1)
