-- Synthetic native menus, production worker and SQLite; no public network.
require('ffi').log=function()end
require('setupkoenv')
local ffi,json=require('ffi'),require('json');require('ffi/posix_h')
local mode=arg[1];local plugin,state_reader;local workers={}
local report={result='UNVERIFIED',mode=mode,phase='init',checks=0,requests=0,posts=0,forbidden=0,workers_reaped=false}
local function expect(value)
    report.checks=report.checks+1
    if not value then error('cloud_pin_ui_probe.lua:'..debug.getinfo(2,'l').currentline..': assertion',0) end
end
local ok,reason=pcall(function()
    local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/weread%-cloud%-pin%-[%w_]+/profile$'))
    local source=home..'/plugins/weread.koplugin';package.path=source..'/?.lua;'..package.path
    assert(mode=='live' or mode=='reopen')
    G_defaults=require('luadefaults'):open();G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
    G_reader_settings:saveSetting('language','zh_CN');require('gettext').changeLang('zh_CN')
    G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
    local Device=require('device');require('document/canvascontext'):init(Device)
    local SQ3=require('lua-ljsqlite3/init');local path=home..'/synthetic-pin-remote.db'
    local function remote(task)
        local db=SQ3.open(path);db:exec('PRAGMA busy_timeout=3000');local good,value=pcall(task,db);db:close();assert(good);return value
    end
    local function load(db)return json.decode(db:rowexec('SELECT payload FROM remote WHERE id=1'))end
    local function save(db,value)local stmt=db:prepare('UPDATE remote SET payload=? WHERE id=1');stmt:bind(json.encode(value)):step();stmt:close()end
    local function shelf()return {books={{bookId='41',title='合成测试书籍',finishReading=0,secret=0},
        {bookId='42',title='合成其他书籍',finishReading=1,secret=0}},archive=json.decode('[]')}end
    local function progress()return {book={bookId='41',chapterUid=2,chapterIdx=2,chapterOffset=100,progress=37.5}}end
    if mode=='live' then remote(function(db)
        db:exec('CREATE TABLE remote(id INTEGER PRIMARY KEY,payload TEXT NOT NULL)');db:exec([[INSERT INTO remote VALUES(1,'{}')]])
        save(db,{shelf=shelf(),progress=progress(),posts=0,requests=0,forbidden=0,fault='normal'})
    end) end
    local function state()return remote(load)end;state_reader=state
    local function change(task)remote(function(db)db:exec('BEGIN IMMEDIATE');local value=load(db);task(value);save(db,value);db:exec('COMMIT')end)end
    local function fault(value)change(function(v)v.fault=value end)end
    local parent=tonumber(ffi.C.getpid());local base='https://i.weread.qq.com'
    local Client=require('weread.lib.client')
    function Client:request(options)
        local writing=options.url==base..'/shelf/top';local h=options.headers or {}
        local kind=options.url==base..'/shelf/sync' and 'shelf' or options.url==base..'/book/getProgress?bookId=41' and 'progress'
            or options.url==base..'/book/info?bookId=41' and 'metadata' or writing and 'write'
        local body=writing and json.decode(options.body)
        local allowed=kind and options.method==(writing and 'POST' or 'GET') and tonumber(ffi.C.getpid())~=parent
            and options.skip_cookie and options.persist_response_cookies==false and options.sensitive
            and h.vid=='900000' and h.accessToken=='synthetic-pin-access' and not h.Cookie and not h.Authorization
        if writing then
            local record=require('weread.lib.shelf_flag_change_store'):new(plugin.library_db,self):read()
            allowed=allowed and record and record.phase=='pending' and record.metadata.kind=='pinned'
                and body.isDel==(record.metadata.desired and 0 or 1) and type(body.bookIds)=='table'
                and #body.bookIds==1 and body.bookIds[1]=='41' and json.encode(body.albumIds)=='[]' and json.encode(body.archiveIds)=='[]'
            local count=0;for _i in pairs(body) do count=count+1 end;allowed=allowed and count==4
        end
        local result=remote(function(db)
            db:exec('BEGIN IMMEDIATE');local value=load(db);value.requests=value.requests+1
            if not allowed then value.forbidden=value.forbidden+1;save(db,value);db:exec('COMMIT');return {reject=true} end
            if writing then
                value.posts=value.posts+1
                if value.fault~='no_change' then value.shelf.books[1].isTop=body.isDel==0 and 1 or nil end
                if value.fault=='unrelated' then value.shelf.books[2].secret=1 end
            end
            save(db,value);db:exec('COMMIT');return value
        end)
        assert(not result.reject);require('socket').sleep(.12)
        if writing and result.fault=='lost_ack' then error('synthetic timeout',0) end
        return json.encode(kind=='shelf' and result.shelf or kind=='progress' and result.progress
            or kind=='metadata' and {bookId='41',title='合成测试书籍',version=77} or {succ=1}),200
    end
    local Settings=require('weread.lib.settings');local settings_new=Settings.new
    function Settings:new()
        local value=settings_new(self)
        if mode=='live' then
            value.store:saveSetting('auth_schema_version',1);value.store:saveSetting('auth_epoch',1)
            value.store:saveSetting('account',{user_vid='900000',name='合成用户'});value:flush()
            assert(require('weread.lib.native_credentials'):new(value):save({vid='900000',accessToken='synthetic-pin-access',
                refreshToken='synthetic-pin-refresh',deviceId=string.rep('1',32)},value:get_auth_scope(),0,2))
        end
        return value
    end
    local UI=require('ui/uimanager');local socket=require('socket')
    local Worker=require('weread.lib.memory_worker');local start=Worker.start
    function Worker:start(...)local value=start(self,...);if self.job then workers[#workers+1]={pid=self.job.pid,runner=self.runner} end;return value end
    local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
    for _i,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end;expect(#Loader.enabled_plugins==1)
    local FM=require('apps/filemanager/filemanager');FM:showFiles(home);plugin=assert(FM.instance.weread)
    plugin.isNetworkOnline=function()return true end;plugin.isNetworkConnected=plugin.isNetworkOnline
    if mode=='live' then expect(plugin.library_db:cacheShelf(shelf().books,{})) end
    local Journal=require('weread.lib.shelf_flag_change_store');local journal=Journal:new(plugin.library_db,plugin.client)
    local tr=require('weread.lib.plugin_util').tr
    local function tick()UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)end
    local function wait(test)local until_=socket.gettime()+65;while not test() do assert(socket.gettime()<until_);tick()end end
    local function open(resolving)
        plugin:showBookMenu{book_id='41',title='合成测试书籍',chapters={}}
        local detail=assert(plugin._book_detail_view)
        for _i,button in ipairs(detail._action_buttons) do if button.text==tr('Shelf status') then button.callback();break end end
        local menu=assert(plugin._shelf_state_menu)
        for _i,item in ipairs(menu.item_table) do if item.text==tr(resolving and 'Check pending cloud pin change' or 'Change cloud pin') then
            menu:onMenuSelect(item);wait(function()return plugin._shelf_flag_change_ui and plugin._shelf_flag_change_ui.dialog end)
            return plugin._shelf_flag_change_ui.dialog
        end end;error('missing cloud pin entry')
    end
    local function notice()
        wait(function()return not plugin._shelf_flag_change_ui end)
        local top=UI:getTopmostVisibleWidget();if top~=plugin._shelf_state_menu then UI:close(top) end
    end
    local function confirm(view)
        UI:forceRePaint();local beat=false;UI:scheduleIn(.1,function()beat=true end);view.ok_callback();notice();wait(function()return beat end);expect(beat)
    end
    local function saved(value)
        local book=plugin.library_db:getShelfStatus('41').book
        expect(require('weread.lib.shelf_flags').display(book,'pinned')==value)
    end
    local function status(value)
        for _,row in ipairs(assert(plugin._shelf_state_menu).item_table) do
            if row.text==tr('Pinned') then expect(row.mandatory==tr(value));return end
        end
        error('missing pin status')
    end
    if mode=='live' then
        report.phase='cancel';local view=open();expect(view.ok_text==tr('Pin in WeRead') and state().posts==0)
        expect(view.text:find(tr('The cloud did not provide the previous pin state.'),1,true))
        expect(view:getSize().h<=Device.screen:getHeight())
        UI:forceRePaint();Device.screen:shot(assert(os.getenv('WEREAD_PIN_SHOTS'))..'/pin-confirmation.png');view.cancel_callback()
        expect(state().posts==0 and not plugin._shelf_flag_change_ui and journal:read().phase=='idle')
        report.phase='pin';view=open();confirm(view);expect(state().posts==1 and journal:read().phase=='idle');saved(true);status('Yes')
        report.phase='unpin';view=open();expect(view.ok_text==tr('Unpin in WeRead'));confirm(view)
        expect(state().posts==2 and journal:read().phase=='idle');saved(nil);status('Not provided')
        report.phase='changed-preflight';view=open();change(function(v)v.shelf.books[2].secret=1 end);confirm(view)
        expect(state().posts==2 and journal:read().phase=='idle');change(function(v)v.shelf=shelf()end)
        report.phase='lost-ack';view=open();fault('lost_ack');confirm(view)
        expect(state().posts==3 and journal:read().phase=='pending');fault('normal')
    else
        report.phase='read-only-reopen';expect(state().posts==3 and journal:read().phase=='pending')
        local view=open(true);expect(view.ok_text==tr('Keep current cloud pin state'))
        view.ok_callback();expect(plugin._shelf_flag_change_ui and plugin._shelf_flag_change_ui.dialog~=view)
        confirm(plugin._shelf_flag_change_ui.dialog);expect(journal:read().phase=='idle' and state().posts==3);saved(true)
        report.phase='restore';view=open();expect(view.ok_text==tr('Unpin in WeRead'));confirm(view)
        expect(state().posts==4 and journal:read().phase=='idle');saved(nil)
        expect(state().shelf.books[2].secret==0 and state().shelf.books[2].finishReading==1 and state().progress.book.chapterOffset==100)
    end
    plugin:closeWeReadUI();for _i,worker in ipairs(workers) do wait(function()return worker.runner.done(worker.pid)end)end
    report.workers_reaped=true;local value=state();report.requests,report.posts,report.forbidden=value.requests,value.posts,value.forbidden
    expect(value.forbidden==0);report.phase='complete';report.result='PASS'
end)
if plugin then pcall(plugin.closeWeReadUI,plugin) end
if state_reader then local read,value=pcall(state_reader);if read then report.requests,report.posts,report.forbidden=value.requests,value.posts,value.forbidden end end
local deadline=require('socket').gettime()+5;local reaped=true
for _i,worker in ipairs(workers) do
    while not worker.runner.done(worker.pid) and require('socket').gettime()<deadline do require('socket').sleep(.01) end
    if not worker.runner.done(worker.pid) then reaped=false end
end
report.workers_reaped=reaped
if not ok then report.failed_line=tonumber(type(reason)=='string' and reason:match('cloud_pin_ui_probe%.lua:(%d+):')) or 0 end
io.write('\nWEREAD_CLOUD_PIN_UI_RESULT='..json.encode(report)..'\n');os.exit(ok and 0 or 1)
