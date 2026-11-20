-- All colors through actual widgets, worker claims, SQLite and loopback HTTP.
return function(reader,plugin,pump,shot,clean_popups,tap,request,same,created)
    local UI=require('ui/uimanager');local Colors=require('weread.lib.mark_color')
    local Journal=require('weread.lib.mark_edit_service').new_journal(plugin.library_db,plugin.client)
    local before=request('/__state');local baseline=before.selection_marks[created];local owner
    local function select(id)
        assert(plugin:showMyCloudMarks(plugin:detectWeReadBook()));owner=assert(plugin._my_marks_owner)
        for _i,item in ipairs(owner.menu.item_table) do if item.my_note_id==id then item.callback();return end end
        error('missing color target')
    end
    local function preview()
        pump(function() return not owner.mark_editor or owner.mark_editor.service.preview end)
        assert(owner.mark_editor and owner.mark_editor.service.preview)
    end
    local function notice()
        pump(function() return not owner.mark_editor end)
        local top=UI:getTopmostVisibleWidget();if top~=owner.menu then UI:close(top) end
    end
    for index,color in ipairs({1,2,3,4,5,0}) do
        plugin:cancelMyCloudMarks();clean_popups(reader);select(created);tap(owner,'change_highlight_color')
        local chooser=assert(owner.menu._shelf_popup);UI:forceRePaint()
        if index==1 then shot('highlight-color-chooser') end
        chooser.buttontable:getButtonById('highlight_color_'..color):onTapSelectButton();preview()
        assert(owner.mark_editor.dialog.text:find(require('weread.lib.plugin_util').tr(Colors.labels[color]),1,true))
        assert(owner.mark_editor.service.preview_job.input.color==color)
        if index==3 then request('/__control',{selection_thought_mode='empty'}) end
        tap(owner,'confirm_highlight_change');notice();request('/__control',{selection_thought_mode='plain'})
        local state=request('/__state');local row=assert(state.selection_marks[created])
        local expected={};for k,v in pairs(baseline) do expected[k]=v end;expected.colorStyle=color
        assert(same(row,expected) and state.highlight_posts==before.highlight_posts+index and Journal:read().phase=='idle')
        assert(same(state.selection_thoughts,before.selection_thoughts))
    end
    plugin:cancelMyCloudMarks();clean_popups(reader);select('synthetic-existing-highlight');tap(owner,'change_highlight_color')
    owner.menu._shelf_popup.buttontable:getButtonById('highlight_color_3'):onTapSelectButton();preview()
    request('/__control',{selection_thought_mode='no_change'});tap(owner,'confirm_highlight_change');notice()
    assert(Journal:read().phase=='pending' and Journal:read().metadata.operation=='color')
    local posts=request('/__state').highlight_posts
    local checking=false
    for _i,item in ipairs(owner.menu.item_table) do
        if item.text==require('weread.lib.plugin_util').tr('Check last cloud mark change') then item.callback();checking=true;break end
    end
    assert(checking,'missing production color recovery action')
    preview();assert(not owner.mark_editor.service.preview.confirmed);tap(owner,'resolve_highlight_change');notice()
    assert(Journal:read().phase=='idle' and request('/__state').highlight_posts==posts,'color recovery replayed a write')
    plugin:cancelMyCloudMarks();clean_popups(reader);request('/__control',{selection_thought_mode='plain'})
    local state=request('/__state');assert(same(state.selection_marks,before.selection_marks) and same(state.selection_thoughts,before.selection_thoughts))
    local f=assert(io.open(os.getenv('WEREAD_EVIDENCE')..'/mark-color-result.json','wb'))
    f:write(require('json').encode{result='PASS',synthetic_only=true,all_palette_values=true,style_source_and_time_preserved=true,
        linked_thought_color_pending=true,lost_receipt_readback=true,unknown_receipt_no_replay=true,readonly_recovery=true,
        mock_data_posts=7,real_account_data_posts=0});f:close()
    return 7
end
