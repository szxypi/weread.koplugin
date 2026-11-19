-- Imported-book native highlight create/delete against a closed mock only.
return function(reader,plugin,pump,clean,offline)
    local Json,HTTP,LTN=require('json'),require('socket.http'),require('ltn12')
    local UI,tr=require('ui/uimanager'),require('weread.lib.plugin_util').tr
    local Selection=require('weread.ui.selection_thought')
    local journal=require('weread.lib.mark_edit_service').new_journal(plugin.library_db,plugin.client)
    local id=assert(plugin:detectWeReadBook());assert(id=='CB_SyntheticResume')
    if offline then
        local pending=assert(journal:read())
        assert(pending.phase=='pending' and pending.metadata.book_id==id and pending.metadata.operation=='create',
            'offline reopen lost the unconfirmed imported highlight')
        local cached=assert(require('weread.lib.my_cloud_marks_store'):new(plugin.library_db,plugin.client):read(id))
        for _i,row in ipairs(cached.updated) do assert(not row.bookmarkId:match('^synthetic%-new%-highlight%-')) end
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
        return transport(self,options)
    end
    local function open()
        clean(reader);reader.highlight.selected_text=selected;reader.highlight:onShowHighlightMenu();UI:forceRePaint()
        assert(reader.highlight.highlight_dialog.buttontable:getButtonById('weread_selection_thought')):onTapSelectButton()
        local owner
        pump(function() owner=plugin._selection_thought_owner or owner;return owner and (owner.reference or owner.error) end)
        assert(owner.reference,'imported selection was not bound to source')
        for _i,item in ipairs(owner.menu.item_table) do
            assert(item.text~=tr('Write private thought') and item.text~=tr('Default highlight style')
                and item.text~=tr('Default highlight color'),'unverified imported edit action was exposed')
        end
        return owner
    end
    local before=request('/__state');local owner=open();row(owner,'Save highlight');preview(owner)
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
        and not buttons:getButtonById('thought_create'),'unverified imported modification exposed')
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
    request('/__control',{selection_thought_mode='plain'});Selection.cancel(plugin);clean(reader)
    plugin.client.request=transport
    local file=assert(io.open(os.getenv('WEREAD_EVIDENCE')..'/cb-highlight-edit.json','wb'))
    file:write(Json.encode{result='PASS',fixture='synthetic',create_delete_verified=true,source_change_refused=true,
        unknown_result_no_replay=true,read_only_recovery=true,default_style_bound=true,unverified_actions_hidden=true,
        pending_survives_offline_reopen=true,mock_data_posts=4,real_account_posts=0});file:close()
end
