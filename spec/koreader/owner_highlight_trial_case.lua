-- Native selection/save and list/delete, with an independent host read after
-- each write. Inherited reader/credential setup never writes login to disk.
return function(input,mode,counters)
    local path=assert(debug.getinfo(1,'S').source:match('^@(.*/)'))
    local case=dofile(path..'owner_selection_preview_case.lua')(input,mode,counters)
    local Json,UI,ffi=require('json'),require('ui/uimanager'),require('ffi')
    local parent=tonumber(ffi.C.getpid());local cfg,trial=input.selection_preview,input.selection_trial
    local mark=assert(input.highlight_trial);local grant=cfg.credentials;local base='https://i.weread.qq.com'
    case.report={permit_writes=trial.armed,source_reference=false,native_controls=false,exact_creation_body=false,cache_verified=false,
        local_pending_kept=false,dispatch_blocked=false,heartbeat=false,steps=0,native_gets=0,native_posts=0,blocked_posts=0,native_denied=0,failed_line=0,phase='init'}
    if mark.styles then case.report.style_controls=false;case.report.style_displays=0 end
    local function same(a,b)
        if type(a)~=type(b) then return false end
        if type(a)~='table' then return a==b end
        for k,v in pairs(a) do if not same(v,b[k]) then return false end end
        for k in pairs(b) do if a[k]==nil then return false end end;return true
    end
    local reads={[base..'/review/list?bookId='..input.book_id..'&listType=11&listMode=0&mine=1&synckey=0&count=20']=true,
        [base..'/book/bookmarklist?bookId='..input.book_id..'&synckey=0']=true,[base..'/book/info?bookId='..input.book_id]=true}
    local writes={[base..'/book/addBookmark']='create',[base..'/book/removeBookmark']='delete'}
    if mark.styles then writes[base..'/book/updateBookmark']='style' end
    function case:request(client,options,dispatch)
        local h=options.headers or {}
        local common=self.enabled and tonumber(ffi.C.getpid())~=parent and options.skip_cookie==true
            and options.persist_response_cookies==false and options.sensitive==true and h.vid==input.vid and h.accessToken==grant.accessToken
            and not h.Cookie and not h.cookie and not h.Authorization and not h.authorization
        if common and options.method=='GET' and not options.body and reads[options.url] and counters[32]<40 then
            counters[32]=counters[32]+1;return dispatch(client,options)
        end
        local operation=writes[options.url]
        if common and options.method=='POST' and operation and type(options.body)=='string' and self.gate then
            if not self.gate:claim(operation,client:json_decode(options.body)) then
                counters[36]=counters[36]+1;error('native_highlight/dry_run',0)
            end
            counters[33]=counters[33]+1;assert(counters[33]<=(mark.styles and 4 or 2));return dispatch(client,options)
        end
        counters[34]=counters[34]+1;error('native_highlight/native_scope',0)
    end
    local function acknowledge(sequence,target,preview)
        local value=preview and {seq=0,preview=preview} or {seq=sequence,created_id=target}
        local raw=Json.encode(value);assert(#raw<=16384)
        io.write('\nWEREAD_NATIVE_THOUGHT_'..trial.rpc_token..'_STEP='..raw..'\n');io.flush()
        local line=assert(io.stdin:read('*l'));assert(#line<=16384);local reply=Json.decode(line)
        assert(reply.seq==sequence and reply.ok==true and (sequence==0 or reply.created_id==target))
    end
    function case:run(plugin,reader,pump,index,origin)
        self.enabled=true
        local Selection=require('weread.ui.selection_thought');local tr=require('weread.lib.plugin_util').tr
        local Service=require('weread.lib.mark_edit_service');local journal=Service.new_journal(plugin.library_db,plugin.client)
        self.gate=dofile(path..'native_highlight_trial_gate.lua'):new({permit_writes=trial.armed,book_id=input.book_id,
            original_ids=mark.original_ids,create_body=mark.create_body,styles=mark.styles},plugin.library_db,plugin.client,assert(os.getenv('KO_HOME')))
        local document=reader.document;local notes=plugin.client:json_encode(reader.annotation.annotations)
        local first,last=assert(index:locate(cfg.first)),assert(index:locate(cfg.last))
        assert(assert(index:capture(first.xpointer)).co==cfg.first and assert(index:capture(last.xpointer)).co==cfg.last)
        local text=assert(document:getTextFromXPointers(first.xpointer,last.xpointer));document:clearSelection()
        assert(require('weread.lib.source_dom').normalize(text)==require('weread.lib.source_dom').normalize(cfg.reference.markText))
        reader.rolling:onGotoXPointer(first.xpointer);UI:setInputTimeout(0);UI:handleInput();UI:forceRePaint()
        reader.highlight.selected_text={pos0=first.xpointer,pos1=last.xpointer,text=text};reader.highlight:onShowHighlightMenu();UI:forceRePaint()
        assert(reader.highlight.highlight_dialog.buttontable:getButtonById('weread_selection_thought')):onTapSelectButton()
        local owner
        pump(function() owner=plugin._selection_thought_owner or owner;return owner and (owner.reference or owner.error) end)
        assert(owner.reference and same(owner.reference,cfg.reference));self.report.source_reference=true
        local function row(label)
            for _i,item in ipairs(owner.menu.item_table) do if item.text==tr(label) then item.callback();return end end
            error('native_highlight/missing_row',0)
        end
        local function tap(key)
            UI:forceRePaint();assert(owner.menu._shelf_popup.button_table:getButtonById(key)):onTapSelectButton()
        end
        local function submit()
            pump(function() return not owner.mark_editor or owner.mark_editor.service.preview end);assert(owner.mark_editor)
            assert(owner.mark_editor.dialog.text:find(mark.create_body.markText,1,true));self.report.exact_creation_body=true
            local beat=false;UI:scheduleIn(.1,function() beat=true end);tap('confirm_highlight_change')
            pump(function() return beat and not owner.mark_editor end);self.report.heartbeat=true
            local top=UI:getTopmostVisibleWidget();if top~=owner.menu then UI:close(top) end
        end
        self.report.phase='create';row('Save highlight');submit();self.report.native_controls=true
        if not trial.armed then
            local state=self.gate:read();assert(state.phase=='blocked' and state.posts==0 and same(state.preview,mark.create_body) and journal:read().phase=='pending')
            self.report.dispatch_blocked,self.report.local_pending_kept=true,true;acknowledge(0,nil,state.preview)
            local gets=tonumber(counters[32]);row('Save highlight');assert(not owner.mark_editor and counters[32]==gets and counters[36]==1)
        else
            local cache=Service.new_cache(plugin.library_db,plugin.client)
            assert(self.gate:read().phase=='create_pending' and journal:read().phase=='idle')
            local original={};for _i,id in ipairs(mark.original_ids) do original[id]=true end
            local target
            for _i,item in ipairs(assert(cache:read(input.book_id)).updated) do
                if not original[item.bookmarkId] then assert(not target);target=item.bookmarkId end
            end
            assert(target);acknowledge(1,target);self.report.steps=1;self.gate:advance(target)
            Selection.cancel(plugin)
            if mark.styles then
                local function display(style)
                    pump(function() return plugin._personal_marks and plugin._personal_marks.complete end)
                    UI:forceRePaint();local shown
                    for _i,record in ipairs(plugin._personal_marks.records) do if record.bookmarkId==target then shown=record end end
                    assert(shown and shown.style==style and #plugin._personal_marks.overlay.visible>0)
                    assert(require('weread.lib.source_dom').normalize(document:getTextFromXPointers(shown.pos0,shown.pos1))
                        ==require('weread.lib.source_dom').normalize(mark.create_body.markText));document:clearSelection()
                    self.report.style_displays=self.report.style_displays+1
                end
                display(1)
                for _i,style in ipairs({0,2}) do
                    self.report.phase='style'..style;assert(plugin:showMyCloudMarks(input.book_id));owner=assert(plugin._my_marks_owner)
                    local selected;for _j,item in ipairs(owner.menu.item_table) do if item.my_note_id==target then selected=item end end
                    assert(selected);selected.callback();tap('change_highlight_style')
                    UI:forceRePaint();owner.menu._shelf_popup.buttontable:getButtonById('highlight_style_'..style):onTapSelectButton();submit()
                    assert(self.gate:read().phase=='style'..style..'_pending' and journal:read().phase=='idle')
                    acknowledge(_i+1,target);self.report.steps=_i+1;self.gate:advance_style(target,style)
                    plugin:cancelMyCloudMarks();display(style)
                end
                self.report.style_controls=true
            end
            self.report.phase='delete';plugin:showMyCloudMarks(input.book_id);owner=assert(plugin._my_marks_owner)
            local selected
            for _i,item in ipairs(owner.menu.item_table) do if item.my_note_id==target then selected=item end end
            assert(selected);selected.callback();tap('delete_highlight');submit()
            local last_step=mark.styles and 4 or 2
            assert(self.gate:read().phase=='delete_pending' and journal:read().phase=='idle');acknowledge(last_step,target);self.report.steps=last_step
            local ids={};for _i,item in ipairs(assert(cache:read(input.book_id)).updated) do ids[item.bookmarkId]=true;assert(item.bookmarkId~=target) end
            local count=0;for _id in pairs(ids) do count=count+1 end;assert(count==#mark.original_ids)
            for _i,id in ipairs(mark.original_ids) do assert(ids[id]) end
            self.report.cache_verified=true;plugin:cancelMyCloudMarks()
        end
        Selection.cancel(plugin);plugin:closeWeReadUI()
        local restored;assert(plugin:openSourcePosition(origin,function(value) restored=value or false end));pump(function() return restored~=nil end)
        assert(restored and restored.chapter_offset==origin.chapter_offset and plugin.client:json_encode(reader.annotation.annotations)==notes)
        self.report.phase='complete';self.enabled=false
    end
    function case:finish(reason)
        self.report.native_gets,self.report.native_posts,self.report.native_denied=tonumber(counters[32]),tonumber(counters[33]),tonumber(counters[34])
        self.report.blocked_posts=tonumber(counters[36])
        self.report.failed_line=tonumber(type(reason)=='string' and reason:match('owner_highlight_trial_case%.lua:(%d+):')) or 0
    end
    return case
end
