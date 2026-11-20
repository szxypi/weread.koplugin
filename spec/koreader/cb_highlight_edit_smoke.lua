-- Imported-book native highlight create/delete against a closed mock only.
return function(reader,plugin,pump,clean,offline)
    local Json,HTTP,LTN=require('json'),require('socket.http'),require('ltn12')
    local UI,tr=require('ui/uimanager'),require('weread.lib.plugin_util').tr
    local Selection=require('weread.ui.selection_thought')
    local journal=require('weread.lib.mark_edit_service').new_journal(plugin.library_db,plugin.client)
    local thought_journal=require('weread.lib.thought_edit_store'):new(plugin.library_db,plugin.client)
    local id=assert(plugin:detectWeReadBook());assert(id=='CB_SyntheticResume')
    if offline then
        local pending=assert(journal:read())
        assert(pending.phase=='pending' and pending.metadata.book_id==id and pending.metadata.operation=='create',
            'offline reopen lost the unconfirmed imported highlight')
        local cached=assert(require('weread.lib.my_cloud_marks_store'):new(plugin.library_db,plugin.client):read(id))
        for _i,row in ipairs(cached.updated) do assert(not row.bookmarkId:match('^synthetic%-new%-highlight%-')) end
        local thought_pending=assert(thought_journal:read())
        assert(thought_pending.phase=='pending' and thought_pending.metadata.book_id==id and #thought_journal:drafts()==1,
            'offline reopen lost imported selection thought or its draft')
        return
    end
    local function request(path,value)
        local chunks,body={},value and Json.encode(value)
        local _,status=HTTP.request{url=plugin.settings.mock_endpoint..path,proxy=plugin.settings.mock_endpoint,
            method=body and 'POST' or 'GET',source=body and LTN.source.string(body),sink=LTN.sink.table(chunks),
            headers=body and {['Content-Type']='application/json',['Content-Length']=tostring(#body)} or {}}
        assert(status==200);return Json.decode(table.concat(chunks))
    end
    local function row(owner,label)
        for _i,item in ipairs(owner.menu.item_table) do if item.text==tr(label) then item.callback();return end end
        error('missing selection action',0)
    end
    local function tap(owner,key)
        UI:forceRePaint();assert(owner.menu._shelf_popup.button_table:getButtonById(key)):onTapSelectButton()
    end
    local function preview(owner)
        pump(function() return not owner.mark_editor or owner.mark_editor.service.preview end)
        assert(owner.mark_editor and owner.mark_editor.service.preview,'imported mark preview failed')
    end
    local function notice(owner)
        pump(function() return not owner.mark_editor end)
        local top=UI:getTopmostVisibleWidget();if top~=owner.menu then UI:close(top) end
    end
    local scope=plugin.settings:get_auth_scope();local credentials=require('weread.lib.native_credentials'):new(plugin.settings)
    local _,revision=credentials:read()
    assert(credentials:save({vid=scope.vid,accessToken='mock-native-access',refreshToken='mock-native-refresh',
        deviceId='eink334691225'..string.rep('1',19)},scope,revision,26))
    plugin.settings:set('cloud_highlight_style',2);plugin.settings:set('cloud_highlight_color',3);plugin.settings:flush()
    clean(reader)
    local firsts=reader.document:findAllText('选区专用开始',false,0,10,false,0)
    local lasts=reader.document:findAllText('第二段选区验证。',false,0,10,false,0)
    assert(firsts and #firsts==1 and lasts and #lasts==1)
    local first,last=firsts[1].start,lasts[1]['end'];reader.rolling:onGotoXPointer(first);UI:forceRePaint()
    local selected={pos0=first,pos1=last,text=reader.document:getTextFromXPointers(first,last)}
    local function same(a,b)
        if type(a)~=type(b) then return false end
        if type(a)~='table' then return a==b end
        for key,value in pairs(a) do if not same(value,b[key]) then return false end end
        for key in pairs(b) do if a[key]==nil then return false end end
        return true
    end
    dofile('/source/spec/koreader/bookmark_editor_smoke.lua')(reader,plugin,pump,function() end,clean,row,tap,request,same)
    local transport=plugin.client.request;local parent=tonumber(require('ffi').C.getpid())
    function plugin.client:request(options)
        local operation=({['https://i.weread.qq.com/book/addBookmark']='create',
            ['https://i.weread.qq.com/book/removeBookmark']='delete'})[options.url]
        if operation then
            assert(tonumber(require('ffi').C.getpid())~=parent,'write ran on UI thread')
            local intent=assert(journal:read());local body=Json.decode(options.body)
            assert(intent.phase=='pending' and intent.metadata.operation==operation and intent.metadata.book_id==id)
            assert(intent.metadata.request_hash==require('weread.lib.mark_edit_contract').body_hash(body))
            if operation=='create' then assert(body.bookId==id and body.style==1 and body.colorStyle==0) end
        end
        local thought_operation=({['https://i.weread.qq.com/review/add']='create',
            ['https://i.weread.qq.com/review/useredit']='edit',['https://i.weread.qq.com/review/delete']='delete'})[options.url]
        if thought_operation then
            assert(tonumber(require('ffi').C.getpid())~=parent,'thought write ran on UI thread')
            local intent=assert(thought_journal:read());local body=Json.decode(options.body)
            assert(intent.phase=='pending' and intent.metadata.operation==thought_operation and intent.metadata.book_id==id)
            assert(intent.metadata.request_hash==require('weread.lib.thought_edit_contract').body_hash(body))
            if thought_operation=='create' then assert(body.bookId==id and body.isPrivate==1 and body.chapterIdx==nil)
            else assert(body.reviewId~='synthetic-existing-thought') end
        end
        return transport(self,options)
    end
    local function open()
        clean(reader);reader.highlight.selected_text=selected;reader.highlight:onShowHighlightMenu();UI:forceRePaint()
        assert(reader.highlight.highlight_dialog.buttontable:getButtonById('weread_selection_thought')):onTapSelectButton()
        local owner
        pump(function() owner=plugin._selection_thought_owner or owner;return owner and (owner.reference or owner.error) end)
        assert(owner.reference,'imported selection was not bound to source')
        for _i,item in ipairs(owner.menu.item_table) do
            assert(item.text~=tr('Default highlight style')
                and item.text~=tr('Default highlight color'),'unverified imported edit action was exposed')
        end
        return owner
    end
    local before=request('/__state');local owner=open();row(owner,'Write private thought')
    local online=plugin.isNetworkOnline;plugin.isNetworkOnline=function() return false end
    owner.editor.input:setInputText('导入书选区私密想法');tap(owner,'save_thought_draft')
    assert(#thought_journal:drafts()==1 and request('/__state').selection_posts==0,'offline imported draft failed')
    Selection.cancel(plugin);clean(reader);owner=open();row(owner,'Local thought drafts')
    owner.editor.dialog.item_table[1].callback();tap(owner,'resume_thought_draft')
    pump(function() return owner.editor and owner.editor.input end)
    assert(owner.editor.input:getInputText()=='导入书选区私密想法','imported draft could not resume')
    plugin.isNetworkOnline=online;tap(owner,'submit_thought')
    pump(function() return owner.editor and owner.editor.service.preview end)
    request('/__control',{selection_source_revision=2});tap(owner,'confirm_thought_change')
    pump(function() return not owner.editor end)
    assert(request('/__state').selection_posts==0 and thought_journal:read().phase=='idle'
        and #thought_journal:drafts()==1,'changed imported source dispatched or lost draft')
    request('/__control',{selection_source_revision=1});Selection.cancel(plugin);clean(reader)
    owner=open();row(owner,'Write private thought')
    assert(owner.editor.input:getInputText()=='导入书选区私密想法','changed-source draft was not retained')
    tap(owner,'submit_thought');pump(function() return owner.editor and owner.editor.service.preview end)
    tap(owner,'confirm_thought_change');pump(function() return not owner.editor end)
    local direct_state=request('/__state');local direct
    for key,value in pairs(direct_state.selection_thoughts) do
        if not before.selection_thoughts[key] then
            assert(not direct and value.isPrivate==1 and value.content=='导入书选区私密想法');direct=key
        end
    end
    assert(direct and direct_state.selection_posts==1 and thought_journal:read().phase=='idle'
        and #thought_journal:drafts()==0,'imported selection thought creation failed')
    Selection.cancel(plugin);clean(reader)
    for _i,op in ipairs({'edit','delete'}) do
        assert(plugin:showMyCloudThoughts(id));owner=assert(plugin._my_marks_owner)
        local item;for _j,value in ipairs(owner.menu.item_table) do if value.my_note_id==direct then item=value end end
        assert(item);item.callback();tap(owner,'thought_'..op)
        if op=='edit' then owner.editor.input:setInputText('导入书选区想法已修改');tap(owner,'submit_thought') end
        pump(function() return owner.editor and owner.editor.service.preview end)
        tap(owner,'confirm_thought_change');pump(function() return not owner.editor end)
        direct_state=request('/__state')
        assert(thought_journal:read().phase=='idle' and (op=='edit' and direct_state.selection_thoughts[direct].content=='导入书选区想法已修改'
            or op=='delete' and not direct_state.selection_thoughts[direct]),'imported selection thought change failed')
        plugin:cancelMyCloudMarks();clean(reader)
    end
    assert(direct_state.selection_posts==3 and direct_state.selection_thoughts['synthetic-existing-thought'],'original thought changed')
    owner=open();row(owner,'Save highlight');preview(owner)
    tap(owner,'confirm_highlight_change');notice(owner)
    local state=request('/__state');local created
    for key,value in pairs(state.selection_marks) do
        if not before.selection_marks[key] then assert(not created and value.markText==owner.reference.markText);created=key end
    end
    assert(created and state.highlight_posts==1 and journal:read().phase=='idle','imported creation not confirmed')
    Selection.cancel(plugin);clean(reader)
    pump(function() return plugin._personal_marks and plugin._personal_marks.complete end)
    local found=false;for _i,record in ipairs(plugin._personal_marks.records) do if record.bookmarkId==created then found=true end end
    assert(found,'created imported highlight missing from native reader')
    assert(plugin:showMyCloudMarks(id));owner=assert(plugin._my_marks_owner)
    for _i,item in ipairs(owner.menu.item_table) do if item.my_note_id==created then item.callback();break end end
    local buttons=assert(owner.menu._shelf_popup.button_table)
    assert(not buttons:getButtonById('change_highlight_style') and not buttons:getButtonById('change_highlight_color')
        and buttons:getButtonById('thought_create'),'imported highlight actions are incorrect')
    tap(owner,'thought_create');owner.editor.input:setInputText('合成导入书私密想法');tap(owner,'submit_thought')
    pump(function() return owner.editor and owner.editor.service.preview end)
    tap(owner,'confirm_thought_change');pump(function() return not owner.editor end)
    state=request('/__state');local thought
    for key,value in pairs(state.selection_thoughts) do
        if not before.selection_thoughts[key] then
            assert(not thought and value.isPrivate==1 and value.content=='合成导入书私密想法');thought=key
        end
    end
    assert(thought and thought_journal:read().phase=='idle' and state.selection_posts==4,'imported private thought was not confirmed')
    plugin:cancelMyCloudMarks();clean(reader)
    for _i,op in ipairs({'edit','delete'}) do
        assert(plugin:showMyCloudThoughts(id));owner=assert(plugin._my_marks_owner)
        local item;for _j,value in ipairs(owner.menu.item_table) do if value.my_note_id==thought then item=value end end
        assert(item,'imported private thought missing');item.callback();tap(owner,'thought_'..op)
        if op=='edit' then owner.editor.input:setInputText('合成导入书修改想法');tap(owner,'submit_thought') end
        pump(function() return owner.editor and owner.editor.service.preview end)
        tap(owner,'confirm_thought_change');pump(function() return not owner.editor end)
        state=request('/__state')
        assert(thought_journal:read().phase=='idle' and (op=='edit' and state.selection_thoughts[thought].content=='合成导入书修改想法'
            or op=='delete' and not state.selection_thoughts[thought]),'imported private thought change failed')
        plugin:cancelMyCloudMarks();clean(reader)
    end
    assert(state.selection_posts==6 and state.selection_thoughts['synthetic-existing-thought'],'original thought changed')
    assert(plugin:showMyCloudMarks(id));owner=assert(plugin._my_marks_owner)
    for _i,item in ipairs(owner.menu.item_table) do if item.my_note_id==created then item.callback();break end end
    tap(owner,'delete_highlight');preview(owner);tap(owner,'confirm_highlight_change');notice(owner)
    state=request('/__state');assert(state.highlight_posts==2 and not state.selection_marks[created]
        and state.selection_marks['synthetic-existing-highlight'] and journal:read().phase=='idle','imported delete failed')
    plugin:cancelMyCloudMarks();clean(reader)
    owner=open();row(owner,'Save highlight');preview(owner)
    request('/__control',{selection_source_revision=2});tap(owner,'confirm_highlight_change');notice(owner)
    assert(request('/__state').highlight_posts==2 and journal:read().phase=='idle','changed source dispatched')
    request('/__control',{selection_source_revision=1});Selection.cancel(plugin);clean(reader)
    owner=open();row(owner,'Save highlight');preview(owner)
    request('/__control',{selection_thought_mode='no_change'});tap(owner,'confirm_highlight_change');notice(owner)
    assert(request('/__state').highlight_posts==3 and journal:read().phase=='pending','unknown result lost')
    row(owner,'Save highlight');assert(not owner.mark_editor and request('/__state').highlight_posts==3,'unknown result resent')
    notice(owner);row(owner,'Check last cloud mark change');preview(owner)
    assert(not owner.mark_editor.service.preview.confirmed);tap(owner,'resolve_highlight_change');notice(owner)
    assert(journal:read().phase=='idle' and request('/__state').highlight_posts==3,'read-only recovery failed')
    Selection.cancel(plugin);clean(reader)
    owner=open();row(owner,'Save highlight');preview(owner);tap(owner,'confirm_highlight_change');notice(owner)
    assert(journal:read().phase=='pending' and request('/__state').highlight_posts==4,'offline pending fixture was not retained')
    Selection.cancel(plugin);clean(reader)
    owner=open();row(owner,'Write private thought');owner.editor.input:setInputText('导入书待核对选区想法')
    tap(owner,'submit_thought');pump(function() return owner.editor and owner.editor.service.preview end)
    tap(owner,'confirm_thought_change');pump(function() return not owner.editor end)
    assert(request('/__state').selection_posts==7 and thought_journal:read().phase=='pending'
        and #thought_journal:drafts()==1,'unconfirmed imported thought or draft was lost')
    row(owner,'Write private thought');tap(owner,'submit_thought');assert(not owner.editor)
    assert(request('/__state').selection_posts==7 and thought_journal:read().phase=='pending','unconfirmed thought was resent')
    request('/__control',{selection_thought_mode='plain'});Selection.cancel(plugin);clean(reader)
    plugin.client.request=transport
    local file=assert(io.open(os.getenv('WEREAD_EVIDENCE')..'/cb-highlight-edit.json','wb'))
    file:write(Json.encode{result='PASS',fixture='synthetic',create_delete_verified=true,source_change_refused=true,
        unknown_result_no_replay=true,read_only_recovery=true,default_style_bound=true,unverified_actions_hidden=true,
        pending_survives_offline_reopen=true,private_thought_create_edit_delete=true,selection_thought_draft_and_writes=true,
        changed_selection_source_keeps_draft=true,selection_pending_offline_no_replay=true,
        imported_bookmark_save_locate_delete=true,mock_data_posts=13,real_account_posts=0});file:close()
end
