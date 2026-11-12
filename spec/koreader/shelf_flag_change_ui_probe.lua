-- Synthetic native menus, production services/workers and actual SQLite.
-- A shared local fixture replaces transport; no Internet request can escape.
require('ffi').log=function() end
require('setupkoenv')
local ffi,json=require('ffi'),require('json');require('ffi/posix_h')
local mode=arg[1];local plugin,state_reader;local workers={}
local report={result='UNVERIFIED',mode=mode,phase='init',checks=0,requests=0,posts=0,forbidden=0,screenshots=0,workers_reaped=false}
local function expect(value)
    report.checks=report.checks+1
    if not value then error('shelf_flag_change_ui_probe.lua:'..debug.getinfo(2,'l').currentline..': assertion',0) end
end
local ok,reason=pcall(function()
    local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/weread%-private%-[%w_]+/profile$'))
    local source=home..'/plugins/weread.koplugin';package.path=source..'/?.lua;'..package.path
    assert(mode=='live' or mode=='reopen')
    G_defaults=require('luadefaults'):open();G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
    G_reader_settings:saveSetting('language','zh_CN');require('gettext').changeLang('zh_CN')
    G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
    local Device=require('device');require('document/canvascontext'):init(Device)
    local SQ3=require('lua-ljsqlite3/init');local path=home..'/synthetic-private-remote.db'
    local function remote(task)
        local db=SQ3.open(path);db:exec('PRAGMA busy_timeout=3000');local good,value=pcall(task,db);db:close();assert(good);return value
    end
    local function load(db) return json.decode(db:rowexec('SELECT payload FROM remote WHERE id=1')) end
    local function save(db,value) local stmt=db:prepare('UPDATE remote SET payload=? WHERE id=1');stmt:bind(json.encode(value)):step();stmt:close() end
    local function shelf() return {books={{bookId='41',title='合成测试书籍：私密阅读',finishReading=0,secret=0},
        {bookId='42',title='合成其他书籍',finishReading=1,secret=0}},archive={}} end
    local function progress() return {book={bookId='41',chapterUid=2,chapterIdx=2,chapterOffset=100,progress=37.5}} end
    if mode=='live' then remote(function(db)
        db:exec('CREATE TABLE remote(id INTEGER PRIMARY KEY,payload TEXT NOT NULL)');db:exec([[INSERT INTO remote VALUES(1,'{}')]])
        save(db,{shelf=shelf(),progress=progress(),posts=0,requests=0,forbidden=0,fault='normal'})
    end) end
    local function state() return remote(load) end
    state_reader=state
    local function change(task) remote(function(db) db:exec('BEGIN IMMEDIATE');local value=load(db);task(value);save(db,value);db:exec('COMMIT') end) end
    local function fault(value) change(function(v) v.fault=value end) end
    local parent=tonumber(ffi.C.getpid());local base='https://i.weread.qq.com'
    local Client=require('weread.lib.client');local Contract=require('weread.lib.shelf_flag_change_contract')
    function Client:request(options)
        local writing=options.url==base..'/book/secret';local h=options.headers or {}
        local kind=options.url==base..'/shelf/sync' and 'shelf' or options.url==base..'/book/getProgress?bookId=41' and 'progress'
            or options.url==base..'/book/info?bookId=41' and 'metadata' or writing and 'write'
        local body=writing and json.decode(options.body)
        local allowed=kind and options.method==(writing and 'POST' or 'GET') and tonumber(ffi.C.getpid())~=parent
            and options.skip_cookie and options.persist_response_cookies==false and options.sensitive
            and h.vid=='900000' and h.accessToken=='synthetic-private-access' and not h.Cookie and not h.Authorization
        if writing then
            local record=require('weread.lib.shelf_flag_change_store'):new(plugin.library_db,self):read()
            local desired=body.private==1
            local expected=Contract.request('41',desired)
            allowed=allowed and record and record.phase=='pending' and record.metadata.desired==desired
                and body.private==expected.private and type(body.bookIds)=='table' and #body.bookIds==1 and body.bookIds[1]=='41'
            local count=0;for _i in pairs(body) do count=count+1 end;allowed=allowed and count==2
        end
        local result=remote(function(db)
            db:exec('BEGIN IMMEDIATE');local value=load(db);value.requests=value.requests+1
            if not allowed then value.forbidden=value.forbidden+1;save(db,value);db:exec('COMMIT');return {reject=true} end
            if writing then
                value.posts=value.posts+1
                if value.fault~='no_change' then value.shelf.books[1].secret=body.private end
                if value.fault=='unrelated' then value.shelf.books[2].secret=1 end
            end
            save(db,value);db:exec('COMMIT');return value
        end)
        assert(not result.reject);require('socket').sleep(.12)
        if writing and result.fault=='delayed' then require('socket').sleep(5) end
        if writing and result.fault=='lost_ack' then error('synthetic timeout',0) end
        if kind=='progress' and result.fault=='no_position' then return json.encode({errcode=-10102}),200 end
        return json.encode(kind=='shelf' and result.shelf or kind=='progress' and result.progress
            or kind=='metadata' and {bookId='41',title='合成测试书籍：私密阅读',version=77} or {status=1}),200
    end
    local Settings=require('weread.lib.settings');local settings_new=Settings.new
    function Settings:new()
        local value=settings_new(self)
        if mode=='live' then
            value.store:saveSetting('auth_schema_version',1);value.store:saveSetting('auth_epoch',1)
            value.store:saveSetting('account',{user_vid='900000',name='合成用户'});value:flush()
            assert(require('weread.lib.native_credentials'):new(value):save({vid='900000',accessToken='synthetic-private-access',
                refreshToken='synthetic-private-refresh',deviceId=string.rep('1',32)},value:get_auth_scope(),0,2))
        end
        return value
    end
    local UI=require('ui/uimanager');local socket=require('socket')
    local Worker=require('weread.lib.memory_worker');local start=Worker.start
    function Worker:start(...) local value=start(self,...);if self.job then workers[#workers+1]={pid=self.job.pid,runner=self.runner} end;return value end
    local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
    for _i,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end;expect(#Loader.enabled_plugins==1)
    local FM=require('apps/filemanager/filemanager');FM:showFiles(home);plugin=assert(FM.instance.weread)
    plugin.isNetworkOnline=function() return true end;plugin.isNetworkConnected=plugin.isNetworkOnline
    if mode=='live' then expect(plugin.library_db:cacheShelf(shelf().books,{})) end
    local Journal=require('weread.lib.shelf_flag_change_store');local journal=Journal:new(plugin.library_db,plugin.client)
    local tr=require('weread.lib.plugin_util').tr
    local function tick() UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01) end
    local function wait(test) local until_=socket.gettime()+65;while not test() do assert(socket.gettime()<until_);tick() end end
    local function shot(name) UI:forceRePaint();Device.screen:shot(assert(os.getenv('WEREAD_PRIVATE_SHOTS'))..'/'..mode..'-'..name..'.png');report.screenshots=report.screenshots+1 end
    local function open(resolving)
        plugin:showBookMenu{book_id='41',title='合成测试书籍：私密阅读',chapters={}}
        local detail=assert(plugin._book_detail_view)
        for _i,button in ipairs(detail._action_buttons) do if button.text==tr('Shelf status') then button.callback();break end end
        local menu=assert(plugin._shelf_state_menu)
        for _i,item in ipairs(menu.item_table) do if item.text==tr(resolving and 'Check pending private-reading change' or 'Change private reading') then
            menu:onMenuSelect(item);wait(function() return plugin._shelf_flag_change_ui and plugin._shelf_flag_change_ui.dialog end)
            return plugin._shelf_flag_change_ui.dialog
        end end;error('missing private-reading entry')
    end
    local function notice()
        wait(function() return not plugin._shelf_flag_change_ui end)
        local top=UI:getTopmostVisibleWidget();if top~=plugin._shelf_state_menu then UI:close(top) end
    end
    local function confirm(view)
        UI:forceRePaint();local beat=false;UI:scheduleIn(.1,function() beat=true end);view.ok_callback();notice();wait(function() return beat end);expect(beat)
    end
    local function accept(changed)
        local view=open(true)
        if changed then
            expect(view.text:find(tr('The reading position has changed or could not be checked. Ending this check does not restore the earlier position.'),1,true))
            shot('removed-pending-check')
        end
        view.ok_callback();expect(plugin._shelf_flag_change_ui and plugin._shelf_flag_change_ui.dialog~=view)
        confirm(plugin._shelf_flag_change_ui.dialog);expect(journal:read().phase=='idle')
    end
    local function saved(value) expect(require('weread.lib.shelf_flags').display(plugin.library_db:getShelfStatus('41').book,'private')==value) end
    if mode=='live' then
        report.phase='login-and-mutual-exclusion'
        plugin:showShelfState('41');local capture=plugin.settings.get_auth_scope;plugin.settings.get_auth_scope=function() return nil end
        require('weread.ui.shelf_flag_change').open(plugin,'41')
        expect(not plugin._shelf_flag_change_ui and UI:getTopmostVisibleWidget().text==tr('Authorize or renew E-Ink login in settings, then try again.'))
        UI:close(UI:getTopmostVisibleWidget())
        require('weread.ui.shelf_membership_write').open(plugin,'41')
        expect(not plugin._shelf_membership_ui and UI:getTopmostVisibleWidget().text==tr('Authorize or renew E-Ink login in settings, then try again.'))
        UI:close(UI:getTopmostVisibleWidget());plugin.settings.get_auth_scope=capture;expect(state().posts==0)
        local member_journal=require('weread.lib.shelf_membership_journal'):new(plugin.settings,plugin.client)
        local member_scope=plugin.settings:get_auth_scope();local pending=assert(member_journal:begin(member_scope,'41','remove'))
        require('weread.ui.shelf_flag_change').open(plugin,'41');expect(not plugin._shelf_flag_change_ui and state().posts==0)
        UI:close(UI:getTopmostVisibleWidget());expect(member_journal:finish(member_scope,pending))
        local finish_journal=require('weread.lib.finish_change_store'):new(plugin.library_db,plugin.client)
        local finish_metadata=require('weread.lib.finish_change_contract').make(shelf(),progress(),'41',true).metadata
        local finish_record=assert(finish_journal:begin(finish_metadata,plugin.settings:get_auth_scope(),finish_journal:read().revision))
        require('weread.ui.shelf_flag_change').open(plugin,'41');expect(not plugin._shelf_flag_change_ui and state().posts==0)
        UI:close(UI:getTopmostVisibleWidget());expect(finish_journal:finish(finish_record,'prepared'))
        report.phase='mark';local view=open();expect(view.ok_text==tr('Make private') and state().posts==0);shot('mark-confirmation');confirm(view)
        expect(state().posts==1 and journal:read().phase=='idle');saved(true)
        report.phase='unmark';fault('lost_ack');view=open();expect(view.ok_text==tr('Make public'));confirm(view)
        expect(state().posts==2 and journal:read().phase=='idle');saved(false);fault('normal')
        report.phase='cancel'
        view=open();view.cancel_callback();expect(state().posts==2 and not plugin._shelf_flag_change_ui and journal:read().phase=='idle')
        view=open();plugin:closeWeReadUI();view.ok_callback();expect(state().posts==2 and not plugin._shelf_flag_change_ui)
        view=open();plugin:onWeReadAccountChanged();view.ok_callback();expect(state().posts==2 and not plugin._shelf_flag_change_ui)
        report.phase='changed-preflight';view=open();change(function(v) v.shelf.books[1].finishReading=1 end);confirm(view)
        expect(state().posts==2 and journal:read().phase=='idle');change(function(v) v.shelf=shelf() end)
        report.phase='unrelated-readback';view=open();fault('unrelated');confirm(view)
        expect(state().posts==3 and journal:read().phase=='pending')
        change(function(v) table.remove(v.shelf.books,1);v.fault='no_position' end)
        accept(true);expect(state().posts==3 and plugin.library_db:getShelfStatus('41').present==false)
        change(function(v) v.shelf=shelf();v.fault='normal' end)
        report.phase='unknown-readback';view=open();fault('no_change');confirm(view)
        expect(state().posts==4 and journal:read().phase=='pending')
        require('weread.ui.shelf_membership_write').open(plugin,'41')
        expect(not plugin._shelf_membership_ui and state().posts==4);UI:close(UI:getTopmostVisibleWidget())
        require('weread.ui.finish_change').open(plugin,'41')
        expect(not plugin._finish_change_ui and state().posts==4);UI:close(UI:getTopmostVisibleWidget())
        accept();expect(state().posts==4);saved(false);fault('normal')
        report.phase='save-failure'
        local db=assert(plugin.library_db:open());db:execsql([[CREATE TRIGGER reject_private_cache BEFORE INSERT ON shelf_state
            WHEN NEW.name='membership_snapshot' BEGIN SELECT RAISE(ABORT,'synthetic cache failure'); END]]);db:close()
        view=open();confirm(view);expect(state().posts==5 and journal:read().phase=='pending');saved(false)
        db=assert(plugin.library_db:open());db:execsql('DROP TRIGGER reject_private_cache');db:close();accept();saved(true)
        view=open();confirm(view);expect(state().posts==6 and journal:read().phase=='idle');saved(false)
        report.phase='cancel-after-dispatch';view=open();fault('delayed');view.ok_callback();wait(function() return state().posts==7 end)
        plugin.busy_message:onTapClose();expect(not plugin._shelf_flag_change_ui and journal:read().phase=='pending');shot('pending')
        fault('normal')
    else
        report.phase='read-only-reopen';expect(state().posts==7 and journal:read().phase=='pending');accept();expect(state().posts==7);saved(true)
        report.phase='restore';local view=open();confirm(view);expect(state().posts==8 and journal:read().phase=='idle');saved(false);shot('restored')
        expect(state().shelf.books[2].secret==0 and state().shelf.books[2].finishReading==1 and state().progress.book.chapterOffset==100)
    end
    plugin:closeWeReadUI();for _i,worker in ipairs(workers) do wait(function() return worker.runner.done(worker.pid) end) end
    report.workers_reaped=true;local value=state();report.requests,report.posts,report.forbidden=value.requests,value.posts,value.forbidden
    expect(value.forbidden==0);report.phase='complete';report.result='PASS'
end)
if plugin then pcall(plugin.closeWeReadUI,plugin) end
if state_reader then
    local read,value=pcall(state_reader)
    if read then report.requests,report.posts,report.forbidden=value.requests,value.posts,value.forbidden end
end
local deadline=require('socket').gettime()+5
local reaped=true
for _i,worker in ipairs(workers) do
    while not worker.runner.done(worker.pid) and require('socket').gettime()<deadline do require('socket').sleep(.01) end
    if not worker.runner.done(worker.pid) then reaped=false end
end
report.workers_reaped=reaped
if not ok then report.failed_line=tonumber(type(reason)=='string' and reason:match('shelf_flag_change_ui_probe%.lua:(%d+):')) or 0 end
io.write('\nWEREAD_PRIVATE_UI_RESULT='..json.encode(report)..'\n');os.exit(ok and 0 or 1)
