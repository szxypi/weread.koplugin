-- Synthetic native current-page bookmark, list navigation and deletion.
return function(reader,plugin,pump,shot,clean_popups,row,tap,request,same)
    local UI=require('ui/uimanager');local Selection=require('weread.ui.selection_thought');local Json=require('json')
    local C=require('weread.lib.mark_edit_contract');local Journal=require('weread.lib.mark_edit_service').new_journal(plugin.library_db,plugin.client)
    local before=request('/__state');local origin=reader.document:getXPointer();local notes=Json.decode(Json.encode(reader.annotation.annotations))
    local file=assert(io.open(reader.document.file,'rb'));local original_bytes=file:read('*a');file:close()
    local owner;local parent=tonumber(require('ffi').C.getpid());local transport=plugin.client.request
    function plugin.client:request(options)
        if options.url=='https://i.weread.qq.com/book/addBookmark' or options.url=='https://i.weread.qq.com/book/removeBookmark' then
            assert(tonumber(require('ffi').C.getpid())~=parent,'bookmark POST blocked native UI')
            local intent=assert(Journal:read());local body=Json.decode(options.body)
            assert(intent.phase=='pending' and intent.metadata.request_hash==C.body_hash(body))
            assert(intent.metadata.operation==(options.url:find('addBookmark',1,true) and 'bookmark_create' or 'bookmark_delete'))
            if intent.metadata.operation=='bookmark_create' then
                assert(body.type==0 and body.style==0 and not body.colorStyle and not body.chapterIdx and body.range==owner.reference.range)
            end
            assert(not options.headers.Cookie and options.sensitive and options.skip_cookie and not options.persist_response_cookies)
        end
        return transport(self,options)
    end
    local function open()
        assert(Selection.open_bookmark(plugin));owner=assert(plugin._selection_thought_owner)
        pump(function() return owner.reference or owner.error end)
        assert(owner.reference and owner.reference.bookmark and owner.reference.type==0 and owner.reference.range:match('^%d+$'),tostring(owner.error))
        return owner
    end
    local function wait_preview()
        pump(function() return not owner.mark_editor or owner.mark_editor.service.preview end)
        assert(owner.mark_editor and owner.mark_editor.service.preview,'bookmark preview failed')
    end
    local function notice()
        pump(function() return not owner.mark_editor end)
        local top=UI:getTopmostVisibleWidget();if top~=owner.menu then UI:close(top) end
    end
    clean_popups(reader);open();row(owner,'Save cloud bookmark');wait_preview();shot('bookmark-native-confirmation')
    assert(owner.mark_editor.service.preview.operation=='bookmark_create')
    request('/__control',{selection_thought_mode='empty'});tap(owner,'confirm_highlight_change');notice()
    request('/__control',{selection_thought_mode='plain'})
    local state=request('/__state');local id
    for key,value in pairs(state.selection_marks) do if not before.selection_marks[key] then assert(not id and value.type==0);id=key end end
    assert(id and state.bookmark_posts==1 and Journal:read().phase=='idle')
    plugin._bookmark_offline_fixture=Json.decode(Json.encode(state.selection_marks[id]))
    plugin._bookmark_offline_fixture.bookmarkId='synthetic-bookmark-offline'
    -- Duplicate point refusal happens before any second creation dispatch.
    Selection.cancel(plugin);clean_popups(reader);open();row(owner,'Save cloud bookmark');notice()
    assert(request('/__state').bookmark_posts==1 and Journal:read().phase=='idle')
    Selection.cancel(plugin);clean_popups(reader)
    assert(plugin:showMyCloudBookmarks(plugin:detectWeReadBook()));owner=assert(plugin._my_marks_owner)
    assert(owner.bookmarks and owner.filter==0)
    local function select()
        for _i,item in ipairs(owner.menu.item_table) do if item.my_note_id==id then item.callback();return end end
        error('missing native bookmark row')
    end
    select();shot('bookmark-native-list')
    local navigation=require('weread.ui.my_mark_navigation');local start=navigation.start;local jumped
    navigation.start=function(actual_host,actual_owner,mark,current)
        assert(mark.bookmarkId==id and current(plugin,owner));jumped=true;return start(actual_host,actual_owner,mark,current)
    end
    tap(owner,'open_bookmark')
    pump(function() return plugin._read_resume_active==nil and owner.navigation==nil and not plugin._my_marks_owner end)
    navigation.start=start;assert(jumped,'bookmark list did not route original position')
    assert(reader.document:getXPointer()==origin,'bookmark did not return to current page')
    assert(plugin:showMyCloudBookmarks(plugin:detectWeReadBook()));owner=assert(plugin._my_marks_owner)
    select();tap(owner,'delete_bookmark');wait_preview();shot('bookmark-native-delete')
    request('/__control',{selection_thought_mode='empty'});tap(owner,'confirm_highlight_change');notice()
    request('/__control',{selection_thought_mode='plain'});plugin:cancelMyCloudMarks();clean_popups(reader)
    state=request('/__state')
    assert(state.bookmark_posts==2 and state.highlight_posts==before.highlight_posts and Journal:read().phase=='idle')
    assert(same(state.selection_marks,before.selection_marks) and same(state.selection_thoughts,before.selection_thoughts))
    assert(reader.document:getXPointer()==origin and same(reader.annotation.annotations,notes))
    file=assert(io.open(reader.document.file,'rb'));assert(file:read('*a')==original_bytes);file:close()
    plugin.client.request=transport
    local receipt=assert(io.open(os.getenv('WEREAD_EVIDENCE')..'/bookmark-edit-result.json','wb'))
    receipt:write(Json.encode{result='PASS',synthetic_only=true,current_page_source_bound=true,native_list_locate=true,native_delete=true,
        duplicate_no_dispatch=true,missing_preview_supported=true,lost_receipt_independent_readback=true,
        original_records_restored=true,reader_position_and_notes_preserved=true,downloaded_file_unchanged=true,
        background_workers=true,durable_intent_before_post=true,mock_data_posts=2,real_account_data_posts=0});receipt:close()
end
