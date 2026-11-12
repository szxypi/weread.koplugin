-- Only this explicit duplex mode can arm the three production native writes.
-- The host reserves four total slots first and independently checks every step.
return function(input,mode,counters)
    local path=assert(debug.getinfo(1,'S').source:match('^@(.*/)'))
    local case=dofile(path..'owner_selection_preview_case.lua')(input,mode,counters)
    local Json,UI=require('json'),require('ui/uimanager');local ffi=require('ffi')
    local parent=tonumber(ffi.C.getpid());local cfg,trial=assert(input.selection_preview),assert(input.selection_trial)
    local grant=cfg.credentials;local base='https://i.weread.qq.com'
    case.report={permit_writes=trial.armed,source_reference=false,native_controls=false,exact_creation_body=false,cache_verified=false,
        local_pending_kept=false,dispatch_blocked=false,heartbeat=false,steps=0,native_gets=0,native_posts=0,blocked_posts=0,native_denied=0,failed_line=0,phase='init'}
    local function same(a,b)
        if type(a)~=type(b) then return false end
        if type(a)~='table' then return a==b end
        for k,v in pairs(a) do if not same(v,b[k]) then return false end end
        for k in pairs(b) do if a[k]==nil then return false end end;return true
    end
    local reads={[base..'/review/list?bookId='..input.book_id..'&listType=11&listMode=0&mine=1&synckey=0&count=20']=true,
        [base..'/book/info?bookId='..input.book_id]=true}
    local writes={[base..'/review/add']='create',[base..'/review/useredit']='edit',[base..'/review/delete']='delete'}
    function case:request(client,options,dispatch)
        local h=options.headers or {}
        local common=self.enabled and tonumber(ffi.C.getpid())~=parent and options.skip_cookie==true
            and options.persist_response_cookies==false and options.sensitive==true and h.vid==input.vid and h.accessToken==grant.accessToken
            and not h.Cookie and not h.cookie and not h.Authorization and not h.authorization
        if common and options.method=='GET' and not options.body and reads[options.url] and counters[32]<32 then
            counters[32]=counters[32]+1;return dispatch(client,options)
        end
        local operation=writes[options.url]
        if common and options.method=='POST' and operation and type(options.body)=='string' and self.gate then
            if not self.gate:claim(operation,client:json_decode(options.body)) then
                counters[36]=counters[36]+1;error('selection_trial/dry_run',0)
            end
            counters[33]=counters[33]+1;assert(counters[33]<=3);return dispatch(client,options)
        end
        counters[34]=counters[34]+1;error('selection_trial/native_scope',0)
    end
    local function emit(value)
        local raw=Json.encode(value);assert(#raw<=16384)
        io.write('\nWEREAD_NATIVE_THOUGHT_'..trial.rpc_token..'_STEP='..raw..'\n');io.flush()
    end
    local function acknowledged(sequence,target,preview)
        emit(preview and {seq=0,preview=preview} or {seq=sequence,created_id=target})
        local raw=assert(io.stdin:read('*l'));assert(#raw<=16384);local reply=Json.decode(raw)
        assert(reply.seq==sequence and reply.ok==true and (sequence==0 or reply.created_id==target))
    end
    function case:run(plugin,reader,pump,index,origin)
        self.enabled=true
        local Selection=require('weread.ui.selection_thought');local tr=require('weread.lib.plugin_util').tr
        local journal=require('weread.lib.thought_edit_store'):new(plugin.library_db,plugin.client)
        self.gate=dofile(path..'native_thought_trial_gate.lua'):new({permit_writes=trial.armed,book_id=input.book_id,
            original_ids=trial.original_ids,create_body=cfg.body,edited_text=trial.edited_text},plugin.library_db,plugin.client,assert(os.getenv('KO_HOME')))
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
            error('selection_trial/missing_row',0)
        end
        local function tap(key)
            UI:forceRePaint();assert(owner.menu._shelf_popup.button_table:getButtonById(key)):onTapSelectButton()
        end
        local function operation(kind,content)
            if kind~='delete' then owner.editor.input:setInputText(content);tap('submit_thought') end
            pump(function() return not owner.editor or owner.editor.service.preview end);assert(owner.editor)
            if kind=='create' then
                assert(owner.editor.dialog.text:find(cfg.body.abstract,1,true) and owner.editor.dialog.text:find(cfg.body.content,1,true))
                self.report.exact_creation_body=true
            end
            local beat=false;UI:scheduleIn(.1,function() beat=true end);tap('confirm_thought_change')
            pump(function() return beat and not owner.editor end);self.report.heartbeat=true
            local top=UI:getTopmostVisibleWidget();if top~=owner.menu then UI:close(top) end
        end
        self.report.phase='create';row('Write private thought');operation('create',cfg.body.content)
        self.report.native_controls=true
        if not trial.armed then
            local state=self.gate:read();assert(state.phase=='blocked' and state.posts==0 and same(state.preview,cfg.body) and journal:read().phase=='pending')
            self.report.dispatch_blocked,self.report.local_pending_kept=true,true;acknowledged(0,nil,state.preview)
        else
            local cache=require('weread.lib.my_cloud_marks_store'):new(plugin.library_db,plugin.client,'thoughts')
            assert(self.gate:read().phase=='create_pending' and journal:read().phase=='idle')
            local target
            for _i,item in ipairs(assert(cache:read(input.book_id)).reviews) do
                if item.content==cfg.body.content and item.isPrivate==1 then assert(not target);target=item.reviewId end
            end
            assert(target);acknowledged(1,target);self.report.steps=1;self.gate:advance(1,target)
            Selection.cancel(plugin)
            for sequence,kind in ipairs({'edit','delete'}) do
                self.report.phase=kind;plugin:showMyCloudThoughts(input.book_id);owner=assert(plugin._my_marks_owner)
                local selected
                for _i,item in ipairs(owner.menu.item_table) do if item.my_note_id==target then selected=item end end
                assert(selected);selected.callback();tap('thought_'..kind);operation(kind,kind=='edit' and trial.edited_text or nil)
                assert(self.gate:read().phase==kind..'_pending' and journal:read().phase=='idle')
                acknowledged(sequence+1,target);self.report.steps=sequence+1
                if sequence==1 then self.gate:advance(2,target) end
                plugin:cancelMyCloudMarks()
            end
            local ids={};for _i,item in ipairs(assert(cache:read(input.book_id)).reviews) do ids[item.reviewId]=true;assert(item.reviewId~=target) end
            local count=0;for _id in pairs(ids) do count=count+1 end;assert(count==#trial.original_ids)
            for _i,id in ipairs(trial.original_ids) do assert(ids[id]) end
            self.report.cache_verified=true
        end
        Selection.cancel(plugin);plugin:closeWeReadUI()
        local restored;assert(plugin:openSourcePosition(origin,function(value) restored=value or false end));pump(function() return restored~=nil end)
        assert(restored and restored.chapter_offset==origin.chapter_offset and plugin.client:json_encode(reader.annotation.annotations)==notes)
        self.report.phase='complete';self.enabled=false
    end
    function case:finish(reason)
        self.report.native_gets,self.report.native_posts,self.report.native_denied=tonumber(counters[32]),tonumber(counters[33]),tonumber(counters[34])
        self.report.blocked_posts=tonumber(counters[36])
        self.report.failed_line=tonumber(type(reason)=='string' and reason:match('owner_selection_trial_case%.lua:(%d+):')) or 0
    end
    return case
end
