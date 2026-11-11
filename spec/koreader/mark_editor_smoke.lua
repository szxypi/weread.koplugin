-- Synthetic source selection -> native confirmation -> cloud list deletion.
-- Real widgets/workers/SQLite/loopback HTTP; no public network or account data.
return function(reader,plugin,pump,shot,clean_popups,open,row,tap,request,same)
    local Selection=require('weread.ui.selection_thought');local Service=require('weread.lib.mark_edit_service')
    local Journal=Service.new_journal(plugin.library_db,plugin.client);local Json=require('json');local UI=require('ui/uimanager')
    local Text=assert(loadfile('/source/spec/koreader/thought_text_smoke.lua'))()
    local before=request('/__state');local original=before.selection_marks;local thoughts=before.selection_thoughts
    local origin=reader.document:getXPointer();local annotations=Json.decode(Json.encode(reader.annotation.annotations))
    local function bytes() local f=assert(io.open(reader.document.file,'rb'));local b=f:read('*a');f:close();return b end
    local original_file=bytes()
    local online=plugin.isNetworkOnline;local owner
    local transport=plugin.client.request;local parent=tonumber(require('ffi').C.getpid())
    function plugin.client:request(options)
        local op=({['https://i.weread.qq.com/book/addBookmark']='create',['https://i.weread.qq.com/book/removeBookmark']='delete'})[options.url]
        if op then
            assert(tonumber(require('ffi').C.getpid())~=parent,'highlight write blocked native UI')
            local intent=assert(Journal:read());local body=Json.decode(options.body)
            assert(intent.phase=='pending' and intent.metadata.operation==op and intent.metadata.request_hash==require('weread.lib.mark_edit_contract').body_hash(body))
            assert(options.sensitive and options.skip_cookie and options.persist_response_cookies==false and not options.headers.Cookie)
        end
        return transport(self,options)
    end
    local function wait_preview()
        pump(function() return not owner.mark_editor or owner.mark_editor.service.preview end)
        assert(owner.mark_editor and owner.mark_editor.service.preview,'highlight preview failed')
    end
    local function notice()
        pump(function() return not owner.mark_editor end)
        local top=UI:getTopmostVisibleWidget();if top~=owner.menu then UI:close(top) end
    end
    plugin.isNetworkOnline=function() return false end
    owner=open(true);row(owner,'Save highlight');assert(not owner.mark_editor and request('/__state').highlight_posts==0)
    Selection.cancel(plugin);clean_popups(reader);plugin.isNetworkOnline=online
    owner=open(true);row(owner,'Save highlight');wait_preview()
    assert(Text.emoji(owner.mark_editor.dialog.box_widget,{['😀']=true,['🙂']=true})>=2)
    shot('highlight-native-confirmation');tap(owner,'confirm_highlight_change');notice()
    local state=request('/__state');local created,created_row
    for key,value in pairs(state.selection_marks) do if not original[key] then
        assert(not created and value.markText==owner.reference.markText and value.range==owner.reference.range);created=key;created_row=value
    end end
    assert(created and state.highlight_posts==1 and Journal:read().phase=='idle')
    Selection.cancel(plugin);clean_popups(reader)
    local display=require('weread.ui.personal_marks')
    pump(function() return plugin._personal_marks and plugin._personal_marks.complete end)
    local shown=false
    for _i,item in ipairs(plugin._personal_marks.records) do if item.bookmarkId==created then shown=true end end
    assert(shown,'confirmed cloud mark not projected into reader')
    UI:forceRePaint();assert(#plugin._personal_marks.overlay.visible>0,'personal underline has no native screen boxes')
    shot('personal-highlight-saved')
    plugin:toggleAnnotationVisibility();UI:forceRePaint();assert(not plugin._personal_marks.overlay.enabled and #plugin._personal_marks.overlay.visible==0)
    plugin:toggleAnnotationVisibility();pump(function() return plugin._personal_marks.complete end);UI:forceRePaint()
    assert(plugin._personal_marks.overlay.enabled and #plugin._personal_marks.overlay.visible>0)
    local font_size=reader.font.configurable.font_size
    reader.font:onSetFontSize(font_size+2);clean_popups(reader);UI:forceRePaint()
    assert(#plugin._personal_marks.overlay.visible>0,'font reflow lost personal underline')
    reader.font:onSetFontSize(font_size);clean_popups(reader);reader.rolling:onGotoXPointer(origin);UI:forceRePaint()
    local own_box=plugin._personal_marks.overlay.visible[1].rect
    assert(plugin:_onXPointerOverlayTap{pos={x=own_box.x+own_box.w/2,y=own_box.y+own_box.h/2}},'personal underline tap was not routed')
    owner=assert(plugin._my_marks_owner);assert(owner.menu._shelf_popup,'personal underline did not open its own quote')
    require('weread.ui.shelf_popup').close(owner.menu)
    local function select(id)
        for _i,item in ipairs(owner.menu.item_table) do if item.my_note_id==id then item.callback();return end end
        error('missing native highlight row')
    end
    if not plugin._my_marks_owner then plugin:showMyCloudMarks(plugin:detectWeReadBook()) end;owner=assert(plugin._my_marks_owner)
    pump(function() return owner.value~=nil end)
    -- Deleting a mark linked to an original thought is blocked before POST.
    select('synthetic-existing-highlight');tap(owner,'delete_highlight');notice()
    assert(request('/__state').highlight_posts==1 and Journal:read().phase=='idle')
    select(created);tap(owner,'delete_highlight');wait_preview();shot('highlight-native-delete')
    request('/__control',{selection_thought_mode='empty'});tap(owner,'confirm_highlight_change');notice()
    state=request('/__state');assert(state.highlight_posts==2 and same(state.selection_marks,original) and Journal:read().phase=='idle')
    plugin:cancelMyCloudMarks();clean_popups(reader);request('/__control',{selection_thought_mode='plain'})
    pump(function() return plugin._personal_marks and plugin._personal_marks.complete end);UI:forceRePaint()
    for _i,item in ipairs(plugin._personal_marks.records) do assert(item.bookmarkId~=created,'deleted cloud mark remains in personal layer') end
    assert(#plugin._personal_marks.overlay.visible==0);shot('personal-highlight-deleted')
    owner=open(true);row(owner,'Save highlight');wait_preview()
    request('/__control',{selection_source_revision=2});tap(owner,'confirm_highlight_change');notice()
    assert(request('/__state').highlight_posts==2 and Journal:read().phase=='idle','changed source sent a highlight')
    request('/__control',{selection_source_revision=1});Selection.cancel(plugin);clean_popups(reader)
    owner=open(true);row(owner,'Save highlight');wait_preview()
    local service=owner.mark_editor.service;local preview=service.preview
    Selection.cancel(plugin);clean_popups(reader)
    assert(not service:commit(preview,function() error('stale commit escaped') end) and request('/__state').highlight_posts==2)
    owner=open(true);row(owner,'Save highlight');wait_preview()
    request('/__control',{selection_thought_mode='no_change'});tap(owner,'confirm_highlight_change');notice()
    assert(request('/__state').highlight_posts==3 and Journal:read().phase=='pending')
    row(owner,'Save highlight');assert(not owner.mark_editor and request('/__state').highlight_posts==3,'unknown result resent')
    notice();row(owner,'Check last highlight change');wait_preview()
    assert(not owner.mark_editor.service.preview.confirmed);tap(owner,'resolve_highlight_change');notice()
    assert(request('/__state').highlight_posts==3 and Journal:read().phase=='idle','GET recovery dispatched')
    -- Leave one unknown operation for an entirely fresh offline process.
    row(owner,'Save highlight');wait_preview();tap(owner,'confirm_highlight_change');notice()
    assert(request('/__state').highlight_posts==4 and Journal:read().phase=='pending')
    Selection.cancel(plugin);clean_popups(reader);request('/__control',{selection_thought_mode='plain'})
    state=request('/__state');assert(same(state.selection_marks,original) and same(state.selection_thoughts,thoughts))
    assert(reader.document:getXPointer()==origin and same(reader.annotation.annotations,annotations))
    assert(bytes()==original_file,'cloud display rewrote the downloaded document')
    pump(function() return plugin._personal_marks and plugin._personal_marks.complete end)
    assert(display.available(plugin)==false,'unsupported synthetic saved mark was displayed')
    -- Seed only the isolated local cache for a fresh offline display test.
    -- This record is never sent to the mock cloud or a real account.
    local cache=require('weread.lib.my_cloud_marks_store'):new(plugin.library_db,plugin.client)
    local cached=assert(cache:read(plugin:detectWeReadBook()))
    created_row.bookmarkId='synthetic-display-offline';cached.updated[#cached.updated+1]=created_row
    assert(cache:write(cached));display.changed(plugin,cached)
    pump(function() return plugin._personal_marks and plugin._personal_marks.complete end)
    assert(#plugin._personal_marks.records==1,'offline cache fixture did not project')
    plugin.client.request=transport
    local file=assert(io.open(os.getenv('WEREAD_EVIDENCE')..'/highlight-edit-result.json','wb'))
    file:write(Json.encode{result='PASS',synthetic_only=true,native_selection=true,native_list_delete=true,
        background_workers=true,durable_intent_before_post=true,offline_no_write=true,source_change_refuses_post=true,
        linked_thought_delete_refused=true,lost_receipt_independent_readback=true,pending_no_resend=true,
        readonly_recovery=true,cancel_refuses_commit=true,original_records_restored=true,reader_position_and_notes_preserved=true,
        personal_overlay_saved_and_deleted=true,personal_overlay_toggle_and_tap=true,downloaded_file_unchanged=true,
        personal_overlay_font_reflow=true,synthetic_offline_cache_seeded=true,
        mock_data_posts=4,real_account_data_posts=0});file:close()
end
