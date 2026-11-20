-- Synthetic native menus, production services/workers and actual SQLite.
-- A shared local fixture replaces transport; no Internet request can escape.
require('ffi').log=function() end
require('setupkoenv')
local ffi,json=require('ffi'),require('json');require('ffi/posix_h')
local mode=arg[1];local plugin,state_reader;local workers={}
local report={result='UNVERIFIED',mode=mode,phase='init',checks=0,requests=0,posts=0,forbidden=0,screenshots=0,workers_reaped=false}
local function expect(value)
    report.checks=report.checks+1
    if not value then error('finish_change_ui_probe.lua:'..debug.getinfo(2,'l').currentline..': assertion',0) end
end
local ok,reason=pcall(function()
    local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/weread%-finish%-[%w_]+/profile$'))
    local source=home..'/plugins/weread.koplugin';package.path=source..'/?.lua;'..package.path
    assert(mode=='live' or mode=='reopen' or mode=='offline_reopen' or mode=='retry_reopen')
    G_defaults=require('luadefaults'):open();G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
    G_reader_settings:saveSetting('language','zh_CN');require('gettext').changeLang('zh_CN')
    G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
    local Device=require('device');require('document/canvascontext'):init(Device)
    local SQ3=require('lua-ljsqlite3/init');local path=home..'/synthetic-finish-remote.db'
    local function remote(task)
        local db=SQ3.open(path);db:exec('PRAGMA busy_timeout=3000');local good,value=pcall(task,db);db:close();assert(good);return value
    end
    local function load(db) return json.decode(db:rowexec('SELECT payload FROM remote WHERE id=1')) end
    local function save(db,value) local stmt=db:prepare('UPDATE remote SET payload=? WHERE id=1');stmt:bind(json.encode(value)):step();stmt:close() end
    local function shelf() return {books={{bookId='41',title='合成测试书籍：读完标记',finishReading=0,secret=0,readUpdateTime=1700000000},
        {bookId='42',title='合成其他书籍',finishReading=1,secret=0}},archive=json.decode('[]')} end
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
    local Client=require('weread.lib.client');local Contract=require('weread.lib.finish_change_contract')
    function Client:request(options)
        local writing=options.url==base..'/book/markstatus';local h=options.headers or {}
        local kind=options.url==base..'/shelf/sync' and 'shelf' or options.url==base..'/book/getProgress?bookId=41' and 'progress'
            or options.url==base..'/book/info?bookId=41' and 'metadata' or writing and 'write'
        local body=writing and json.decode(options.body)
        local allowed=kind and options.method==(writing and 'POST' or 'GET') and tonumber(ffi.C.getpid())~=parent
            and options.skip_cookie and options.persist_response_cookies==false and options.sensitive
            and h.vid=='900000' and h.accessToken=='synthetic-finish-access' and not h.Cookie and not h.Authorization
        local rejection=not allowed and 'transport_guard' or nil
        if writing then
            local record,reason=require('weread.lib.finish_change_store'):new(plugin.library_db,self):read()
            if not record then rejection=reason=='storage' and 'journal_storage' or 'journal_unavailable'
            elseif record.phase~='pending' then rejection='journal_not_pending'
            elseif record.metadata.request_hash~=require('weread.lib.thought_edit_contract').body_hash(body) then rejection='request_hash' end
            allowed=allowed and record and record.phase=='pending' and record.metadata.request_hash==require('weread.lib.thought_edit_contract').body_hash(body)
            local desired=type(body.isCancel)=='number' and body.isCancel==0
            for k,v in pairs(Contract.request('41',desired)) do
                if body[k]~=v then rejection='request_fields' end
                allowed=allowed and body[k]==v
            end
            local count=0;for _i in pairs(body) do count=count+1 end
            if count~=5 then rejection='request_fields' end
            allowed=allowed and count==5
        end
        local result=remote(function(db)
            db:exec('BEGIN IMMEDIATE');local value=load(db);value.requests=value.requests+1
            if not allowed then value.forbidden=value.forbidden+1;value.rejection=rejection or 'unknown';save(db,value);db:exec('COMMIT');return {reject=true} end
            if kind=='shelf' and (value.fault=='preflight_503_once' or value.fault=='preflight_429_once') then
                local status=value.fault=='preflight_503_once' and 503 or 429
                value.fault='normal';save(db,value);db:exec('COMMIT');return {injected_status=status}
            end
            if writing then
                value.posts=value.posts+1
                if value.fault~='no_change' then value.shelf.books[1].finishReading=body.isCancel==0 and 1 or 0 end
                if value.fault=='unrelated' then value.shelf.books[2].secret=1 end
            end
            save(db,value);db:exec('COMMIT');return value
        end)
        assert(not result.reject);require('socket').sleep(.12)
        if result.injected_status then return json.encode({errcode=-1}),result.injected_status end
        if writing and result.fault=='delayed' then require('socket').sleep(5) end
        if writing and result.fault=='lost_ack' then error('synthetic timeout',0) end
        if kind=='progress' and result.fault=='no_position' then return json.encode({errcode=-10102}),200 end
        return json.encode(kind=='shelf' and result.shelf or kind=='progress' and result.progress
            or kind=='metadata' and {bookId='41',title='合成测试书籍：读完标记',version=77} or {status=1}),200
    end
    local Settings=require('weread.lib.settings');local settings_new=Settings.new
    function Settings:new()
        local value=settings_new(self)
        if mode=='live' then
            value.store:saveSetting('auth_schema_version',1);value.store:saveSetting('auth_epoch',1)
            value.store:saveSetting('account',{user_vid='900000',name='合成用户'});value:flush()
            assert(require('weread.lib.native_credentials'):new(value):save({vid='900000',accessToken='synthetic-finish-access',
                refreshToken='synthetic-finish-refresh',deviceId=string.rep('1',32)},value:get_auth_scope(),0,2))
        end
        return value
    end
    local UI=require('ui/uimanager');local socket=require('socket')
    local Worker=require('weread.lib.memory_worker');local start=Worker.start
    function Worker:start(...) local value=start(self,...);if self.job then workers[#workers+1]={pid=self.job.pid,runner=self.runner} end;return value end
    do
        -- Synthetic-only fixed categories distinguish a stalled worker from a
        -- proven-unsent or possibly-dispatched operation without logging data.
        local Service=require('weread.lib.finish_change_service')
        local Task=require('weread.lib.finish_change_task')
        local task_run,task_preview=Task.run,Task.preview
        local active_trace
        function Task.preview(...)
            if not active_trace then return task_preview(...) end
            local valid,value=pcall(task_preview,...)
            active_trace.preflight=valid and 'ok' or Task.read_error(value)
            if not valid then error(value,0) end
            return value
        end
        function Task.run(client,settings,selected,input,record,store,...)
            local trace={preflight='not_started',claim='not_called',owns_failed=0}
            active_trace=trace
            local owns,claim,read=store.owns,store.claim,store.read
            store.read=function(self,...)
                local value,why=read(self,...)
                trace.last_read=value and 'available' or ({storage=true,account=true})[why] and why or 'other'
                return value,why
            end
            store.owns=function(self,...)
                if trace.preflight=='ok' and mode=='reopen' and report.phase=='offline-mark' then
                    local injected=remote(function(db)
                        db:exec('BEGIN IMMEDIATE');local value=load(db)
                        local fail=value.fault=='local_owns_once'
                        if fail then value.fault='normal';save(db,value) end
                        db:exec('COMMIT');return fail
                    end)
                    if injected then
                        trace.owns_failed=trace.owns_failed+1;trace.owns_reason='storage'
                        return false,'storage'
                    end
                end
                local result,why=owns(self,...)
                if not result then trace.owns_failed=trace.owns_failed+1;trace.owns_reason=trace.last_read or 'other' end
                return result,why
            end
            store.claim=function(self,...)
                local result,why=claim(self,...)
                trace.claim=result and 'claimed' or why=='storage' and 'storage' or 'other'
                return result,why
            end
            local good,value=pcall(task_run,client,settings,selected,input,record,store,...)
            store.owns,store.claim,store.read=owns,claim,read;active_trace=nil
            if not good then error(value,0) end
            if type(value)=='table' then value._synthetic_trace=trace end
            return value
        end
        local prepare,commit=Service.prepare,Service.commit
        local kinds={confirmed=true,noop=true,changed=true,temporary=true,login=true,rate_limited=true,
            unavailable=true,unconfirmed=true,session_changed=true}
        function Service:prepare(id,guard,callback,...)
            report.trace_prepare='started';report.trace_commit='none'
            report.trace_preflight,report.trace_claim,report.trace_owns_failed,report.trace_owns_reason=nil,nil,nil,nil
            report.trace_attempted,report.trace_finished=nil,nil
            return prepare(self,id,guard,function(plan,why,...)
                report.trace_prepare=plan and 'ready' or kinds[why] and why or 'other'
                return callback(plan,why,...)
            end,...)
        end
        function Service:commit(plan,callback)
            report.trace_commit='started'
            return commit(self,plan,function(result,finished)
                local kind=type(result)=='table' and result.kind
                report.trace_commit=kinds[kind] and kind or 'other'
                report.trace_attempted=type(result)=='table' and result.attempted==true or false
                report.trace_finished=finished==true
                local trace=type(result)=='table' and result._synthetic_trace
                if type(trace)=='table' then
                    report.trace_preflight=({ok=true,temporary=true,login=true,rate_limited=true,unavailable=true,
                        not_started=true})[trace.preflight] and trace.preflight or 'other'
                    report.trace_claim=({claimed=true,storage=true,other=true,not_called=true})[trace.claim] and trace.claim or 'other'
                    report.trace_owns_failed=type(trace.owns_failed)=='number' and math.min(trace.owns_failed,100) or 0
                    if trace.owns_reason then
                        report.trace_owns_reason=({available=true,storage=true,account=true,other=true})[trace.owns_reason]
                            and trace.owns_reason or 'other'
                    end
                end
                return callback(result,finished)
            end)
        end
    end
    local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
    for _i,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end;expect(#Loader.enabled_plugins==1)
    local FM=require('apps/filemanager/filemanager');FM:showFiles(home);plugin=assert(FM.instance.weread)
    plugin.isNetworkOnline=function() return true end;plugin.isNetworkConnected=plugin.isNetworkOnline
    if mode=='live' then expect(plugin.library_db:cacheShelf(shelf().books,{})) end
    local Journal=require('weread.lib.finish_change_store');local journal=Journal:new(plugin.library_db,plugin.client)
    local tr=require('weread.lib.plugin_util').tr
    local function tick() UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01) end
    local function wait(test) local until_=socket.gettime()+65;while not test() do assert(socket.gettime()<until_);tick() end end
    local function shot(name) UI:forceRePaint();Device.screen:shot(assert(os.getenv('WEREAD_FINISH_SHOTS'))..'/'..mode..'-'..name..'.png');report.screenshots=report.screenshots+1 end
    local function hold_action(label,list_mode)
        local display=plugin.settings:get('shelf');display.view_mode=list_mode and 'list' or 'cover';display.paginated=true
        plugin.settings:set('shelf',display);plugin.settings:flush()
        plugin:closeWeReadUI();plugin:showBookshelf();UI:forceRePaint()
        local view=assert(plugin.shelf_view);local index
        for i,book in ipairs(view.books) do if tostring(book.bookId or book.book_id)=='41' then index=i;break end end
        local cell=assert(index and view._item_rows[index]);local event=require('ui/event')
        local pos=require('ui/geometry'):new{x=cell.dimen.x+math.floor(cell.dimen.w/2),y=cell.dimen.y+math.floor(cell.dimen.h/2)}
        expect(cell:handleEvent(event:new('Gesture',{ges='hold',pos=pos})))
        local dialog=assert(view._shelf_popup)
        expect(cell:handleEvent(event:new('Gesture',{ges='hold_release',pos=pos})))
        local action
        for _,row in ipairs(dialog.buttons) do for _,button in ipairs(row) do if button.text==tr(label) then action=button end end end
        expect(action);action.callback()
        return view
    end
    local function open(resolving)
        plugin:cancelShelfState()
        plugin:showBookMenu{book_id='41',title='合成测试书籍：读完标记',chapters={}}
        local detail=assert(plugin._book_detail_view)
        local direct
        if not resolving then for _,button in ipairs(detail._action_buttons) do
            if button.text==tr('Change finished mark') then direct=button;break end
        end end
        if direct then direct.callback() end
        for _i,button in ipairs(detail._action_buttons) do
            if not direct and button.text==tr('Shelf status') then button.callback();break end
        end
        local menu=assert(plugin._shelf_state_menu)
        if not direct then
            for _i,item in ipairs(menu.item_table) do
                if item.text==tr(resolving and 'Check pending finished-mark change' or 'Change finished mark') then menu:onMenuSelect(item);break end
            end
        end
        wait(function() return plugin._finish_change_ui and plugin._finish_change_ui.dialog end)
        return plugin._finish_change_ui.dialog
    end
    local function notice()
        wait(function() return not plugin._finish_change_ui end)
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
        view.ok_callback();expect(plugin._finish_change_ui and plugin._finish_change_ui.dialog~=view)
        confirm(plugin._finish_change_ui.dialog);expect(journal:read().phase=='idle')
    end
    local function saved(value) expect(require('weread.lib.shelf_flags').display(plugin.library_db:getShelfStatus('41').book,'finished')==value) end
    if mode=='live' then
        report.phase='login-and-mutual-exclusion'
        local owner=hold_action('Change cloud membership')
        wait(function() return plugin._shelf_membership_ui and plugin._shelf_membership_ui.dialog end)
        expect(owner._shelf_popup==plugin._shelf_state_menu and plugin._shelf_membership_ui.dialog.ok_text==tr('Remove from cloud bookshelf'))
        plugin._shelf_membership_ui.dialog.cancel_callback();expect(state().posts==0)
        plugin:closeWeReadUI()
        plugin:showShelfState('41');local capture=plugin.settings.get_auth_scope;plugin.settings.get_auth_scope=function() return nil end
        require('weread.ui.finish_change').open(plugin,'41')
        expect(not plugin._finish_change_ui and UI:getTopmostVisibleWidget().text==tr('Authorize or renew E-Ink login in settings, then try again.'))
        UI:close(UI:getTopmostVisibleWidget())
        require('weread.ui.shelf_membership_write').open(plugin,'41')
        expect(not plugin._shelf_membership_ui and UI:getTopmostVisibleWidget().text==tr('Authorize or renew E-Ink login in settings, then try again.'))
        UI:close(UI:getTopmostVisibleWidget());plugin.settings.get_auth_scope=capture;expect(state().posts==0)
        local member_journal=require('weread.lib.shelf_membership_journal'):new(plugin.settings,plugin.client)
        local member_scope=plugin.settings:get_auth_scope();local pending=assert(member_journal:begin(member_scope,'41','remove'))
        require('weread.ui.finish_change').open(plugin,'41');expect(not plugin._finish_change_ui and state().posts==0)
        UI:close(UI:getTopmostVisibleWidget());expect(member_journal:finish(member_scope,pending))
        report.phase='mark';local before=hold_action('Change finished mark')
        wait(function() return plugin._finish_change_ui and plugin._finish_change_ui.dialog end)
        local view=plugin._finish_change_ui.dialog
        expect(view.ok_text==tr('Mark as finished') and state().posts==0);shot('mark-confirmation');confirm(view)
        expect(state().posts==1 and journal:read().phase=='idle');saved(true)
        expect(plugin.shelf_view==before and before._shelf_popup==plugin._shelf_state_menu)
        UI:close(plugin._shelf_state_menu);wait(function() return plugin.shelf_view~=before end)
        local found
        for _,book in ipairs(plugin.shelf_view.books) do if book.bookId=='41' then found=book end end
        expect(found and require('weread.lib.shelf_flags').display(found,'finished')==true)
        expect(plugin.shelf_view.on_select and plugin.shelf_view._item_rows[1].hold_callback)
        report.phase='unmark';fault('lost_ack');before=plugin.shelf_view
        view=open();expect(view.ok_text==tr('Mark as unfinished'));confirm(view)
        expect(state().posts==2 and journal:read().phase=='idle');saved(false);fault('normal')
        UI:close(assert(plugin._shelf_state_menu));assert(plugin._book_detail_view):onClose()
        wait(function() return plugin.shelf_view~=before end)
        found=nil
        for _,book in ipairs(plugin.shelf_view.books) do if book.bookId=='41' then found=book end end
        expect(found and require('weread.lib.shelf_flags').display(found,'finished')==false)
        report.phase='cancel'
        view=open();view.cancel_callback();expect(state().posts==2 and not plugin._finish_change_ui and journal:read().phase=='idle')
        view=open();plugin:closeWeReadUI();view.ok_callback();expect(state().posts==2 and not plugin._finish_change_ui)
        view=open();plugin:onWeReadAccountChanged();view.ok_callback();expect(state().posts==2 and not plugin._finish_change_ui)
        report.phase='changed-preflight';view=open();change(function(v) v.shelf.books[1].secret=1 end);confirm(view)
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
        accept();expect(state().posts==4);saved(false);fault('normal')
        report.phase='save-failure'
        local db=assert(plugin.library_db:open());db:execsql([[CREATE TRIGGER reject_finish_cache BEFORE INSERT ON shelf_state
            WHEN NEW.name='membership_snapshot' BEGIN SELECT RAISE(ABORT,'synthetic cache failure'); END]]);db:close()
        view=open();confirm(view);expect(state().posts==5 and journal:read().phase=='pending');saved(false)
        db=assert(plugin.library_db:open());db:execsql('DROP TRIGGER reject_finish_cache');db:close();accept();saved(true)
        view=open();confirm(view);expect(state().posts==6 and journal:read().phase=='idle');saved(false)
        report.phase='cancel-after-dispatch';view=open();fault('delayed');view.ok_callback();wait(function() return state().posts==7 end)
        plugin.busy_message:onTapClose();expect(not plugin._finish_change_ui and journal:read().phase=='pending');shot('pending')
        fault('normal')
    elseif mode=='reopen' then
        report.phase='read-only-reopen';expect(state().posts==7 and journal:read().phase=='pending');accept();expect(state().posts==7);saved(true)
        report.phase='restore';local view=open();confirm(view);expect(state().posts==8 and journal:read().phase=='idle');saved(false);shot('restored')
        expect(state().shelf.books[2].secret==0 and state().shelf.books[2].finishReading==1 and state().progress.book.chapterOffset==100)
        local queue=require('weread.lib.finish_queue_store'):new(plugin.library_db)
        local function queue_offline(list_mode)
            plugin.isNetworkConnected=function() return false end
            local owner=hold_action('Change finished mark',list_mode)
            wait(function() return plugin._finish_offline_dialog~=nil end)
            expect(owner._shelf_popup==plugin._shelf_state_menu)
            local dialog=assert(plugin._finish_offline_dialog);dialog.ok_callback()
            expect(queue:get('41') and queue:get('41').phase=='queued')
            local top=UI:getTopmostVisibleWidget();if top~=plugin._shelf_state_menu then UI:close(top) end
            local display=plugin.settings:get('shelf');display.view_mode=list_mode and 'list' or 'cover';display.paginated=not list_mode
            plugin.settings:set('shelf',display);plugin.settings:flush()
            plugin:closeWeReadUI();plugin:showBookshelf()
            local shelf_view=assert(plugin.shelf_view);local book
            for _,item in ipairs(shelf_view.books) do if tostring(item.bookId or item.book_id)=='41' then book=item end end
            expect(book and shelf_view:itemStatus(book):find(tr('Pending sync'),1,true))
            if shelf_view.cover_mode then
                local cell
                for _,item in ipairs(shelf_view._item_rows) do if item.book==book then cell=item end end
                expect(cell and cell._finished_badge and cell._finished_badge.label.text==tr('Pending sync'))
            end
            if not report.offline_shot then shot('offline-queued');report.offline_shot=true end
        end
        local function reconnect(expected_posts,finished,overlay,read_failure)
            local before=assert(plugin.shelf_view)
            local last=#before.layout
            before:moveFocusTo(math.min(2,#before.layout[last]),last,require('ui/widget/focusmanager').FOCUS_ONLY_ON_NT)
            local x,y=before.selected.x,before.selected.y
            local popup,detail
            if overlay=='search' then
                before.on_search();popup=assert(before._shelf_popup)
            elseif overlay=='detail' then
                plugin:showBookMenu{book_id='41',title='合成测试书籍：读完标记',chapters={}}
                detail=assert(plugin._book_detail_view)
            elseif overlay=='status' then
                plugin:showShelfState('41');detail=assert(plugin._shelf_state_menu)
            end
            if read_failure then fault(read_failure=='temporary' and 'preflight_503_once' or 'preflight_429_once') end
            local posts_before=state().posts
            plugin.isNetworkConnected=function() return true end;plugin:onNetworkConnected()
            if read_failure=='temporary' then
                wait(function() return plugin._finish_offline_retry and plugin._finish_offline_retry.timer end)
                local retry=plugin._finish_offline_retry;local timer=retry.timer
                expect(retry.attempts==1 and queue:get('41').phase=='queued' and state().posts==posts_before)
                plugin:onNetworkConnected();expect(plugin._finish_offline_retry.timer==timer)
                require('weread.ui.finish_change').open(plugin,'41')
                local dialog=assert(plugin._finish_offline_dialog)
                expect(plugin._finish_offline_retry==retry and retry.timer==timer)
                UI:unschedule(timer);UI:scheduleIn(.01,timer)
                wait(function() return retry.waiting_ui end)
                expect(queue:get('41').phase=='queued' and state().posts==posts_before)
                fault('local_owns_once')
                dialog.cancel_callback()
                wait(function() return plugin._finish_offline_retry==retry and retry.attempts==2 and retry.timer~=nil end)
                report.dialog_retry_verified=true
                expect(queue:get('41').phase=='queued' and journal:read().phase=='idle' and state().posts==posts_before)
                timer=retry.timer;UI:unschedule(timer);UI:scheduleIn(.01,timer)
                report.local_storage_retry_verified=true
            elseif read_failure=='rate_limited' then
                wait(function() return state().fault=='normal' and plugin._finish_offline_sync and not plugin._finish_offline_sync.job end)
                expect(not plugin._finish_offline_retry and queue:get('41').phase=='queued' and state().posts==posts_before)
                plugin:onNetworkConnected()
            end
            wait(function() local entry,err=queue:get('41');return not err and not entry end)
            expect(state().posts==expected_posts and journal:read().phase=='idle');saved(finished)
            if read_failure=='temporary' then report.temporary_retry_verified=true end
            if read_failure=='rate_limited' then report.rate_limit_stop_verified=true end
            if popup then
                expect(plugin.shelf_view==before and before._shelf_popup==popup)
                require('weread.ui.shelf_popup').close(before)
            elseif detail then
                expect(plugin.shelf_view==before and (plugin._book_detail_view==detail or plugin._shelf_state_menu==detail))
                UI:close(detail)
            end
            wait(function() return plugin.shelf_view and plugin.shelf_view~=before end)
            local updated=plugin.shelf_view;local book
            for _,item in ipairs(updated.books) do if tostring(item.bookId or item.book_id)=='41' then book=item end end
            expect(book and require('weread.lib.shelf_flags').display(book,'finished')==finished
                and not updated:itemStatus(book):find(tr('Pending sync'),1,true))
            if updated.cover_mode then
                local cell
                for _,item in ipairs(updated._item_rows) do if item.book==book then cell=item end end
                expect(cell and (finished and cell._finished_badge and cell._finished_badge.label.text==tr('Read complete')
                    or not finished and not cell._finished_badge))
            end
            expect(updated.page==before.page)
            if overlay~='detail' then expect(updated.selected.x==x and updated.selected.y==y) end
            if overlay=='search' then shot('offline-confirmed') end
        end
        report.phase='offline-mark';queue_offline();expect(state().posts==8);reconnect(9,true,'search','temporary')
        report.phase='offline-unmark';queue_offline(true);expect(state().posts==9);reconnect(10,false,'detail','rate_limited')
        report.phase='offline-already-applied';queue_offline(true)
        change(function(v) v.shelf.books[1].finishReading=1 end)
        reconnect(10,true,'status')
        do
            local before=assert(plugin.shelf_view)
            local metadata={};plugin.book_metadata_context=metadata
            require('weread.ui.finish_offline').refresh_view(plugin,'41')
            expect(plugin.shelf_view==before and before._finish_dirty['41'] and metadata.pending_shelf_redraw)
            plugin:cancelBookMetadata();wait(function() return plugin.shelf_view~=before end)
            local updated=plugin.shelf_view;local found
            for _,item in ipairs(updated.books) do
                if tostring(item.bookId or item.book_id)=='41' then found=item end
            end
            expect(found and require('weread.lib.shelf_flags').display(found,'finished')==true)
            report.metadata_refresh_verified=true
        end
        report.phase='offline-unmark-after-noop';queue_offline()
        plugin.prepareShelfProgress=function() return nil end;plugin.fetchVisibleShelfCovers=function() end
        plugin:showHome()
        expect(plugin.shelf_view._discovery_tab=='home' and #plugin.shelf_view.books>0)
        reconnect(11,false)
        report.phase='offline-interrupted';queue_offline();fault('delayed')
        plugin.isNetworkConnected=function() return true end;plugin:onNetworkConnected()
        wait(function() return state().posts==12 end)
        plugin.isNetworkConnected=function() return false end;plugin:onNetworkDisconnected()
        expect(queue:get('41').phase=='dispatching' and journal:read().phase=='pending')
        fault('normal')
    elseif mode=='offline_reopen' then
        report.phase='offline-reopen-no-retry'
        local queue=require('weread.lib.finish_queue_store'):new(plugin.library_db)
        expect(state().posts==12 and queue:get('41').phase=='dispatching' and journal:read().phase=='pending')
        plugin:onNetworkConnected();local until_=socket.gettime()+.5;while socket.gettime()<until_ do tick() end
        expect(state().posts==12 and queue:get('41').phase=='dispatching')
        accept();expect(state().posts==12 and journal:read().phase=='idle');saved(true)
        report.phase='offline-review';expect(require('weread.ui.finish_offline').open(plugin,'41'))
        local dialog=assert(plugin._finish_offline_dialog)
        expect(dialog.text==tr('This offline change may have been sent. Remove its local record without retrying? Check the current cloud status separately; a delayed change may still appear.'))
        dialog.ok_callback();expect(not queue:get('41') and state().posts==12)
        report.phase='retry-before-restart'
        local top=UI:getTopmostVisibleWidget();if top~=plugin._shelf_state_menu then UI:close(top) end
        plugin.isNetworkConnected=function() return false end
        local menu=assert(plugin._shelf_state_menu);local action
        for _,item in ipairs(menu.item_table) do if item.text==tr('Change finished mark') then action=item end end
        expect(action);menu:onMenuSelect(action);assert(plugin._finish_offline_dialog).ok_callback()
        expect(queue:get('41').phase=='queued' and state().posts==12)
        top=UI:getTopmostVisibleWidget();if top~=plugin._shelf_state_menu then UI:close(top) end
        fault('preflight_503_once');plugin.isNetworkConnected=function() return true end;plugin:onNetworkConnected()
        wait(function() return plugin._finish_offline_retry and plugin._finish_offline_retry.timer end)
        expect(queue:get('41').phase=='queued' and journal:read().phase=='idle' and state().posts==12)
        report.queued_restart_prepared=true
    else
        report.phase='retry-after-restart'
        local queue=require('weread.lib.finish_queue_store'):new(plugin.library_db)
        expect(state().posts==12 and queue:get('41').phase=='queued' and journal:read().phase=='idle')
        expect(not plugin._finish_offline_retry);plugin:onNetworkConnected()
        wait(function() local entry,err=queue:get('41');return not err and not entry end)
        expect(state().posts==13 and journal:read().phase=='idle');saved(false)
        report.queued_restart_verified=true
    end
    plugin:closeWeReadUI();for _i,worker in ipairs(workers) do wait(function() return worker.runner.done(worker.pid) end) end
    report.workers_reaped=true;local value=state();report.requests,report.posts,report.forbidden=value.requests,value.posts,value.forbidden
    expect(value.forbidden==0);report.phase='complete';report.result='PASS'
end)
if not ok and plugin then
    local inspected=pcall(function()
        local queue=require('weread.lib.finish_queue_store'):new(plugin.library_db)
        local entry=queue:get('41')
        local record=require('weread.lib.finish_change_store'):new(plugin.library_db,plugin.client):read()
        report.trace_queue=entry and ({queued=true,dispatching=true,conflict=true})[entry.phase] and entry.phase or 'none_or_unavailable'
        report.trace_journal=record and ({idle=true,prepared=true,pending=true})[record.phase] and record.phase or 'unavailable'
        local sync=plugin._finish_offline_sync
        report.trace_sync_active=sync and sync.job~=nil or false
        report.trace_worker_active=sync and sync.service and sync.service.worker and sync.service.worker.job~=nil or false
        report.trace_timer_active=plugin._finish_offline_retry and plugin._finish_offline_retry.timer~=nil or false
        report.trace_dialog_active=plugin._finish_change_ui~=nil or plugin._shelf_flag_change_ui~=nil
            or plugin._shelf_membership_ui~=nil or plugin._finish_offline_dialog~=nil or plugin._membership_offline_dialog~=nil
    end)
    report.trace_inspected=inspected
end
if plugin then pcall(plugin.closeWeReadUI,plugin) end
if state_reader then
    local read,value=pcall(state_reader)
    if read then
        report.requests,report.posts,report.forbidden=value.requests,value.posts,value.forbidden
        if value.forbidden>0 then
            report.trace_rejection=({transport_guard=true,journal_storage=true,journal_unavailable=true,
                journal_not_pending=true,request_hash=true,request_fields=true})[value.rejection] and value.rejection or 'unknown'
        end
    end
end
local deadline=require('socket').gettime()+5
local reaped=true
for _i,worker in ipairs(workers) do
    while not worker.runner.done(worker.pid) and require('socket').gettime()<deadline do require('socket').sleep(.01) end
    if not worker.runner.done(worker.pid) then reaped=false end
end
report.workers_reaped=reaped
if not ok then report.failed_line=tonumber(type(reason)=='string' and reason:match('finish_change_ui_probe%.lua:(%d+):')) or 0 end
io.write('\nWEREAD_FINISH_UI_RESULT='..json.encode(report)..'\n');os.exit(ok and 0 or 1)
