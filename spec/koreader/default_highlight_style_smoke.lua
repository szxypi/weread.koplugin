-- Actual chooser, durable preference, immutable preview and direct creation.
-- Only the loopback fixture is used; no public service or real credentials.
return function(reader,plugin,pump,shot,clean_popups,open,row,tap,request,same)
    local UI=require('ui/uimanager');local Style=require('weread.lib.mark_style');local Color=require('weread.lib.mark_color')
    local tr=require('weread.lib.plugin_util').tr;local Selection=require('weread.ui.selection_thought')
    local journal=require('weread.lib.mark_edit_service').new_journal(plugin.library_db,plugin.client)
    local baseline=request('/__state');local owner
    local function preview()
        pump(function() return not owner.mark_editor or owner.mark_editor.service.preview end)
        assert(owner.mark_editor and owner.mark_editor.service.preview)
    end
    local function notice()
        pump(function() return not owner.mark_editor end)
        local top=UI:getTopmostVisibleWidget();if top~=owner.menu then UI:close(top) end
    end
    local function choose(style)
        row(owner,'Default highlight style');local dialog=assert(owner.menu._shelf_popup)
        UI:forceRePaint();shot('default-highlight-chooser-'..style)
        dialog.buttontable:getButtonById('default_highlight_style_'..style):onTapSelectButton()
        assert(Style.default(plugin.settings)==style and not owner.menu._shelf_popup)
        local found=false
        for _i,item in ipairs(owner.menu.item_table) do
            if item.text==tr('Default highlight style') then found=item.mandatory==tr(Style.labels[style]) end
        end
        assert(found,'native menu did not show the saved default')
    end
    for index,style in ipairs({0,2}) do
        local color=index==1 and 3 or 5
        owner=open(true);choose(style);row(owner,'Default highlight color')
        local chooser=assert(owner.menu._shelf_popup);UI:forceRePaint();shot('default-highlight-color-'..color)
        chooser.buttontable:getButtonById('default_highlight_color_'..color):onTapSelectButton()
        assert(Color.default(plugin.settings)==color)
        row(owner,'Save highlight');preview()
        local editor=owner.mark_editor
        assert(editor.service.preview_job.input.style==style)
        assert(editor.service.preview_job.input.color==color)
        assert(editor.dialog.text:find(tr(Style.labels[style]),1,true),'confirmation lost the frozen style')
        -- A new preference must affect the next highlight, not an existing
        -- confirmation or the persisted request hash being sent now.
        plugin.settings:set('cloud_highlight_style',(style+1)%3);plugin.settings:flush()
        plugin.settings:set('cloud_highlight_color',(color+1)%6);plugin.settings:flush()
        tap(owner,'confirm_highlight_change');notice()
        local state=request('/__state');local created
        for key,value in pairs(state.selection_marks) do if not baseline.selection_marks[key] then
            assert(not created and value.style==style and value.colorStyle==color and value.markText==owner.reference.markText)
            created=key
        end end
        assert(created and state.highlight_posts==baseline.highlight_posts+index*2-1 and journal:read().phase=='idle')
        Selection.cancel(plugin);clean_popups(reader)
        pump(function() return plugin._personal_marks and plugin._personal_marks.complete end);UI:forceRePaint()
        local shown=false
        for _i,record in ipairs(plugin._personal_marks.records) do if record.bookmarkId==created then shown=record.style==style end end
        assert(shown and #plugin._personal_marks.overlay.visible>0,'direct initial style not drawn in reader')
        shot('default-highlight-created-'..style)
        assert(plugin:showMyCloudMarks(plugin:detectWeReadBook()));owner=assert(plugin._my_marks_owner)
        local found=false
        for _i,item in ipairs(owner.menu.item_table) do if item.my_note_id==created then item.callback();found=true;break end end
        assert(found);tap(owner,'delete_highlight');preview();tap(owner,'confirm_highlight_change');notice()
        state=request('/__state')
        assert(state.highlight_posts==baseline.highlight_posts+index*2 and same(state.selection_marks,baseline.selection_marks)
            and same(state.selection_thoughts,baseline.selection_thoughts) and journal:read().phase=='idle')
        plugin:cancelMyCloudMarks();clean_popups(reader)
    end
    local online=plugin.isNetworkOnline;plugin.isNetworkOnline=function() return false end
    owner=open(true);choose(1)
    row(owner,'Default highlight color');UI:forceRePaint()
    owner.menu._shelf_popup.buttontable:getButtonById('default_highlight_color_0'):onTapSelectButton()
    assert(Color.default(plugin.settings)==0)
    assert(request('/__state').highlight_posts==baseline.highlight_posts+4,'offline preference caused a write')
    Selection.cancel(plugin);clean_popups(reader);plugin.isNetworkOnline=online
    return 4
end
