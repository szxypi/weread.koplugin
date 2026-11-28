-- Product dialogs, real snapshot SQLite/children, then real ReaderUI reopening.
return function(c)
    local UIManager=require('ui/uimanager')
    local Screen=require('device').screen
    local socket=require('socket')
    local Crypto=require('weread.lib.crypto')
    local Versions=require('weread.lib.mp_cache_versions')
    local Actions=require('weread.ui.mp_article_actions')
    local Recovery=require('weread.ui.mp_record_recovery')
    local Model=require('weread.lib.mp_record_recovery')
    local Store=require('weread.lib.mp_records_db')
    local Data=require('weread.lib.mp_record_data')
    local Doc=require('docsettings')
    local tr=require('weread.lib.i18n').tr
    local entries,cases={},{}
    local function pump(predicate)
        local deadline=socket.gettime()+20
        while not predicate() do
            assert(socket.gettime()<deadline,'native record recovery deadline')
            UIManager:setInputTimeout(0);UIManager:handleInput();socket.sleep(.01)
        end
    end
    local current,host,opened,original_open
    local function begin(location)
        c.choose('hash');current=c.open(c.sources[2].path);c.choose(location,current)
        host=assert(current.weread);original_open=host.openFile;opened=nil
        host.openFile=function(_self,path) opened=path end
        return host
    end
    local function finish()
        host.openFile=original_open;host:closeWeReadUI();c.close(current);current=nil
    end
    local function wait_choice()
        pump(function() return host._mp_records_menu~=nil or host.mp_records_job==nil end)
        assert(host._mp_records_menu and not opened,'old file opened before record selection')
        local account=assert(host.library_db:accountKey())
        local store=assert(Store.new(c.settings,account));local rows=assert(store:list(c.key))
        assert(#rows>=2,'shared records were not archived')
        return store,rows
    end
    local function choose_record(kind,notes,bookmarks)
        local menu=assert(host._mp_records_menu)
        local labels={backup=tr('Saved backup record'),primary=tr('Saved primary record'),live=tr('Record before closing'),
            beside=tr('Record beside the text'),folder=tr('Record in metadata folder')}
        for _i,row in ipairs(menu.item_table) do
            if row.text:find(labels[kind],1,true) and row.mandatory==
                require('ffi/util').template(tr('%1 notes · %2 bookmarks'),notes,bookmarks) then
                row.callback();return assert(host._mp_records_confirmation)
            end
        end
        error('native snapshot choice missing')
    end
    local function request_history(path)
        assert(Actions.history(host,c.book,c.article))
        local listed=assert(Versions.list(c.book.cache_dir,c.key))
        for index,entry in ipairs(listed) do
            if entry.path==path then host._mp_versions_menu.item_table[index].callback();return end
        end
        error('old version absent from native history')
    end
    for index,case in ipairs({{role='backup',location='doc',source=1},{role='primary',location='dir',source=2},
        {role='beside',location='doc',source=2},{role='folder',location='hash',source=2},{role='live',location='hash',source=2}}) do
        begin(case.location)
        local expected=c.sources[case.source]
        if case.role=='beside' or case.role=='folder' then
            local directory=Doc:getSidecarDir(expected.path,case.role=='beside' and 'doc' or 'dir')
            assert(require('util').makePath(directory))
            local file=assert(io.open(directory..'/'..Doc.getSidecarFilename(expected.path),'wb'))
            assert(file:write(c.originals.primary));file:close()
        end
        if case.role=='live' then
            current.rolling:onGotoPage(5);current.bookmark:onToggleBookmark()
            local selected=assert(current.document:getTextFromPositions({x=1,y=1},
                {x=Screen:getWidth()-2,y=Screen:getHeight()-2},true))
            current.annotation:addItem{page=selected.pos0,pos0=selected.pos0,pos1=selected.pos1,text=selected.text,
                note='关书前尚未保存的合成附注',drawer='lighten',datetime='2026-11-09 19:00:00'}
        end
        local prior=Versions.resolve(c.book.cache_dir,c.key)
        if index==1 then
            host:showMPArticleList(c.book,c.book.mp_articles);host._mp_article_list_view.item_table[1].callback()
        else request_history(expected.path) end
        if index==1 then
            local durable=assert(Store.new(c.settings,assert(host.library_db:accountKey())))
            assert(durable:get(c.key,Store.id('primary',c.originals.primary))==c.originals.primary
                and durable:get(c.key,Store.id('backup',c.originals.backup))==c.originals.backup,
                'shared snapshots were not durable before UI event processing')
            -- Exercise the ordinary reader flush after the preservation barrier.
            current:saveSettings()
        end
        local store,rows=wait_choice()
        if index==1 then
            assert(store:get(c.key,Store.id('primary',c.originals.primary))==c.originals.primary
                and store:get(c.key,Store.id('backup',c.originals.backup))==c.originals.backup,
                'normal reader flush damaged preserved snapshots')
            UIManager:forceRePaint();Screen:shot(c.evidence..'/mp-records-choices.png')
        end
        local notes,bookmarks=1,1
        if case.role=='live' then
            notes,bookmarks=2,2
            expected={path=expected.path,word=expected.word,annotations=c.projection(current.annotation.annotations),
                xpointer=assert(current.doc_settings:readSetting('last_xpointer'))}
        end
        local selected_id,selected_raw
        for _i,row in ipairs(rows) do
            if row.kind==case.role and row.notes==notes and row.bookmarks==bookmarks then
                local raw=assert(store:get(c.key,row.id));local data=Data.read(raw)
                if c.same(c.projection(data.annotations),expected.annotations) and data.last_xpointer==expected.xpointer then
                    selected_id,selected_raw=row.id,raw;break
                end
            end
        end
        assert(selected_id,'chosen native snapshot does not preserve expected record')
        local confirmation=choose_record(case.role,notes,bookmarks)
        if index==1 then UIManager:forceRePaint();Screen:shot(c.evidence..'/mp-records-confirm.png') end
        assert(Versions.resolve(c.book.cache_dir,c.key)==prior,'preview changed current cache')
        confirmation.ok_callback()
        pump(function() return host.mp_records_job==nil end)
        local path=assert(opened,'native recovery did not open its new copy')
        assert(path~=expected.path and Versions.resolve(c.book.cache_dir,c.key)==path,'new copy was not selected')
        local raw=c.read(path)
        assert(raw:match('<body>(.*)</body>')==c.read(expected.path):match('<body>(.*)</body>'),'recovery changed body markup')
        assert(not Doc:open(path):readSetting('partial_md5_checksum'),'old derived checksum copied')
        local entry={path=path,location=case.location,word=expected.word,annotations=expected.annotations,
            xpointer=expected.xpointer,body_sha256=Crypto.sha256_hex(raw),article_key=c.key,
            record_id=selected_id,record_sha256=Crypto.sha256_hex(selected_raw)}
        finish();c.verify(entry);entries[#entries+1]=entry
        cases[#cases+1]={kind=case.role,location=case.location,archived=true,explicit_confirmation=true,
            records_restored=true,body_unchanged=true,derived_identity_reset=true}
    end
    -- Explicit action also offers an independent copy without applying any row.
    begin('doc');assert(Actions.show(host,c.book,c.article))
    local action
    for _i,row in ipairs(host._mp_actions_menu.item_table) do if row.text==tr('Recover reading records') then action=row end end
    assert(action);action.callback();wait_choice()
    local menu=host._mp_records_menu
    for _i,row in ipairs(menu.item_table) do if row.text==tr('Open new copy without records') then row.callback();break end end
    assert(host._mp_records_confirmation).ok_callback();pump(function() return host.mp_records_job==nil end)
    local fresh=assert(opened);assert(not Doc:hasSidecarFile(fresh),'fresh copy inherited a record before opening')
    finish()
    local value=c.open(fresh);assert(#value.annotation.annotations==0,'fresh copy inherited annotations');c.close(value)
    local entry={path=fresh,location='doc',word='NEWTEXT',annotations={},xpointer=assert(Doc:open(fresh):readSetting('last_xpointer')),
        body_sha256=Crypto.sha256_hex(c.read(fresh))}
    c.verify(entry);entries[#entries+1]=entry
    cases[#cases+1]={kind='fresh_copy',no_records_applied=true}
    -- A failed record write cannot publish the deferred selector.
    begin('doc');request_history(c.sources[1].path);wait_choice()
    local before=Versions.resolve(c.book.cache_dir,c.key);local count=#assert(Versions.list(c.book.cache_dir,c.key))
    local confirmation=choose_record('backup',1,1)
    local flush=Doc.flush;Doc.flush=function(self,...)
        if self.data.doc_path~=c.sources[2].path then return nil end
        return flush(self,...)
    end
    confirmation.ok_callback();pump(function() return host.mp_records_job==nil end);Doc.flush=flush
    assert(not opened and Versions.resolve(c.book.cache_dir,c.key)==before and #Versions.list(c.book.cache_dir,c.key)==count,
        'failed record write changed current version or retained an unselected body')
    finish();cases[#cases+1]={kind='record_write_failure',current_and_originals_kept=true}
    -- The selector rename may succeed even if its immediate readback fails.
    -- Keep that complete body and the released attempt record for inspection.
    begin('doc');request_history(c.sources[1].path);local uncertain_store=wait_choice()
    local selector=assert(require('weread.lib.mp_cache_identity').path(c.book.cache_dir,c.key)):match('^(.*)/[^/]+$')..'/current'
    local rename,open_file=os.rename,io.open;local unknown=false
    rawset(os,'rename',function(from,to)
        local ok,reason=rename(from,to)
        if ok and to==selector then unknown=true end
        return ok,reason
    end)
    rawset(io,'open',function(path,...)
        if unknown and path==selector then return nil,'synthetic selector readback failure' end
        return open_file(path,...)
    end)
    choose_record('backup',1,1).ok_callback()
    local uncertain_stage=assert(host.mp_records_job.stage)
    local attempt=assert(uncertain_stage.lease and uncertain_stage.lease.path)
    pump(function() return host.mp_records_job==nil and uncertain_stage.lease==nil end)
    rawset(os,'rename',rename);rawset(io,'open',open_file)
    local retained=assert(Versions.resolve(c.book.cache_dir,c.key))
    assert(unknown and not opened and retained==uncertain_stage.parent..'/'..uncertain_stage.version_name,
        'unknown readback lost the published body or reported automatic success')
    assert(require('libs/libkoreader-lfs').attributes(attempt,'mode')=='file','unknown commit discarded its ownership record')
    assert(c.same(c.projection(Doc:open(retained):readSetting('annotations')),c.sources[1].annotations),
        'unknown commit retained an incomplete record')
    local snapshot_id=Store.id('backup',c.originals.backup)
    local snapshot_raw=assert(uncertain_store:get(c.key,snapshot_id))
    local retained_entry={path=retained,location='doc',word='OLDTEXT',annotations=c.sources[1].annotations,
        xpointer=c.sources[1].xpointer,body_sha256=Crypto.sha256_hex(c.read(retained)),article_key=c.key,
        record_id=snapshot_id,record_sha256=Crypto.sha256_hex(snapshot_raw)}
    finish();c.verify(retained_entry);entries[#entries+1]=retained_entry
    cases[#cases+1]={kind='selector_readback_unknown',complete_body_retained=true,attempt_record_retained=true,
        records_reopened=true,no_automatic_success=true}
    -- Cancel only after observing an actual live child handle.
    begin('doc')
    local function pause_child(marker)
        local file=assert(io.open(c.evidence..'/'..marker,'wb'));assert(file:write('ready'));file:close()
        socket.sleep(10)
    end
    local prepare=Model.prepare
    Model.prepare=function(...) pause_child('records-inspection-ready');return prepare(...) end
    assert(Recovery.open(host,c.book,c.article,c.sources[1].path));Model.prepare=prepare
    pump(function() return require('libs/libkoreader-lfs').attributes(c.evidence..'/records-inspection-ready') end)
    local pid=assert(host.mp_records_worker.job and host.mp_records_worker.job.pid)
    assert(not host.mp_records_worker.runner.done(pid),'inspection child already exited before cancellation')
    host:closeWeReadUI();pump(function() return host.mp_records_worker.runner.done(pid) end)
    assert(not opened and not host.mp_records_job,'cancelled inspection opened old source')
    finish();cases[#cases+1]={kind='cancel_live_inspection',child_reaped=true,no_file_opened=true}
    begin('doc');request_history(c.sources[1].path);wait_choice()
    before=Versions.resolve(c.book.cache_dir,c.key);count=#Versions.list(c.book.cache_dir,c.key)
    local write_body=Model.write
    Model.write=function(input,stage,sha)
        assert(stage.output:write('unfinished synthetic copy'));pause_child('records-copy-ready')
        return write_body(input,stage,sha)
    end
    choose_record('backup',1,1).ok_callback();Model.write=write_body
    local stage=assert(host.mp_records_job.stage)
    pump(function() return require('libs/libkoreader-lfs').attributes(c.evidence..'/records-copy-ready') end)
    pid=assert(host.mp_records_worker.job and host.mp_records_worker.job.pid)
    assert(not host.mp_records_worker.runner.done(pid),'copy child already exited before cancellation')
    host:closeWeReadUI()
    pump(function() return host.mp_records_worker.runner.done(pid) and not require('libs/libkoreader-lfs').attributes(stage.directory) end)
    assert(not opened and Versions.resolve(c.book.cache_dir,c.key)==before and #Versions.list(c.book.cache_dir,c.key)==count,
        'cancelled copy changed current or saved versions')
    finish();cases[#cases+1]={kind='cancel_live_copy',child_reaped=true,stage_cleaned=true,current_kept=true}
    begin('doc');request_history(c.sources[1].path);wait_choice()
    local account=host.settings:get('account');host.settings:set('account',{user_vid='990099'})
    for _i,row in ipairs(host._mp_records_menu.item_table) do
        if row.text:find(tr('Saved backup record'),1,true) and row.select_enabled then row.callback();break end
    end
    assert(not host.mp_records_job and not opened,'changed account retained recovery authority')
    host.settings:set('account',account);host.settings:flush();finish()
    cases[#cases+1]={kind='account_change',no_file_opened=true}
    -- Exercise the stock switchDocument/showReader coroutine rather than the
    -- capture hook used above to inspect publication before closing the source.
    begin('doc');request_history(c.sources[1].path);local handoff_store=wait_choice()
    local Reader=require('apps/reader/readerui');local source_reader=current
    local create=Reader.new;local created=0
    Reader.new=function(class,options) created=created+1;return create(class,options) end
    host.openFile=original_open
    choose_record('backup',1,1).ok_callback()
    pump(function()
        local target=Reader.instance
        return target and target~=source_reader and target.document
            and target.document.file==Versions.resolve(c.book.cache_dir,c.key)
    end)
    Reader.new=create;assert(created==1,'automatic recovery handoff opened an unexpected number of readers')
    c.count_external_open(created)
    local target=assert(Reader.instance);local path=target.document.file
    assert(target.weread and target.weread:detectWeReadBook()==c.book.book_id,'new reader lost article ownership')
    assert(c.same(c.projection(target.annotation.annotations),c.sources[1].annotations)
        and target.doc_settings:readSetting('last_xpointer')==c.sources[1].xpointer
        and target.document:isXPointerInCurrentPage(c.sources[1].xpointer),'stock handoff did not restore selected records')
    UIManager:forceRePaint();Screen:shot(c.evidence..'/mp-records-reader-handoff.png')
    local selected_id=Store.id('backup',c.originals.backup)
    local raw=assert(handoff_store:get(c.key,selected_id))
    local restored={path=path,location='doc',word='OLDTEXT',annotations=c.sources[1].annotations,
        xpointer=c.sources[1].xpointer,body_sha256=Crypto.sha256_hex(c.read(path)),article_key=c.key,
        record_id=selected_id,record_sha256=Crypto.sha256_hex(raw)}
    c.close(target);current=nil;entries[#entries+1]=restored
    cases[#cases+1]={kind='stock_reader_handoff',actual_switch_document=true,records_visible=true,new_reader_instances=created}
    begin('doc')
    local store=assert(Store.new(c.settings,assert(host.library_db:accountKey())))
    local saved=assert(store:list(c.key));local base=assert(store:get(c.key,Store.id('backup',c.originals.backup)))
    local batch={}
    for index=1,Store.MAX_RECORDS-3-#saved do
        local data=Data.read(base);data.record_fixture=index
        for _i,row in ipairs(data.annotations) do
            if row.drawer then row.text=string.rep('📖',80);row.note=string.rep('📖',80) end
        end
        batch[#batch+1]={kind='backup',raw='return '..require('dump')(data,nil,true)}
        if #batch==3 then assert(store:save(c.key,batch));batch={} end
    end
    if #batch>0 then assert(store:save(c.key,batch)) end
    assert(Recovery.show(host,c.book,c.article,c.sources[1].path));store,saved=wait_choice()
    assert(store:get(c.key,Store.id('backup',c.originals.backup))==c.originals.backup,'large history changed an existing snapshot')
    local encoded=host.client:json_encode{ok=true,rows=saved,source_sha256=string.rep('a',64)}
    assert(#saved>=125 and #encoded>65536 and #encoded<=512*1024,'large Unicode record list did not cross default pipe limit')
    assert(#host._mp_records_menu.item_table==#saved+2,'large snapshot list was truncated')
    host._mp_records_menu.item_table[1].callback()
    local large=assert(host._mp_records_confirmation)
    UIManager:forceRePaint();Screen:shot(c.evidence..'/mp-records-long-preview.png')
    large.cancel_callback();UIManager:close(large)
    assert(not opened,'large record chooser applied a row without confirmation')
    finish();cases[#cases+1]={kind='large_unicode_history',rows=#saved,pipe_bytes=#encoded,not_truncated=true,no_file_opened=true}
    for _i,source in ipairs(c.sources) do assert(Crypto.sha256_hex(c.read(source.path))==source.body_sha256,'original HTML changed') end
    for _i,item in ipairs(entries) do c.verify(item) end
    return {entries=entries,cases=cases,expected_reader_opens=32}
end
