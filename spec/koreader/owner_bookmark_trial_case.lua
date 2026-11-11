-- Current viewport -> production bookmark controls -> independent host reads.
-- The outer supervisor confines private files to tmpfs and audits credentials.
return function(input,mode,counters)
    local path=assert(debug.getinfo(1,'S').source:match('^@(.*/)'))
    local case=dofile(path..'owner_selection_preview_case.lua')(input,mode,counters)
    local Json,UI,ffi=require('json'),require('ui/uimanager'),require('ffi')
    local parent=tonumber(ffi.C.getpid());local cfg,trial=input.bookmark_trial,input.selection_trial
    local grant=input.selection_preview.credentials;local base='https://i.weread.qq.com'
    case.report={permit_writes=trial.armed,source_reference=false,native_controls=false,exact_creation_body=false,cache_verified=false,
        local_pending_kept=false,dispatch_blocked=false,heartbeat=false,steps=0,native_gets=0,native_posts=0,blocked_posts=0,native_denied=0,failed_line=0,phase='init',
        viewport_bound=false,bookmark_navigation=false,view_mode_restored=false}
    -- Failure-only diagnostics contain fixed enums/booleans, never a book row,
    -- response, database exception or credential. Success receipts stay fixed.
    local Source=require('weread.lib.shelf_source');local fetch=Source.fetch
    function Source.fetch(...)
        counters[40]=counters[40]+1
        local ok,a,b,c=pcall(fetch,...)
        if not ok then
            counters[41]=({['shelf_source/web_unavailable']=1,['shelf_source/session_changed']=2,
                ['shelf_source/native_unavailable']=3,['shelf_source/native_required']=4})[a] or 5
            error(a,0)
        end
        counters[45]=a._shelf_source=='web' and 1 or a._shelf_source=='native' and 2 or 3
        return a,b,c
    end
    local Library=require('weread.lib.library_db');local cache_shelf=Library.cacheShelf
    function Library:cacheShelf(books,...)
        counters[42]=counters[42]+1;counters[43]=require('weread.lib.shelf_snapshot').metadata(books,os.time()) and 1 or 0
        local saved=cache_shelf(self,books,...);counters[44]=saved and 1 or 0;return saved
    end
    local Worker=require('weread.lib.memory_worker');local start_worker=Worker.start
    function Worker:start(task,callback)
        return start_worker(self,task,function(value)
            if not case.enabled then
                counters[46]=type(value)=='table' and (value.ok==true and 1 or value.ok==false and 2 or 3) or 4
            end
            return callback(value)
        end)
    end
    local function same(a,b)
        if type(a)~=type(b) then return false end
        if type(a)~='table' then return a==b end
        for k,v in pairs(a) do if not same(v,b[k]) then return false end end
        for k in pairs(b) do if a[k]==nil then return false end end;return true
    end
    local reads={[base..'/review/list?bookId='..input.book_id..'&listType=11&listMode=0&mine=1&synckey=0&count=20']=true,
        [base..'/book/bookmarklist?bookId='..input.book_id..'&synckey=0']=true,[base..'/book/info?bookId='..input.book_id]=true}
    local writes={[base..'/book/addBookmark']='bookmark_create',[base..'/book/removeBookmark']='bookmark_delete'}
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
                counters[36]=counters[36]+1;error('native_bookmark/dry_run',0)
            end
            counters[33]=counters[33]+1;assert(counters[33]<=2);return dispatch(client,options)
        end
        counters[34]=counters[34]+1;error('native_bookmark/native_scope',0)
    end
    local function acknowledge(sequence,target,preview)
        local value=preview and {seq=0,preview=preview} or {seq=sequence,created_id=target}
        local raw=Json.encode(value);assert(#raw<=16384)
        io.write('\nWEREAD_NATIVE_THOUGHT_'..trial.rpc_token..'_STEP='..raw..'\n');io.flush()
        local line=assert(io.stdin:read('*l'));assert(#line<=16384);local response=Json.decode(line)
        assert(response.seq==sequence and response.ok==true and (sequence==0 or response.created_id==target))
    end
    function case:run(plugin,reader,pump,index,origin)
        self.enabled=true
        local Selection=require('weread.ui.selection_thought');local tr=require('weread.lib.plugin_util').tr
        local Service=require('weread.lib.mark_edit_service');local journal=Service.new_journal(plugin.library_db,plugin.client)
        self.gate=dofile(path..'native_highlight_trial_gate.lua'):new({bookmarks=true,permit_writes=trial.armed,book_id=input.book_id,
            original_ids=cfg.original_ids,create_body=cfg.create_body},plugin.library_db,plugin.client,assert(os.getenv('KO_HOME')))
        local document=reader.document;local notes=plugin.client:json_encode(reader.annotation.annotations)
        local original_mode=reader.view.view_mode
        local first=assert(index:locate(cfg.first));assert(assert(index:capture(first.xpointer)).co==cfg.first)
        reader:handleEvent(require('ui/event'):new('SetViewMode','scroll'))
        reader.rolling:onGotoXPointer(first.xpointer);document:clearSelection();UI:setInputTimeout(0);UI:handleInput();UI:forceRePaint()
        local function viewport()
            local location=assert(require('weread.lib.source_context').location(document,reader.view.view_mode));local xp=location.xpointer
            if not xp:find('/text()',1,true) then xp=assert(document:getNextVisibleChar(xp));assert(document:isXPointerInCurrentPage(xp)) end
            return assert(index:capture(xp)).co
        end
        assert(reader.view.view_mode=='scroll' and viewport()==cfg.first,'native_bookmark/viewport')
        self.report.viewport_bound=true
        local invoked=false
        for _i,item in ipairs(plugin:getMainMenuItems()) do
            if item.text==tr('Save cloud bookmark') then item.callback();invoked=true;break end
        end
        assert(invoked)
        local owner
        pump(function() owner=plugin._selection_thought_owner or owner;return owner and (owner.reference or owner.error) end)
        assert(owner.reference and same(owner.reference,cfg.reference),'native_bookmark/source_reference');self.report.source_reference=true
        local function row(label)
            for _i,item in ipairs(owner.menu.item_table) do if item.text==tr(label) then item.callback();return end end
            error('native_bookmark/missing_row',0)
        end
        local function tap(key)
            UI:forceRePaint();assert(owner.menu._shelf_popup.button_table:getButtonById(key)):onTapSelectButton()
        end
        local function submit()
            pump(function() return not owner.mark_editor or owner.mark_editor.service.preview end);assert(owner.mark_editor)
            if self.report.phase=='create' then
                assert(owner.mark_editor.dialog.text:find(cfg.create_body.markText,1,true));self.report.exact_creation_body=true
            end
            local beat=false;UI:scheduleIn(.1,function() beat=true end);tap('confirm_highlight_change')
            pump(function() return beat and not owner.mark_editor end);self.report.heartbeat=true
            local top=UI:getTopmostVisibleWidget();if top~=owner.menu then UI:close(top) end
        end
        self.report.phase='create';row('Save cloud bookmark');submit();self.report.native_controls=true
        if not trial.armed then
            local state=self.gate:read();assert(state.phase=='blocked' and state.posts==0 and same(state.preview,cfg.create_body) and journal:read().phase=='pending')
            self.report.dispatch_blocked,self.report.local_pending_kept=true,true;acknowledge(0,nil,state.preview)
            local gets=tonumber(counters[32]);row('Save cloud bookmark');assert(not owner.mark_editor and counters[32]==gets and counters[36]==1)
        else
            local cache=Service.new_cache(plugin.library_db,plugin.client)
            assert(self.gate:read().phase=='create_pending' and journal:read().phase=='idle')
            local originals={};for _i,id in ipairs(cfg.original_ids) do originals[id]=true end
            local target
            for _i,item in ipairs(assert(cache:read(input.book_id)).updated) do
                if not originals[item.bookmarkId] then assert(not target and item.type==0 and item.range==cfg.create_body.range);target=item.bookmarkId end
            end
            assert(target);acknowledge(1,target);self.report.steps=1;self.gate:advance(target);Selection.cancel(plugin)
            local function select()
                for _i,item in ipairs(owner.menu.item_table) do if item.my_note_id==target then item.callback();return end end
                error('native_bookmark/missing_target',0)
            end
            assert(plugin:showMyCloudBookmarks(input.book_id));owner=assert(plugin._my_marks_owner);select();tap('open_bookmark')
            pump(function() return not plugin._my_marks_owner and not plugin._read_resume_active and not owner.navigation end)
            assert(viewport()==cfg.first,'native_bookmark/reverse');self.report.bookmark_navigation=true
            self.report.phase='delete';assert(plugin:showMyCloudBookmarks(input.book_id));owner=assert(plugin._my_marks_owner)
            select();tap('delete_bookmark');submit()
            assert(self.gate:read().phase=='delete_pending' and journal:read().phase=='idle');acknowledge(2,target);self.report.steps=2
            local ids={};for _i,item in ipairs(assert(cache:read(input.book_id)).updated) do ids[item.bookmarkId]=true;assert(item.bookmarkId~=target) end
            local count=0;for _id in pairs(ids) do count=count+1 end;assert(count==#cfg.original_ids)
            for _i,id in ipairs(cfg.original_ids) do assert(ids[id]) end
            self.report.cache_verified=true;plugin:cancelMyCloudMarks()
        end
        Selection.cancel(plugin);plugin:closeWeReadUI()
        reader:handleEvent(require('ui/event'):new('SetViewMode',original_mode))
        local restored;assert(plugin:openSourcePosition(origin,function(value) restored=value or false end));pump(function() return restored~=nil end)
        assert(restored and restored.chapter_offset==origin.chapter_offset and plugin.client:json_encode(reader.annotation.annotations)==notes)
        assert(reader.view.view_mode==original_mode);self.report.view_mode_restored=true
        self.report.phase='complete';self.enabled=false
    end
    function case:finish(reason)
        self.report.native_gets,self.report.native_posts,self.report.native_denied=tonumber(counters[32]),tonumber(counters[33]),tonumber(counters[34])
        self.report.blocked_posts=tonumber(counters[36])
        self.report.failed_line=tonumber(type(reason)=='string' and reason:match('owner_bookmark_trial_case%.lua:(%d+):')) or 0
        if self.report.phase=='init' then
            self.report.shelf_check={fetches=tonumber(counters[40]),fetch_error=tonumber(counters[41]),cache_calls=tonumber(counters[42]),
                metadata_valid=counters[43]==1,cached=counters[44]==1,source=tonumber(counters[45]),worker_result=tonumber(counters[46])}
        end
    end
    return case
end
