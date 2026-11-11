-- Actual native selection menu/editor, workers, SQLite and loopback HTTP.
-- No real account, gesture claim, or public Internet access.
return function(reader,plugin,pump,shot,clean_popups,reopen)
    local Json,HTTP,LTN=require('json'),require('socket.http'),require('ltn12')
    local UI=require('ui/uimanager');local tr=require('weread.lib.plugin_util').tr
    local Selection=require('weread.ui.selection_thought');local id=assert(plugin:detectWeReadBook())
    assert(plugin.settings.mock_endpoint:match('^http://127%.0%.0%.1:%d+$'))
    local Reference=require('weread.lib.selection_reference');local capture_native=Reference.capture_native
    function Reference.capture_native(input,...)
        local file=assert(io.open(os.getenv('WEREAD_EVIDENCE')..'/selection-synthetic-context.json','wb'))
        file:write(Json.encode(input));file:close();return capture_native(input,...)
    end
    local function request(path,value)
        local pieces,body={},value and Json.encode(value)
        local _,code=HTTP.request{url=plugin.settings.mock_endpoint..path,proxy=plugin.settings.mock_endpoint,
            method=body and 'POST' or 'GET',source=body and LTN.source.string(body),sink=LTN.sink.table(pieces),
            headers=body and {['Content-Type']='application/json',['Content-Length']=tostring(#body)} or {}}
        assert(code==200);return Json.decode(table.concat(pieces))
    end
    local function copy(value) return Json.decode(Json.encode(value)) end
    local function counter(path)
        local count=0;for _i,row in ipairs(request('/__state').totals) do if row.path==path then count=count+row.count end end;return count
    end
    local function same(a,b)
        if type(a)~=type(b) then return false end
        if type(a)~='table' then return a==b end
        for key,value in pairs(a) do if not same(value,b[key]) then return false end end
        for key in pairs(b) do if a[key]==nil then return false end end;return true
    end
    if reopen then
        local journal=require('weread.lib.thought_edit_store'):new(plugin.library_db,plugin.client)
        assert(journal:read().phase=='pending' and #journal:drafts()==1,'fresh process lost selection draft or pending operation')
        plugin:showMyCloudThoughts(id);local own=assert(plugin._my_marks_owner)
        for _i,item in ipairs(own.menu.item_table) do if item.text==tr('Local thought drafts') then item.callback();break end end
        own.editor.dialog.item_table[1].callback();UI:forceRePaint()
        own.menu._shelf_popup.button_table:getButtonById('resume_thought_draft'):onTapSelectButton()
        pump(function() return own.editor and own.editor.input end)
        assert(own.editor.input:getInputText()=='等待独立核对的选区想法','offline resume lost pending draft text')
        assert(journal:read().phase=='pending','offline resume replayed or cleared pending operation')
        shot('selection-thought-offline-reopen');plugin:cancelMyCloudMarks();clean_popups(reader)
        local file=assert(io.open(os.getenv('WEREAD_EVIDENCE')..'/selection-thought-reopen-result.json','wb'))
        file:write(Json.encode{result='PASS',synthetic_only=true,fresh_process=true,offline_source_restore=true,
            local_draft_and_pending_kept=true,offline_http_requests=0,automatic_replay=false});file:close();return
    end
    local original=copy(request('/__state').selection_thoughts)
    local auth_posts=counter('/login')+counter('/web/login/renewal')
    local original_online=plugin.isNetworkOnline
    local scope=plugin.settings:get_auth_scope();local credentials=require('weread.lib.native_credentials'):new(plugin.settings)
    local _,revision=credentials:read()
    assert(credentials:save({vid=scope.vid,accessToken='mock-native-access',refreshToken='mock-native-refresh',
        deviceId='eink334691225'..string.rep('1',19)},scope,revision,26))
    local config=copy(plugin.settings:get('sync'));local quiet=copy(config);quiet.upload_on_close=false;quiet.upload_interval_minutes=0
    plugin.settings:set('sync',quiet);plugin.settings:flush();plugin.progress_sync.interval:halt()
    clean_popups(reader)
    local text='选区专用开始😀&标记跨标签文字结尾🙂\n第二段选区验证。'
    local firsts=reader.document:findAllText('选区专用开始',false,0,10,false,0)
    local lasts=reader.document:findAllText('第二段选区验证。',false,0,10,false,0)
    assert(firsts and #firsts==1 and lasts and #lasts==1)
    local first,last=firsts[1].start,lasts[1]['end']
    reader.rolling:onGotoXPointer(first)
    UI:setInputTimeout(0);UI:handleInput();UI:forceRePaint()
    local selected={pos0=first,pos1=last,text=reader.document:getTextFromXPointers(first,last)}
    assert(require('weread.lib.source_dom').normalize(selected.text)==require('weread.lib.source_dom').normalize(text))
    local origin=reader.document:getXPointer();local notes=copy(reader.annotation.annotations)
    local journal=require('weread.lib.thought_edit_store'):new(plugin.library_db,plugin.client)
    local client_request=plugin.client.request;local parent=tonumber(require('ffi').C.getpid())
    function plugin.client:request(options)
        local operation=({['https://i.weread.qq.com/review/add']='create',['https://i.weread.qq.com/review/useredit']='edit',
            ['https://i.weread.qq.com/review/delete']='delete'})[options.url]
        if operation or options.url:find('https://i.weread.qq.com/review/list?',1,true) or options.diagnostic_api=='source_currentness' then
            assert(tonumber(require('ffi').C.getpid())~=parent,'selection verification blocked native UI')
        end
        if operation then
            local intent=assert(journal:read());local body=Json.decode(options.body)
            assert(intent.phase=='pending' and intent.metadata.operation==operation and intent.metadata.book_id==id)
            assert(intent.metadata.request_hash==require('weread.lib.thought_edit_contract').body_hash(body))
            assert(operation=='create' and body.chapterIdx==nil and body.isPrivate==1 or operation~='create' and body.reviewId~='synthetic-existing-thought')
            assert(options.skip_cookie and options.persist_response_cookies==false and options.sensitive and not options.headers.Cookie)
        end
        return client_request(self,options)
    end
    local function row(owner,label)
        for _i,item in ipairs(owner.menu.item_table) do if item.text==tr(label) then item.callback();return end end
        error('missing native selection row: '..label)
    end
    local function tap(owner,key)
        UI:forceRePaint();assert(owner.menu._shelf_popup.button_table:getButtonById(key),'missing editor button '..key):onTapSelectButton()
    end
    local function open()
        clean_popups(reader);reader.highlight.selected_text=copy(selected);reader.highlight:onShowHighlightMenu()
        UI:forceRePaint()
        assert(reader.highlight.highlight_dialog.buttontable:getButtonById('weread_selection_thought')):onTapSelectButton()
        local started_owner
        pump(function()
            started_owner=plugin._selection_thought_owner or started_owner
            return started_owner and (started_owner.reference or started_owner.error)
        end)
        assert(started_owner.reference,'native selection capture failed: '..tostring(started_owner.error))
        assert(not reader.highlight.selected_text,'consumed selection still blocks native source capture')
        local owner=plugin._selection_thought_owner
        assert(owner.reference.selection and owner.reference.markText==text)
        row(owner,'Write private thought');assert(owner.editor.input)
        return owner
    end
    local content='来自原生选区的私密想法 😀\n第二行内容'
    plugin.isNetworkOnline=function() return false end
    local owner=open();owner.editor.input:setInputText(content);tap(owner,'save_thought_draft')
    assert(request('/__state').selection_posts==0 and #journal:drafts()==1)
    shot('selection-thought-offline-draft');Selection.cancel(plugin);clean_popups(reader)
    owner=open();require('weread.ui.thought_editor').cancel(plugin,owner);row(owner,'Local thought drafts')
    owner.editor.dialog.item_table[1].callback();tap(owner,'resume_thought_draft')
    pump(function() return owner.editor and owner.editor.input end)
    assert(owner.editor.input:getInputText()==content,'selection draft lost text or source')
    plugin.isNetworkOnline=original_online
    tap(owner,'submit_thought');pump(function() return not owner.editor or owner.editor.service.preview end)
    assert(owner.editor and owner.editor.service.preview,'selection source preflight failed')
    shot('selection-thought-native-confirmation');tap(owner,'confirm_thought_change');pump(function() return not owner.editor end)
    local state=request('/__state');assert(state.selection_posts==1 and journal:read().phase=='idle' and #journal:drafts()==0)
    local created
    for key,value in pairs(state.selection_thoughts) do
        if key~='synthetic-existing-thought' then assert(not created and value.isPrivate==1 and value.content==content and value.abstract==text);created=key end
    end
    assert(created and same(state.selection_thoughts['synthetic-existing-thought'],original['synthetic-existing-thought']))
    Selection.cancel(plugin);clean_popups(reader)
    local function operate(operation,new_text)
        plugin:showMyCloudThoughts(id);local own=assert(plugin._my_marks_owner)
        local item
        for _i,value in ipairs(own.menu.item_table) do if value.my_note_id==created then item=value end end
        assert(item);item.callback();tap(own,'thought_'..operation)
        if new_text then own.editor.input:setInputText(new_text);tap(own,'submit_thought') end
        pump(function() return own.editor and own.editor.service.preview end)
        tap(own,'confirm_thought_change');pump(function() return not own.editor end)
        plugin:cancelMyCloudMarks();clean_popups(reader)
    end
    operate('edit','已修改的新选区想法');assert(request('/__state').selection_thoughts[created].content=='已修改的新选区想法')
    operate('delete');assert(request('/__state').selection_posts==3 and same(request('/__state').selection_thoughts,original))
    owner=open();owner.editor.input:setInputText('来源变化时保留草稿');tap(owner,'submit_thought')
    pump(function() return owner.editor and owner.editor.service.preview end)
    request('/__control',{selection_source_revision=2});tap(owner,'confirm_thought_change');pump(function() return not owner.editor end)
    assert(request('/__state').selection_posts==3 and journal:read().phase=='idle' and #journal:drafts()==1,'changed source dispatched or lost draft')
    request('/__control',{selection_source_revision=1})
    Selection.cancel(plugin);clean_popups(reader)
    owner=open();owner.editor.input:setInputText('取消检查时保留的草稿');tap(owner,'submit_thought')
    local worker=owner.editor.service.worker;local pid=worker.job and worker.job.pid
    Selection.cancel(plugin);clean_popups(reader)
    if pid then pump(function() return worker.runner.done(pid) end) end
    assert(request('/__state').selection_posts==3 and journal:read().phase=='idle' and #journal:drafts()==1)
    owner=open();owner.editor.input:setInputText('原文授权失效时保留的草稿')
    request('/__control',{match='/web/book/chapter/e_0',status=401,times=1});tap(owner,'submit_thought')
    pump(function() return not owner.editor end)
    assert(request('/__state').selection_posts==3 and journal:read().phase=='idle' and #journal:drafts()==1)
    assert(UI:getTopmostVisibleWidget().text==tr('Log in again to verify the selected text. Your local draft is kept.'))
    request('/__control',{match='',times=0,status=503});Selection.cancel(plugin);clean_popups(reader)
    owner=open();owner.editor.input:setInputText('派发前取消时保留的草稿');tap(owner,'submit_thought')
    pump(function() return owner.editor and owner.editor.service.preview end)
    request('/__control',{match='/web/book/chapter/e_0',status=503,times=1,delay=2})
    tap(owner,'confirm_thought_change')
    pump(function()
        for target,count in pairs(request('/__state').active_requests) do if count>0 and target:find('/web/book/chapter/e_0',1,true) then return true end end
        return false
    end)
    assert(journal:read().phase=='prepared','source preflight claimed a write too early')
    Selection.cancel(plugin);clean_popups(reader)
    assert(journal:read().phase=='idle' and request('/__state').selection_posts==3 and #journal:drafts()==1)
    request('/__control',{match='',times=0,delay=0})
    request('/__control',{selection_thought_mode='empty'})
    owner=open();owner.editor.input:setInputText('丢失回执仍独立核对的私密选区想法');tap(owner,'submit_thought')
    pump(function() return owner.editor and owner.editor.service.preview end)
    tap(owner,'confirm_thought_change');pump(function() return not owner.editor end)
    state=request('/__state');assert(state.selection_posts==4 and journal:read().phase=='idle' and #journal:drafts()==0)
    created=nil;for key in pairs(state.selection_thoughts) do if key~='synthetic-existing-thought' then assert(not created);created=key end end
    assert(created);Selection.cancel(plugin);clean_popups(reader);operate('delete')
    assert(request('/__state').selection_posts==5 and same(request('/__state').selection_thoughts,original))
    request('/__control',{selection_thought_mode='no_change'})
    owner=open();owner.editor.input:setInputText('等待独立核对的选区想法');tap(owner,'submit_thought')
    pump(function() return owner.editor and owner.editor.service.preview end)
    tap(owner,'confirm_thought_change');pump(function() return not owner.editor end)
    assert(request('/__state').selection_posts==6 and journal:read().phase=='pending' and #journal:drafts()==1)
    row(owner,'Write private thought');tap(owner,'submit_thought');assert(not owner.editor)
    assert(request('/__state').selection_posts==6 and journal:read().phase=='pending','unknown result resent')
    Selection.cancel(plugin);clean_popups(reader)
    request('/__control',{selection_thought_mode='plain'})
    assert(reader.document:getXPointer()==origin and same(reader.annotation.annotations,notes),'selection workflow moved reader or changed notes')
    assert(counter('/login')+counter('/web/login/renewal')==auth_posts,'selection workflow renewed authentication automatically')
    plugin.client.request=client_request
    plugin.settings:set('sync',config);plugin.settings:flush();plugin.progress_sync.interval:halt()
    local file=assert(io.open(os.getenv('WEREAD_EVIDENCE')..'/selection-thought-result.json','wb'))
    file:write(Json.encode{result='PASS',synthetic_only=true,actual_selection_menu=true,cooperative_native_capture=true,
        background_source_verification=true,offline_draft_restore=true,private_create_edit_delete=true,
        changed_source_refuses_post=true,original_thought_preserved=true,reader_position_and_notes_preserved=true,
        lost_receipt_independent_readback=true,unknown_result_pending_no_resend=true,unicode_entities_and_cross_paragraph=true,
        cancelled_preparation_keeps_draft=true,cancelled_source_preflight_prevents_dispatch=true,web_401_keeps_draft_without_renewal=true,
        durable_pending_before_post=true,optional_native_index_omitted=true,mock_data_posts=6,real_account_data_posts=0});file:close()
end
