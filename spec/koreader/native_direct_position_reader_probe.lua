-- Installed plugin + ReaderUI position check against a local synthetic service.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
assert(os.getenv('WEREAD_SYNTHETIC')=='1')
local home=assert(os.getenv('KO_HOME'));local plugin=home..'/plugins/weread.koplugin'
package.path=plugin..'/?.lua;'..package.path
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua');G_defaults=require('luadefaults'):open()
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
local Device=require('device');require('document/canvascontext'):init(Device)
local json=require('json');local input=json.decode(assert(io.stdin:read('*a')))
local settings=require('weread.lib.settings'):new();assert(settings.data_dir==home..'/weread')
settings:set('account',{user_vid=input.credentials.vid,name='Synthetic',login_method='qr'})
settings:set('cookies',{wr_vid = input.credentials.vid,wr_skey='synthetic-web-access'});settings:flush()
if input.mode:find('^interval') then
    local sync=settings:get('sync',{});sync.upload_interval_minutes=1
    sync.upload_on_close=input.mode:find('^interval_close')~=nil;settings:set('sync',sync);settings:flush()
end
local scope=assert(settings:get_auth_scope());assert(settings:auth_scope_matches(scope))
local credential_store=require('weread.lib.native_credentials'):new(settings)
local existing=credential_store:read()
if existing then assert(existing.vid==input.credentials.vid and existing.accessToken==input.credentials.accessToken)
else assert(credential_store:save(input.credentials,scope,0,1)) end
local loader=require('pluginloader');loader.enabled_plugins,loader.disabled_plugins,loader.loaded_plugins={},{},{}
for _,item in ipairs(loader:_discover()) do if item.name=='weread' then loader:_load{item} end end
assert(#loader.enabled_plugins==1)
package.path=plugin..'/?.lua;'..package.path
local UI=require('ui/uimanager');local socket=require('socket');local Reader=require('apps/reader/readerui')
if input.mode:find('^interval_close') then UI:show(require('ui/widget/widget'):new{}) end
local function wait(predicate)
    local deadline=socket.gettime()+90
    while not predicate() do
        assert(socket.gettime()<deadline,'native position UI timeout')
        UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
    end
end
Reader:showReader(input.path)
wait(function() return Reader.instance and Reader.instance.document and Reader.instance.weread end)
local reader=Reader.instance;local host=reader.weread;local destination_host
local function configure(active)
active.settings.mock_endpoint=input.mock_endpoint
active.isNetworkConnected=function() return not input.offline end
active.isNetworkOnline=function() return not input.offline end
local requests=active.client.request
active.client.request=function(self,options)
    assert(not input.offline,'offline selection attempted a network request')
    local url=options.url;assert(options.sensitive and options.skip_cookie and options.persist_response_cookies==false)
    assert(url=='https://i.weread.qq.com/book/info?bookId=42'
        or url=='https://i.weread.qq.com/book/getProgress?bookId=42'
        or (input.mode:find('^preview') or input.mode:find('^upload') or input.mode:find('^interval')) and url=='https://i.weread.qq.com/shelf/sync'
        or (input.mode:find('^upload') or input.mode:find('^interval')) and (url=='https://i.weread.qq.com/feature?synckey=0'
            or url=='https://i.weread.qq.com/book/read')
        or url=='https://i.weread.qq.com/book/chapterInfos'
        or input.mode:find('^selection_direct_') and (url:find('https://i.weread.qq.com/book/bookmarklist?',1,true)==1
            or url:find('https://i.weread.qq.com/review/list?',1,true)==1
            or url=='https://i.weread.qq.com/book/addBookmark' or url=='https://i.weread.qq.com/book/removeBookmark'
            or url=='https://i.weread.qq.com/review/add')
        or url:find('https://i.weread.qq.com/book/chapterdownload?',1,true)==1
        or url=='https://weread.qq.com/api/userInfo?userVid=12345678'
        or url=='https://weread.qq.com/web/book/chapterInfos'
        or (input.mode:find('^preview') or input.mode:find('^upload') or input.mode:find('^interval'))
            and url:find('https://weread.qq.com/web/book/getProgress?',1,true)==1
        or url:find('https://weread.qq.com/web/reader/',1,true)==1
        or input.plain_text and (url=='https://weread.qq.com/web/book/chapter/t_0' or url=='https://weread.qq.com/web/book/chapter/t_1')
        or url:find('https://weread.qq.com/web/book/chapter/e_',1,true)==1)
    if url:find('https://weread.qq.com/web/',1,true)==1 then
        assert(options.headers.Cookie:find('synthetic-refreshed-cookie',1,true),'account cookie rotation was not used')
    end
    return requests(self,options)
end
active.showInfo=function(self,message) self.checked_message=message end
active.showTransientInfo=function(self,message) self.transient_message=message end
end
configure(host)
local open_file=host.openFile
host.openFile=function(self,path,callback,...)
    return open_file(self,path,function(next_reader)
        destination_host=assert(next_reader.weread);configure(destination_host)
        return callback(next_reader)
    end,...)
end
local native_worker=require('weread.lib.memory_worker'):new{scheduler=UI,codec=host.client,max_bytes=65536,timeout=180}
local captured,point,point_error
host._native_direct_position_worker={cancel=function() native_worker:cancel() end,start=function(_,task,callback)
    local ctx=assert(host._native_direct_position);captured={text=ctx.input.text,offset=ctx.input.point_offset}
    if input.mode:find('^preview') then
        task=function()
            local value,why=require('weread.lib.native_direct_upload_preview').prepare(host.client,host.settings,ctx.entry,
                ctx.file,ctx.input,ctx.native,ctx.web,function() return true end)
            if value then
                assert(value.dispatch_authorized==false and value.desired.summary and value.desired.raw_percent==50)
                return {position=value.position}
            end
            return {error=why}
        end
    end
    return native_worker:start(task,function(value)
        point=value.position or value.comparison and value.comparison.position or value.preview and value.preview.position;point_error=value.error
        callback(value)
    end)
end}
local function open_menu()
    local id=(input.mode:find('^upload') or input.mode:find('^interval')) and 'native_upload_position'
        or (input.mode:find('^cloud') or input.mode:find('^cross_')) and 'native_cloud_position' or 'native_position_check'
    assert(host:onShowWeReadQuickMenu())
    wait(function()
        local top=UI:getTopmostVisibleWidget()
        return top and type(top.getButtonById)=='function' and top:getButtonById(id)~=nil
    end)
    UI:forceRePaint();assert(UI:getTopmostVisibleWidget():getButtonById(id)):onTapSelectButton()
end
if input.mode:find('^selection_direct') then
    require('weread.ui.selection_thought')
    assert(host._selection_thought_hook,'native chapter selection action was not attached')
    local quote=input.plain_text and 'Unique paragraph 0002' or 'Unique paragraph 0001'
    local matches=assert(reader.document:findAllText(quote,false,0,3,false,0))
    assert(#matches==1 and matches[1].start and matches[1]['end'])
    local bookmark=input.mode:find('^selection_direct_bookmark')~=nil
    if bookmark then
        reader.rolling:onGotoXPointer(matches[1].start);reader.document:clearSelection();UI:forceRePaint()
        if input.mode=='selection_direct_bookmark_quick' then
            assert(host:onShowWeReadQuickMenu())
            wait(function() local top=UI:getTopmostVisibleWidget()
                return top and type(top.getButtonById)=='function' and top:getButtonById('native_save_bookmark')~=nil end)
            UI:forceRePaint();assert(UI:getTopmostVisibleWidget():getButtonById('native_save_bookmark')):onTapSelectButton()
        else
            local action;local tr=require('weread.lib.plugin_util').tr
            for _,item in ipairs(host:getMainMenuItems()) do if item.text==tr('Save cloud bookmark') then action=item.callback end end
            assert(action,'native direct bookmark menu missing');action()
        end
    else
        reader.highlight.selected_text={text=quote,pos0=matches[1].start,pos1=matches[1]['end']}
        reader.highlight:onShowHighlightMenu();UI:forceRePaint()
        assert(reader.highlight.highlight_dialog.buttontable:getButtonById('weread_selection_thought')):onTapSelectButton()
    end
    wait(function() return host._selection_thought_owner~=nil or host.checked_message~=nil end)
    local owner=assert(host._selection_thought_owner)
    if input.mode=='selection_direct_move' then
        wait(function() return owner.direct_entry and owner.worker and owner.worker.job end)
        reader.rolling:onGotoPage(2);UI:forceRePaint()
        wait(function() return not host._selection_thought_owner end)
        assert(not owner.reference and not host.checked_message,'changed page accepted a selection')
    else
        wait(function() return owner.reference or host.checked_message end)
        if input.mode=='selection_direct_mismatch' or input.mode=='selection_direct_auth_expired'
            or input.mode=='selection_direct_offline_missing'
            or input.mode=='selection_direct_web_expired' or input.mode=='selection_direct_limited' then
            assert(not owner.reference and host.checked_message,'unavailable source exposed a selection')
            local message=input.mode=='selection_direct_auth_expired' and 'Authorize or renew E-Ink login in settings, then try again.'
                or input.mode=='selection_direct_web_expired' and 'Log in again to verify the selected text.'
                or input.mode=='selection_direct_limited' and 'WeRead is limiting requests. Please try again later.'
                or input.mode=='selection_direct_offline_missing' and 'The offline chapter source is unavailable. Reconnect and select this text again.'
            if message then assert(host.checked_message==require('weread.lib.plugin_util').tr(message),'wrong source error') end
        else
            assert(owner.reference and require(bookmark and 'weread.lib.bookmark_reference' or 'weread.lib.selection_reference').valid(owner.reference,'42'))
            if input.offline then
                assert(owner.offline_source)
                for _,item in ipairs(owner.menu.item_table) do
                    assert(item.text~=require('weread.lib.plugin_util').tr('Save highlight'),'offline menu exposed cloud highlight')
                end
            end
            if bookmark or input.mode:find('^selection_direct_mark') or input.mode:find('^selection_direct_thought') then
                local thought=input.mode:find('^selection_direct_thought')~=nil
                local tr=require('weread.lib.plugin_util').tr
                local label=tr(bookmark and 'Save cloud bookmark' or thought and 'Write private thought' or 'Save highlight');local action
                for _,item in ipairs(owner.menu.item_table) do if item.text==label then action=item.callback;break end end
                assert(action,'selection action missing')
                if input.mode=='selection_direct_thought_offline_locked' then
                    local cache=require('weread.lib.native_direct_cache')
                    local lease=assert(cache.acquire(host.settings,owner.scope.vid,owner.id))
                    action();assert(not owner.editor and host.checked_message==tr('This chapter is being updated or cleaned. Try opening the thought again.'))
                    lease:release();host.checked_message=nil
                end
                if input.mode=='selection_direct_thought_offline_slow_check' then
                    local cache=require('weread.lib.native_direct_cache');local identify=cache.identify
                    cache.identify=function(...) socket.sleep(4);return identify(...) end
                    local started=socket.gettime();action();cache.identify=identify
                    assert(socket.gettime()-started<2 and owner.editor and not owner.editor.input,'source check blocked UI')
                    local pulse=false;UI:scheduleIn(.1,function() pulse=true end)
                    wait(function() return pulse end)
                    assert(socket.gettime()-started<3 and not owner.editor.input,'UI stalled while checking source')
                else action() end
                if thought then wait(function() return owner.editor and owner.editor.input or host.checked_message end) end
                local function tap(id)
                    UI:forceRePaint();local popup=assert(owner.menu._shelf_popup)
                    assert(popup.button_table:getButtonById(id),'missing '..id):onTapSelectButton()
                end
                if thought then
                    assert(owner.editor and owner.editor.input)
                    if input.mode=='selection_direct_thought_offline_submit' then
                        assert(owner.editor.input:getInputText()=='Synthetic private thought','offline draft was not retained after restart')
                    end
                    owner.editor.input:setInputText('Synthetic private thought')
                    if input.mode=='selection_direct_thought_offline_locked' then
                        local cache=require('weread.lib.native_direct_cache')
                        assert(not cache.acquire(host.settings,owner.scope.vid,owner.id),'open thought editor did not protect its chapter')
                    end
                    if input.mode=='selection_direct_thought_draft' or input.mode=='selection_direct_thought_offline_draft'
                        or input.mode=='selection_direct_thought_offline_locked' or input.mode=='selection_direct_thought_offline_slow_check' then
                        tap('save_thought_draft');wait(function() return not owner.editor end)
                        assert(host.checked_message==tr('Thought draft saved on this device.'));host.checked_message=nil
                        local drafts_action
                        for _,item in ipairs(owner.menu.item_table) do if item.text==tr('Local thought drafts') then drafts_action=item.callback;break end end
                        assert(drafts_action);drafts_action()
                        wait(function() return not (owner.editor and owner.editor.draft_job) end)
                        assert(owner.editor and owner.editor.dialog.item_table[1])
                        local network=host.isNetworkOnline
                        host.isNetworkOnline=function() error('resuming a cached selection checked the network') end
                        owner.editor.dialog.item_table[1].callback();tap('resume_thought_draft')
                        wait(function() return owner.editor and owner.editor.input or host.checked_message end)
                        host.isNetworkOnline=network
                        assert(owner.editor.input:getInputText()=='Synthetic private thought','direct draft did not restore')
                        require('weread.ui.thought_editor').cancel(host,owner)
                        if input.mode=='selection_direct_thought_offline_locked' then
                            local lease=assert(require('weread.lib.native_direct_cache').acquire(host.settings,owner.scope.vid,owner.id))
                            lease:release()
                        end
                    else
                        tap('submit_thought');wait(function() return not owner.editor or owner.editor.service.preview end)
                        assert(owner.editor and owner.editor.service.preview,'direct thought preflight failed')
                        tap('confirm_thought_change');wait(function() return not owner.editor end)
                    end
                else
                    wait(function() return not owner.mark_editor or owner.mark_editor.service.preview end)
                    assert(owner.mark_editor and owner.mark_editor.service.preview,'direct highlight preflight failed')
                    tap('confirm_highlight_change');wait(function() return not owner.mark_editor end)
                end
                local changed=input.mode:find('_changed$')~=nil
                local pending=input.mode:find('_no_effect$')~=nil
                assert(input.mode=='selection_direct_thought_draft' or input.mode=='selection_direct_thought_offline_draft'
                    or input.mode=='selection_direct_thought_offline_locked' or input.mode=='selection_direct_thought_offline_slow_check'
                    or host.checked_message==tr(pending and (thought
                    and 'A thought change needs checking. Use Check last thought change before submitting again.'
                    or 'A cloud mark change needs checking. Use Check last cloud mark change before submitting again.')
                    or changed and (thought
                    and 'The thought or quoted highlight changed, or could not be checked. Your local draft is kept. Refresh and try again.'
                    or 'The cloud mark or its source changed, overlaps a saved note, or could not be checked. Refresh and try again.')
                    or thought and 'Cloud thought change verified.' or bookmark and 'Cloud bookmark change verified.' or 'Cloud highlight change verified.'),
                    'unexpected direct annotation result')
                if input.mode=='selection_direct_bookmark_roundtrip' then
                    require('weread.ui.selection_thought').cancel(host);host.checked_message=nil
                    assert(host:showMyCloudBookmarks('42'),'could not open direct cloud bookmarks')
                    local notes=assert(host._my_marks_owner);local target
                    for _,item in ipairs(notes.menu.item_table) do if item.my_note_id=='synthetic-direct-mark' then target=item end end
                    assert(target,'new direct bookmark missing from list');target.callback()
                    UI:forceRePaint();local popup=assert(notes.menu._shelf_popup)
                    assert(popup.button_table:getButtonById('delete_bookmark')):onTapSelectButton()
                    wait(function() return not notes.mark_editor or notes.mark_editor.service.preview end)
                    assert(notes.mark_editor and notes.mark_editor.service.preview,'direct bookmark delete preflight failed')
                    UI:forceRePaint();popup=assert(notes.menu._shelf_popup)
                    assert(popup.button_table:getButtonById('confirm_highlight_change')):onTapSelectButton()
                    wait(function() return not notes.mark_editor end)
                    assert(host.checked_message==tr('Cloud bookmark change verified.'),'direct bookmark deletion not verified')
                    require('weread.ui.my_cloud_marks').cancel(host)
                end
                if thought and changed then
                    local drafts=require('weread.lib.thought_edit_store'):new(host.library_db,host.client):drafts()
                    assert(drafts and #drafts==1,'changed source did not retain the local draft')
                end
                if pending then
                    local journal=thought and require('weread.lib.thought_edit_store'):new(host.library_db,host.client)
                        or require('weread.lib.mark_edit_service').new_journal(host.library_db,host.client)
                    assert(journal:read().phase=='pending','uncertain annotation did not retain its pending record')
                    host.checked_message=nil;action()
                    if thought then
                        wait(function() return owner.editor and owner.editor.input or host.checked_message end)
                        assert(owner.editor and owner.editor.input);owner.editor.input:setInputText('Synthetic private thought')
                        tap('submit_thought');wait(function() return not owner.editor end)
                    else wait(function() return not owner.mark_editor end) end
                    assert(host.checked_message and journal:read().phase=='pending','pending annotation allowed a second attempt')
                end
            end
        end
    end
    print('WEREAD_POSITION_READER='..json.encode{ok=true,mode=input.mode,
        range=owner.reference and owner.reference.range or '',quote=owner.reference and owner.reference.markText or ''})
    return
end
open_menu()
if input.mode=='upload_initial_recorded' or input.mode=='upload_initial_tts' then
    wait(function() return host.checked_message~=nil end)
    assert(host.checked_message==require('weread.lib.plugin_util').tr('The cloud position could not be safely checked. Your current page is kept.'),
        'unverified audio or recorded time was accepted')
    print('WEREAD_POSITION_READER='..json.encode{ok=true,mode=input.mode})
    return
end
if input.mode:find('^upload') or input.mode:find('^interval') then
    wait(function() return host.checked_message~=nil or host._native_direct_position and host._native_direct_position.confirm end)
    assert(not host.checked_message and host._native_direct_position and host._native_direct_position.confirm,
        (host.checked_message or 'upload confirmation missing')..' ('..tostring(point_error)..')')
    local confirm=host._native_direct_position.confirm
    if input.mode:find('^upload_initial') then
        assert(confirm.text==require('weread.lib.plugin_util').tr('WeRead has no cloud position for this book. Set this page as its first position? Existing reading time will be kept.'),
            'first-position confirmation was not explicit')
    end
    if input.mode=='upload_cancel' then
        confirm.cancel_callback();assert(not host._native_direct_position)
    else
        confirm.ok_callback();wait(function() return host.checked_message~=nil end)
        local tr=require('weread.lib.plugin_util').tr
        local expected=input.mode=='upload_changed' and 'The cloud position changed during the check. Your current page is kept.'
            or (input.mode=='upload_lost_ack' or input.mode=='upload_missing_after'
                or input.mode=='upload_initial_noack' or input.mode=='upload_initial_changed')
                and 'The sync result could not be confirmed. Choose sync again to review it.'
            or 'Cloud reading position synced and checked.'
        assert(host.checked_message==tr(expected),'unexpected upload result')
        if input.mode:find('^interval') then
            local timer=assert(host._native_direct_interval,'manual sync did not establish interval baseline')
            local now=os.time();timer.now=function() return now end
            assert(reader.rolling and reader.document:getPageCount()>3)
            reader.rolling:onGotoPage(2);UI:forceRePaint()
            wait(function() return timer.task~=nil end)
            if input.mode:find('^interval_close') then
                local service=require('weread.lib.native_position_service');local original_start=service.start;local finished=false
                local close=require('weread.lib.native_direct_close');local original_freeze=close.freeze;local frozen=false
                close.freeze=function(...) local value=original_freeze(...);frozen=value~=nil;return value end
                service.start=function(self,metadata,guard,callback)
                    return original_start(self,metadata,guard,function(result,receipt)
                        callback(result,receipt);finished=true
                    end)
                end
                local document,closed=reader.document,false
                for _,name in ipairs({'getCurrentPage','getCurrentPos','getXPointer','getPageXPointer','getNormalizedXPointer',
                    'getDocumentFileContent','getNextVisibleChar','getPrevVisibleChar','getTextFromXPointers'}) do
                    local original=document[name]
                    if original then document[name]=function(self,...)
                        assert(not closed,'closed document accessed during background sync: '..name)
                        return original(self,...)
                    end end
                end
                if input.mode=='interval_close_offline' then host.isNetworkConnected=function() return false end end
                reader:onClose(false);closed=true
                close.freeze=original_freeze
                assert(frozen==(input.mode~='interval_close_offline'),'close did not capture the expected viewport')
                if input.mode=='interval_close_reopen' then
                    Reader:showReader(input.path);wait(function() return Reader.instance and Reader.instance~=reader end)
                    for _i=1,30 do UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01) end
                    assert(not finished and not host.transient_message,'reopening allowed the old close upload')
                elseif input.mode=='interval_close_offline' then
                    for _i=1,30 do UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01) end
                    assert(not finished and not host.transient_message,'offline close started a sync')
                elseif input.mode=='interval_close_conflict' then
                    wait(function() return host.transient_message~=nil end);assert(not finished)
                elseif input.mode=='interval_close_noack' then
                    wait(function() return finished end);assert(host.transient_message,'unknown close result not reported')
                else
                    wait(function() return finished or host.transient_message end)
                    assert(finished and not host.transient_message,'closed chapter sync failed')
                end
                service.start=original_start
            else
              if input.mode=='interval_offline' then host.isNetworkConnected=function() return false end end
              now=timer.due;local fire=timer.task;UI:unschedule(fire);fire()
              if input.mode=='interval_move' then
                wait(function() return native_worker.job~=nil end)
                reader.rolling:onGotoPage(3);UI:forceRePaint()
                wait(function() return not host._native_direct_position and timer.task~=nil end)
                assert(host._native_direct_interval==timer,'page change lost the verified baseline')
              elseif input.mode=='interval' then
                wait(function() return not timer.attempt end)
                assert(host._native_direct_interval==timer and not timer.dirty and not host.transient_message,
                    'automatic upload did not confirm the new baseline')
              else
                wait(function() return not host._native_direct_interval end)
                if input.mode~='interval_offline' then assert(host.transient_message,'paused timer did not report the result') end
                reader.rolling:onGotoPage(3);UI:forceRePaint()
                assert(not host._native_direct_interval,'paused timer restarted without a manual check')
              end
            end
        end
        if input.mode=='interval_noack' or input.mode=='interval_close_noack' then
            local service=require('weread.lib.native_position_service'):new{
                settings=host.settings,client=host.client,library=host.library_db,scheduler=UI}
            assert(assert(service:pending()).phase=='pending','automatic sync lost a request with an unknown result')
        end
        if input.mode=='upload_lost_ack' or input.mode=='upload_missing_after' then
            host.checked_message=nil;open_menu()
            wait(function() return host._native_direct_position and host._native_direct_position.confirm end)
            local review=host._native_direct_position
            review.confirm.ok_callback()
            wait(function() return host.checked_message~=nil or host._native_direct_position and host._native_direct_position.confirm end)
            if input.plain_text and input.mode=='upload_missing_after' then
                assert(host.checked_message==tr('Could not check the previous position sync.')
                    and not host._native_direct_position,'review accepted a TXT response without its literal summary')
                assert(assert(review.service:pending()).phase=='acknowledged','incomplete TXT reply lost the acknowledged request')
            else
                assert(not host.checked_message and host._native_direct_position.confirm,'review failed')
                host._native_direct_position.confirm.ok_callback()
                wait(function() return host.checked_message~=nil end)
                assert(host.checked_message==tr('Previous result archived. Choose sync again to check the current page.'))
            end
        end
    end
elseif input.mode=='move' or input.mode=='cloud_move' then
    wait(function() return native_worker.job~=nil end)
    assert(reader.rolling and reader.document:getPageCount()>2);reader.rolling:onGotoPage(2);UI:forceRePaint()
    wait(function() return native_worker.job==nil end)
    assert(not host.checked_message and not host._native_direct_position,'changed page accepted a stale result')
elseif input.mode=='cloud' or input.mode=='cloud_cancel' or input.mode=='cloud_after' then
    wait(function() return host.checked_message~=nil or host._native_direct_position and host._native_direct_position.confirm end)
    assert(not host.checked_message and host._native_direct_position and host._native_direct_position.confirm)
    local before=reader.document:getCurrentPage();local confirm=host._native_direct_position.confirm
    if input.mode=='cloud_cancel' then
        confirm.cancel_callback();assert(not host._native_direct_position and reader.document:getCurrentPage()==before)
    elseif input.mode=='cloud_after' then
        confirm.ok_callback();wait(function() return host.checked_message~=nil end)
        assert(host.checked_message==require('weread.lib.plugin_util').tr('The cloud position changed during the check. Your current page is kept.'))
        assert(reader.document:getCurrentPage()==before and not host._native_direct_position)
    else
        confirm.ok_callback();wait(function() return host.checked_message~=nil end)
        assert(host.checked_message==require('weread.lib.plugin_util').tr('Opened the cloud reading position in this chapter.'))
        assert(reader.document:getCurrentPage()~=before and not host._native_direct_position)
    end
elseif input.mode=='cloud_other' or input.mode:find('^cross_') then
    wait(function() return host.checked_message~=nil or host._native_direct_position and host._native_direct_position.confirm end)
    assert(not host.checked_message and host._native_direct_position and host._native_direct_position.confirm)
    local confirm=host._native_direct_position.confirm
    if input.mode=='cloud_other' then
        confirm.cancel_callback();assert(not host._native_direct_position and Reader.instance==reader)
    else
        confirm.ok_callback()
        if input.mode=='cross_changed' or input.mode=='cross_denied' or input.mode=='cross_unlocatable' then
            wait(function() return host.checked_message~=nil end)
            local expected=input.mode=='cross_changed' and 'The cloud position changed during the check. Your current page is kept.'
                or input.mode=='cross_denied' and 'The cloud chapter is not available to this account.'
                or 'The cloud position could not be located in the target chapter. Your current page is kept.'
            assert(host.checked_message==require('weread.lib.plugin_util').tr(expected) and Reader.instance==reader)
        elseif input.mode=='cross_after_switch' then
            wait(function() return destination_host and destination_host.checked_message~=nil end)
            assert(Reader.instance~=reader and Reader.instance.weread==destination_host
                and destination_host.checked_message==require('weread.lib.plugin_util').tr('The cloud position changed during the check. Your current page is kept.'))
            assert(Reader.instance.document:getCurrentPage()<=2)
        else
            wait(function() return destination_host and destination_host.checked_message~=nil end)
            assert(Reader.instance~=reader and Reader.instance.weread==destination_host
                and destination_host.checked_message==require('weread.lib.plugin_util').tr('Opened the cloud reading position in this chapter.'))
            assert(Reader.instance.document.file~=input.path and Reader.instance.document:getCurrentPage()>2)
            local matches=assert(Reader.instance.document:findAllText('Target paragraph 0100',false,0,3,false,0))
            assert(#matches==1 and matches[1].start and Reader.instance.document:isXPointerInCurrentPage(matches[1].start),
                'the independently identified cloud target is not on the opened page')
            if input.mode=='cross_cached' then assert(Reader.instance.document.file==input.second) end
        end
    end
else
    wait(function() return host.checked_message~=nil end)
    local tr=require('weread.lib.plugin_util').tr
    if input.mode=='mismatch' then
        assert(host.checked_message==tr('The chapter source changed, so the reading position could not be checked.') and not point)
    elseif input.mode=='cloud_changed' then
        assert(host.checked_message==tr('The cloud position changed during the check. Your current page is kept.') and not point)
    elseif input.mode=='cloud_empty' then
        assert(host.checked_message==tr('There is no cloud reading position yet. Your current page is kept.'))
    elseif input.mode=='preview_changed' or input.mode=='preview_web_changed' then
        assert(host.checked_message==tr('The cloud position changed during the check. Your current page is kept.') and not point)
    else
        assert(host.checked_message==tr('The local reading position was checked against the chapter source.'),tostring(point_error))
        local basis=input.plain_text and 'raw_txt_utf16' or 'filtered_xhtml_utf16'
        assert(point and point.upload_verified==false and point.source_current and point.basis==basis)
    end
end
print('WEREAD_POSITION_READER='..json.encode{ok=true,mode=input.mode,text=captured and captured.text or '',
    point_offset=captured and captured.offset or 0,offset=point and point.chapter_offset or -1})
