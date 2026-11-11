-- Synthetic native widgets, real worker processes/SQLite and fixed transport.
require('ffi').log=function() end
require('setupkoenv')
local ffi,json=require('ffi'),require('json');require('ffi/posix_h')
local mode=arg[1];local report={result='UNVERIFIED',mode=mode,phase='init',checks=0,screenshots=0,requests=0,posts=0,forbidden=0}
local plugin
local function expect(value) report.checks=report.checks+1;assert(value) end
local ok,reason=pcall(function()
    local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/weread%-thought%-[%w_]+/profile$'))
    assert(mode=='live' or mode=='reopen');local source=home..'/plugins/weread.koplugin';package.path=source..'/?.lua;'..package.path
    G_defaults=require('luadefaults'):open();G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
    G_reader_settings:saveSetting('language','zh_CN');require('gettext').changeLang('zh_CN')
    G_reader_settings:saveSetting('virtual_keyboard_enabled',true)
    G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
    local Device=require('device');require('document/canvascontext'):init(Device)
    local F=assert(loadfile('/source/spec/helpers/thought_edit_fixture.lua'))()
    local codec={json_encode=function(_self,v) return json.encode(v) end,json_decode=function(_self,v) return json.decode(v) end}
    local SQ3=require('lua-ljsqlite3/init');local remote_path=home..'/synthetic-remote.db'
    local function remote(task)
        local db=SQ3.open(remote_path);db:exec('PRAGMA journal_mode=WAL');db:exec('PRAGMA busy_timeout=3000')
        local success,value=pcall(task,db);db:close();assert(success);return value
    end
    local function load(db)
        local raw=db:rowexec('SELECT payload FROM remote WHERE id=1');return json.decode(raw)
    end
    local function save(db,value)
        local stmt=db:prepare('UPDATE remote SET payload=? WHERE id=1');stmt:bind(json.encode(value)):step();stmt:close()
    end
    if mode=='live' then remote(function(db)
        db:exec('CREATE TABLE remote(id INTEGER PRIMARY KEY,payload TEXT NOT NULL)')
        db:exec([[INSERT INTO remote(id,payload) VALUES(1,'{}')]])
        save(db,{snapshot=F.snapshot(codec),posts=0,requests=0,forbidden=0,mode='normal'})
    end) end
    local function state() return remote(load) end
    local function fault(value) remote(function(db) local v=load(db);v.mode=value;save(db,v) end) end
    local parent=tonumber(ffi.C.getpid());local base='https://i.weread.qq.com'
    local paths={
        [base..'/review/list?bookId=900001&listType=11&listMode=0&mine=1&synckey=0&count=20']='thoughts',
        [base..'/book/bookmarklist?bookId=900001&synckey=0']='marks',[base..'/book/info?bookId=900001']='metadata',
        [base..'/review/add']='create',[base..'/review/useredit']='edit',[base..'/review/delete']='delete'}
    local Client=require('weread.lib.client')
    function Client:request(options)
        local kind=paths[options.url];local writing=kind=='create' or kind=='edit' or kind=='delete'
        local h=options.headers or {};local body=writing and type(options.body)=='string' and json.decode(options.body)
        local allowed=kind and tonumber(ffi.C.getpid())~=parent and options.method==(writing and 'POST' or 'GET')
            and options.skip_cookie and options.persist_response_cookies==false and options.sensitive
            and h.vid=='900000' and h.accessToken=='synthetic-thought-access' and not h.Cookie and not h.Authorization
            and (writing and require('weread.lib.thought_edit_contract').validate_body(kind,body) or not writing and not options.body)
        local result=remote(function(db)
            db:exec('BEGIN IMMEDIATE');local v=load(db);v.requests=v.requests+1
            if not allowed then v.forbidden=v.forbidden+1;save(db,v);db:exec('COMMIT');return {reject=true} end
            if writing then
                v.posts=v.posts+1
                if v.mode~='no_change' then
                    if kind=='create' then
                        local row=F.row();row.reviewId='synthetic-created';row.content=body.content;row.isPrivate=body.isPrivate
                        v.snapshot.reviews[#v.snapshot.reviews+1]=row
                    else
                        local rows=json.decode('[]')
                        for _i,row in ipairs(v.snapshot.reviews) do
                            if row.reviewId~=body.reviewId then rows[#rows+1]=row
                            elseif kind=='edit' then row.content=body.content;rows[#rows+1]=row end
                        end
                        v.snapshot.reviews=rows
                    end
                end
            end
            save(db,v);db:exec('COMMIT');return v
        end)
        assert(not result.reject)
        local socket=require('socket');socket.sleep(.15)
        if writing and result.mode=='cancel_after_send' then socket.sleep(5) end
        if writing and result.mode=='lost_ack' then error('synthetic timeout',0) end
        if kind=='thoughts' then
            local rows=json.decode('[]');for _i,row in ipairs(result.snapshot.reviews) do
                local copy=json.decode(json.encode(row));copy.bookId='900001';copy.userVid=900000;copy.chapterUid=tostring(copy.chapterUid)
                rows[#rows+1]={reviewId=copy.reviewId,review=copy}
            end
            return json.encode({reviews=rows,totalCount=#rows,hasMore=0}),200
        end
        return json.encode(kind=='marks' and F.marks(codec) or kind=='metadata' and {bookId='900001',version=77} or {succ=1}),200
    end
    local Settings=require('weread.lib.settings');local settings_new=Settings.new
    function Settings:new()
        local value=settings_new(self)
        if mode=='live' then
            value.store:saveSetting('auth_schema_version',1);value.store:saveSetting('auth_epoch',1)
            value.store:saveSetting('account',{user_vid='900000',name='合成用户'});value:flush()
            local saved=require('weread.lib.native_credentials'):new(value):save({vid='900000',accessToken='synthetic-thought-access',
                refreshToken='synthetic-thought-refresh',deviceId=string.rep('1',32)},value:get_auth_scope(),0,0);assert(saved)
        end
        return value
    end
    local UI=require('ui/uimanager');local socket=require('socket')
    local workers={};local Worker=require('weread.lib.memory_worker');local start=Worker.start
    function Worker:start(...)
        local started=start(self,...);if self.job then workers[#workers+1]={pid=self.job.pid,runner=self.runner} end;return started
    end
    local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
    for _i,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
    expect(#Loader.enabled_plugins==1)
    local FM=require('apps/filemanager/filemanager');FM:showFiles(home);plugin=assert(FM.instance.weread)
    local online=true;plugin.isNetworkOnline=function() return online end;plugin.isNetworkConnected=plugin.isNetworkOnline
    local Cache=require('weread.lib.my_cloud_marks_store');local cache=Cache:new(plugin.library_db,plugin.client,'thoughts')
    local Journal=require('weread.lib.thought_edit_store');local journal=Journal:new(plugin.library_db,plugin.client)
    if mode=='live' then
        expect(cache:write(F.snapshot(codec)))
        expect(Cache:new(plugin.library_db,plugin.client):write(require('weread.lib.my_cloud_marks').project(codec,F.marks(codec),'900001','900000',1000)))
    end
    local tr=require('weread.lib.plugin_util').tr
    local function tick() UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01) end
    local function wait(test)
        local deadline=socket.gettime()+65;while not test() do assert(socket.gettime()<deadline);tick() end
    end
    local function shot(name)
        UI:forceRePaint();Device.screen:shot(assert(os.getenv('WEREAD_THOUGHT_SHOTS'))..'/'..mode..'-'..name..'.png');report.screenshots=report.screenshots+1
    end
    local TextSmoke=assert(loadfile('/source/spec/koreader/thought_text_smoke.lua'))()
    report.font=TextSmoke.run()
    local function open(thoughts)
        plugin:showBookMenu{book_id='900001',title='合成测试书籍',chapters={}}
        local detail=assert(plugin._book_detail_view)
        for _i,button in ipairs(detail._action_buttons) do
            if button.text==tr(thoughts and 'My cloud thoughts' or 'My cloud highlights') then button.callback();return assert(plugin._my_marks_owner) end
        end
        error('missing personal entry')
    end
    local function select(owner,id)
        for index,item in ipairs(owner.menu.item_table) do if item.my_note_id==id or item.text==tr(id) then
            owner.menu:onGotoPage(owner.menu:getPageNumber(index));owner.menu:onMenuSelect(item);return
        end end
        error('missing personal row')
    end
    local function tap(owner,id)
        UI:forceRePaint()
        local dialog=assert(owner.menu._shelf_popup);local button=assert(dialog.button_table:getButtonById(id));button:onTapSelectButton()
    end
    local function notice(owner) wait(function() return not owner.editor end);local top=UI:getTopmostVisibleWidget();if top~=owner.menu then UI:close(top) end end
    local function confirm(owner)
        wait(function() local ctx=owner.editor;return ctx and ctx.service.preview end)
        tap(owner,'confirm_thought_change')
    end
    if mode=='live' then
        report.phase='draft'
        local owner=open(false);select(owner,'synthetic-mark');tap(owner,'thought_create')
        owner.editor.input:setInputText('合成本机草稿 😀\n可在离线后继续。');expect(TextSmoke.input(owner.editor.input,{['😀']=true})==1);shot('draft')
        tap(owner,'save_thought_draft');notice(owner);expect(#journal:drafts()==1 and state().posts==0)
        select(owner,'Local thought drafts');local list=owner.menu._shelf_popup;list:onMenuSelect(list.item_table[1]);tap(owner,'resume_thought_draft')
        expect(owner.editor.input:getInputText():find('合成本机草稿',1,true))
        owner.editor.input:setInputText('合成私密想法 😀\n原生编辑器第二行。')
        online=false;tap(owner,'submit_thought');expect(owner.editor~=nil and state().posts==0)
        UI:close(UI:getTopmostVisibleWidget());online=true
        tap(owner,'submit_thought');local heart=false;UI:scheduleIn(.1,function() heart=true end);wait(function() return heart end)
        expect(owner.editor~=nil);confirm(owner);notice(owner)
        expect(state().posts==1 and #state().snapshot.reviews==2 and journal:read().phase=='idle' and #journal:drafts()==0)
        report.phase='edit'
        owner=open(true);select(owner,'synthetic-created');tap(owner,'thought_edit');owner.editor.input:setInputText('合成编辑后想法 😀\n第二行仍完整。')
        tap(owner,'submit_thought');wait(function() return owner.editor.service.preview end);expect(TextSmoke.emoji(owner.editor.dialog.box_widget,{['😀']=true})==1);shot('confirm-edit');fault('lost_ack')
        confirm(owner);notice(owner)
        expect(state().posts==2 and state().snapshot.reviews[2].content=='合成编辑后想法 😀\n第二行仍完整。' and journal:read().phase=='idle')
        report.phase='delete'
        fault('normal');select(owner,'synthetic-created');tap(owner,'thought_delete');confirm(owner);notice(owner)
        expect(state().posts==3 and #state().snapshot.reviews==1 and journal:read().phase=='idle')
        report.phase='stale-reference'
        select(owner,'synthetic-note');tap(owner,'thought_edit');owner.editor.input:setInputText('合成旧版本编辑草稿')
        remote(function(db) local v=load(db);v.snapshot.reviews[1].content='合成另一设备修改';save(db,v) end)
        tap(owner,'submit_thought');notice(owner)
        expect(state().posts==3 and journal:read().phase=='idle' and #journal:drafts()==1)
        remote(function(db) local v=load(db);v.snapshot=F.snapshot(codec);save(db,v) end)
        -- View and delete a stale draft without exposing a submit action.
        select(owner,'Local thought drafts');local drafts=owner.menu._shelf_popup;drafts:onMenuSelect(drafts.item_table[1])
        tap(owner,'delete_thought_draft');notice(owner);expect(#journal:drafts()==0)
        report.phase='unknown-readback'
        owner=open(false);select(owner,'synthetic-mark');tap(owner,'thought_create');owner.editor.input:setInputText('合成未确认的想法')
        tap(owner,'submit_thought');wait(function() return owner.editor.service.preview end);fault('no_change');confirm(owner);notice(owner)
        expect(state().posts==4 and journal:read().phase=='pending' and #journal:drafts()==1)
        select(owner,'Check last thought change');wait(function() return owner.editor and owner.editor.service.preview end)
        expect(not owner.editor.service.preview.confirmed);tap(owner,'accept_thought_state')
        local accept=owner.menu._shelf_popup;expect(type(accept.ok_callback)=='function');accept.ok_callback();notice(owner)
        expect(state().posts==4 and journal:read().phase=='idle' and #journal:drafts()==1)
        fault('normal')
        report.phase='cancel-unsent'
        owner=open(false);select(owner,'synthetic-mark');tap(owner,'thought_create');owner.editor.input:setInputText('合成未提交草稿')
        tap(owner,'submit_thought');wait(function() return owner.editor.service.preview end);local stale=owner.menu._shelf_popup
        UI:close(stale);expect(not owner.editor and journal:read().phase=='idle' and #journal:drafts()==1 and state().posts==4)
        report.phase='cancel-sent'
        select(owner,'synthetic-mark');tap(owner,'thought_create');owner.editor.input:setInputText('合成中断提交后的想法')
        tap(owner,'submit_thought');wait(function() return owner.editor.service.preview end);fault('cancel_after_send');confirm(owner)
        wait(function() return state().posts==5 end)
        UI:close(owner.menu._shelf_popup)
        expect(not owner.editor and journal:read().phase=='pending' and #journal:drafts()==1)
        shot('pending');fault('normal')
        expect(state().forbidden==0)
    else
        report.phase='reconcile-restart'
        expect(journal:read().phase=='pending' and #journal:drafts()==1 and state().posts==5)
        local owner=open(true);select(owner,'Check last thought change');notice(owner)
        expect(journal:read().phase=='idle' and #journal:drafts()==0 and state().posts==5)
        expect(cache:read('900001').reviews[2].content=='合成中断提交后的想法')
        -- Cleanup is synthetic only. The original thought remains exact.
        select(owner,'synthetic-created');tap(owner,'thought_delete');confirm(owner);notice(owner)
        expect(state().posts==6 and #state().snapshot.reviews==1 and state().snapshot.reviews[1].content==F.row().content)
        shot('restored')
    end
    plugin:closeWeReadUI()
    for _i,worker in ipairs(workers) do wait(function() return worker.runner.done(worker.pid) end) end
    local value=state();report.requests,report.posts,report.forbidden=value.requests,value.posts,value.forbidden
    expect(value.forbidden==0)
    local settings_file=assert(io.open(plugin.settings.settings_file));local bytes=settings_file:read('*a');settings_file:close()
    expect(not bytes:find('合成私密想法',1,true) and not bytes:find('合成本机草稿',1,true))
    report.phase,report.result='complete','PASS'
end)
if plugin then pcall(plugin.closeWeReadUI,plugin) end
if not ok then
    report.failed_line=tonumber(type(reason)=='string' and reason:match('thought_editor_probe%.lua:(%d+):')) or 0
    report.error_class=type(reason);report.synthetic_error=tostring(reason)
end
io.write('\nWEREAD_THOUGHT_EDITOR_RESULT='..json.encode(report)..'\n')
os.exit(ok and 0 or 1)
