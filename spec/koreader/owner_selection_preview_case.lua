-- Opt-in real-source selection preview. No native POST can leave this gate.
return function(input,mode,counters)
    local Json,UI=require('json'),require('ui/uimanager')
    local ffi=require('ffi');local parent=tonumber(ffi.C.getpid())
    local cfg=assert(input.selection_preview);local grant=assert(cfg.credentials)
    assert(mode=='live' or mode=='reopen');assert(grant.vid==input.vid)
    local case={enabled=false,report={selection_entry=false,source_reference=false,draft_preserved=false,pending_preserved=false,
        original_notes_preserved=false,reader_position_restored=false,anonymous_native_credentials=true,background_workers=false,
        live_preflight=false,exact_body=false,blocked_dispatch=false,repeat_submit_blocked=false,fresh_offline_restore=false,
        native_gets=0,blocked_posts=0,native_denied=0,account_data_posts=0,failed_line=0,phase='init'},
        capture={reference=Json.util.null,body=Json.util.null,native_text='',draft_text=''}}
    local function same(a,b)
        if type(a)~=type(b) then return false end
        if type(a)~='table' then return a==b end
        for k,v in pairs(a) do if not same(v,b[k]) then return false end end
        for k in pairs(b) do if a[k]==nil then return false end end;return true
    end
    local Worker=require('weread.lib.memory_worker');local start=Worker.start
    function Worker:start(...)
        local started=start(self,...)
        if tonumber(ffi.C.getpid())==parent and self.job and self.job.pid~=parent then counters[35]=counters[35]+1 end
        return started
    end
    local Store=require('weread.lib.native_credentials')
    function Store:_read()
        if not self.settings:auth_scope_matches({vid=input.vid,epoch=1}) then return nil,'unavailable' end
        if not case.enabled then return {revision=0} end
        local saved={};for k,v in pairs(grant) do saved[k]=v end
        saved.epoch,saved.verified_at,saved.book_count=1,os.time(),input.shelf_books
        return {revision=1,authorization=saved}
    end
    function Store:_write() error('selection_preview/credential_write_disabled',0) end
    local base='https://i.weread.qq.com'
    local reads={[base..'/review/list?bookId='..input.book_id..'&listType=11&listMode=0&mine=1&synckey=0&count=20']=true,
        [base..'/book/info?bookId='..input.book_id]=true}
    function case:is_native(options)
        local h=options.headers or {}
        return type(options.url)=='string' and options.url:find(base,1,true)==1 or h.vid~=nil or h.accessToken~=nil
    end
    function case:request(client,options,dispatch)
        local h=options.headers or {}
        local common=mode=='live' and self.enabled and tonumber(ffi.C.getpid())~=parent
            and options.skip_cookie==true and options.persist_response_cookies==false and options.sensitive==true
            and h.vid==input.vid and h.accessToken==grant.accessToken and not h.Cookie and not h.cookie and not h.Authorization and not h.authorization
        if common and options.method=='POST' and options.url==base..'/review/add' then
            assert(self.gate and type(options.body)=='string')
            assert(not self.gate:claim('create',client:json_decode(options.body)))
            counters[33]=counters[33]+1
            error('selection_preview/dispatch_disabled',0)
        elseif common and options.method=='GET' and not options.body and reads[options.url] and counters[32]<12 then
            counters[32]=counters[32]+1;return dispatch(client,options)
        end
        counters[34]=counters[34]+1;error('selection_preview/native_scope',0)
    end
    function case:run(plugin,reader,pump,index,origin)
        self.enabled=true
        local Selection=require('weread.ui.selection_thought')
        local tr=require('weread.lib.plugin_util').tr
        local home=assert(os.getenv('KO_HOME'));local source=assert(debug.getinfo(1,'S').source:match('^@(.*/)'))
        local journal=require('weread.lib.thought_edit_store'):new(plugin.library_db,plugin.client)
        if mode=='live' then
            self.gate=dofile(source..'native_thought_trial_gate.lua'):new({permit_writes=false,book_id=input.book_id,
                original_ids={},create_body=cfg.body},plugin.library_db,plugin.client,home)
        else assert(journal:read().phase=='pending' and #journal:drafts()==1) end
        local document=reader.document;local notes=plugin.client:json_encode(reader.annotation.annotations)
        local first=assert(index:locate(cfg.first));local last=assert(index:locate(cfg.last))
        assert(assert(index:capture(first.xpointer)).co==cfg.first and assert(index:capture(last.xpointer)).co==cfg.last)
        local text=assert(document:getTextFromXPointers(first.xpointer,last.xpointer))
        assert(require('weread.lib.source_dom').normalize(text)==require('weread.lib.source_dom').normalize(cfg.reference.markText))
        document:clearSelection();reader.rolling:onGotoXPointer(first.xpointer)
        UI:setInputTimeout(0);UI:handleInput();UI:forceRePaint()
        self.report.phase='selection'
        reader.highlight.selected_text={pos0=first.xpointer,pos1=last.xpointer,text=text}
        reader.highlight:onShowHighlightMenu();UI:forceRePaint()
        assert(reader.highlight.highlight_dialog.buttontable:getButtonById('weread_selection_thought')):onTapSelectButton()
        local owner
        pump(function() owner=plugin._selection_thought_owner or owner;return owner and (owner.reference or owner.error) end)
        assert(owner.reference and same(owner.reference,cfg.reference),'selection_preview/source_reference')
        self.report.selection_entry,self.report.source_reference=true,true
        self.capture.reference,self.capture.native_text=owner.reference,text
        assert(not reader.highlight.selected_text)
        local function row(label)
            for _i,item in ipairs(owner.menu.item_table) do if item.text==tr(label) then item.callback();return end end
            error('selection_preview/missing_row',0)
        end
        local function tap(key)
            UI:forceRePaint();assert(owner.menu._shelf_popup.button_table:getButtonById(key)):onTapSelectButton()
        end
        local function notice()
            pump(function() return not owner.editor end)
            local top=UI:getTopmostVisibleWidget();if top~=owner.menu then UI:close(top) end
        end
        if mode=='live' then
            row('Write private thought');owner.editor.input:setInputText(cfg.body.content)
            tap('save_thought_draft');notice()
        end
        self.report.phase='restore';row('Local thought drafts');owner.editor.dialog.item_table[1].callback()
        tap('resume_thought_draft');pump(function() return owner.editor and owner.editor.input end)
        assert(owner.editor.input:getInputText()==cfg.body.content and same(owner.editor.reference,cfg.reference))
        self.capture.draft_text=owner.editor.input:getInputText();self.report.draft_preserved=true
        if mode=='live' then
            self.report.phase='preview';tap('submit_thought')
            pump(function() return not owner.editor or owner.editor.service.preview end)
            assert(owner.editor and owner.editor.service.preview,'selection_preview/preflight')
            local confirmation=owner.editor.dialog
            assert(confirmation.text:find(cfg.reference.markText,1,true) and confirmation.text:find(cfg.body.content,1,true))
            self.report.live_preflight=true;self.report.phase='commit'
            local beat=false;UI:scheduleIn(.1,function() beat=true end)
            tap('confirm_thought_change');notice();pump(function() return beat end)
            local blocked=self.gate:read()
            assert(blocked.phase=='blocked' and blocked.posts==0 and same(blocked.preview,cfg.body))
            self.capture.body=blocked.preview;self.report.exact_body,self.report.blocked_dispatch=true,true
            assert(journal:read().phase=='pending')
            self.report.phase='repeat';local gets=tonumber(counters[32]);row('Write private thought')
            tap('submit_thought');notice()
            assert(counters[33]==1 and counters[32]==gets and journal:read().phase=='pending')
            self.report.repeat_submit_blocked=true
        else
            assert(journal:read().phase=='pending' and counters[32]==0 and counters[33]==0)
            self.report.fresh_offline_restore=true
        end
        self.report.background_workers=counters[35]>0
        assert(#journal:drafts()==1 and journal:read().phase=='pending')
        self.report.pending_preserved=true
        Selection.cancel(plugin);plugin:closeWeReadUI()
        local restored
        assert(plugin:openSourcePosition(origin,function(value) restored=value or false end))
        pump(function() return restored~=nil end)
        assert(restored and restored.chapter_offset==origin.chapter_offset)
        self.report.reader_position_restored=true
        assert(plugin.client:json_encode(reader.annotation.annotations)==notes)
        self.report.original_notes_preserved=true;self.report.phase='complete';self.enabled=false
    end
    function case:secrets() return {grant.accessToken,grant.refreshToken,grant.deviceId} end
    function case:finish(reason)
        self.report.native_gets,self.report.blocked_posts,self.report.native_denied=tonumber(counters[32]),tonumber(counters[33]),tonumber(counters[34])
        self.report.failed_line=tonumber(type(reason)=='string' and reason:match('owner_selection_preview_case%.lua:(%d+):')) or 0
    end
    function case:private() return self.capture end
    return case
end
