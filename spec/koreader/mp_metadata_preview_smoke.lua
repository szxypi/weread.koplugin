-- Real FileChooser and history metadata reads, before any article opening.
return function(c)
    local UI, FM = require('ui/uimanager'), require('apps/filemanager/filemanager')
    local Doc, List = require('docsettings'), require('ui/widget/booklist')
    local Model, Store = require('weread.lib.mp_record_recovery'), require('weread.lib.mp_records_db')
    local Content, Data = require('weread.lib.content'), require('weread.lib.mp_record_data')
    local Versions, Crypto = require('weread.lib.mp_cache_versions'), require('weread.lib.crypto')
    local fs, socket = require('libs/libkoreader-lfs'), require('socket')
    local Reader, screen = require('apps/reader/readerui'), require('device').screen
    local function write(path, raw)
        require('util').makePath(path:match('^(.*)/[^/]+$'))
        local file=assert(io.open(path,'wb')); assert(file:write(raw)); assert(file:close())
    end
    local function pump(predicate)
        local deadline=socket.gettime()+30
        while not predicate() do
            assert(socket.gettime()<deadline,'metadata preview deadline')
            UI:setInputTimeout(0); UI:handleInput(); socket.sleep(.01)
        end
    end
    local function clean(base)
        while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=base do UI:close(UI:getTopmostVisibleWidget()) end
    end
    local account=require('weread.lib.library_db'):new(c.settings):accountKey()
    local store=assert(Store.new(c.settings, account))
    local function archived(raw)
        for _i,row in ipairs(assert(store:list(c.key))) do if store:get(c.key,row.id)==raw then return true end end
        return false
    end
    local first=c.sources[1].path
    local parent=first:match('^(.*)/[^/]+$')
    c.choose('doc'); Doc.setIsHashLocationEnabled(true)
    List.resetBookInfoCache(first)
    -- No FileManager exists yet. A damaged MRU candidate is removed by the
    -- actual core read, even though the user has not opened this article.
    local invalid=c.originals.primary:sub(1,-4)..'\n-- truncated candidate\n'
    write(c.shared,invalid); write(c.shared..'.old',c.originals.backup)
    assert(fs.touch(c.shared,os.time(),os.time()) and fs.touch(c.shared..'.old',os.time()-60,os.time()-60))
    List.getBookInfo(first)
    assert(not fs.attributes(c.shared) and fs.attributes(c.shared..'.old'), 'native metadata read did not remove the invalid candidate')
    local function clear_individual(path)
        for _i,location in ipairs({'doc','dir'}) do
            local dir=Doc:getSidecarDir(path, location)
            os.remove(dir..'/'..Doc.getSidecarFilename(path)); os.remove(dir..'/'..Doc.getSidecarFilename(path)..'.old')
        end
        List.resetBookInfoCache(path)
    end
    clear_individual(first)
    c.originals.primary=invalid..'\n-- preview primary boundary\n'
    c.originals.backup=c.originals.backup..'\n-- preview backup boundary\n'
    write(c.shared,c.originals.primary); write(c.shared..'.old',c.originals.backup)
    assert(fs.touch(c.shared,os.time(),os.time()) and fs.touch(c.shared..'.old',os.time()-60,os.time()-60))
    assert(not archived(c.originals.primary) and not archived(c.originals.backup))
    local expected={[first]={c.originals.primary,c.originals.backup}}
    local native_reads=0
    local native=Doc.open
    Doc.open=function(self,path,...)
        if expected[path] then
            for _i,raw in ipairs(expected[path]) do assert(archived(raw), 'list metadata reached native read before snapshot commit') end
            native_reads=native_reads+1
        end
        return native(self,path,...)
    end
    G_reader_settings:saveSetting('collate','percent_unopened_first')
    FM:showFiles(parent)
    local manager=assert(FM.instance); local host=assert(manager.weread)
    assert(native_reads>=1 and not Reader.instance, 'first FileManager layout did not inspect guarded metadata')
    UI:forceRePaint(); screen:shot(c.evidence..'/mp-preview-initial-list.png')
    local cases={{kind='unprotected_native_metadata_control',invalid_shared_candidate_deleted=true,valid_backup_kept=true},
        {kind='first_filemanager_layout',raw_candidates_committed_before_native_read=true,no_reader_opened=true}}
    local legacy=Content.mp_article_legacy_path(c.settings,c.book,c.article)
    local epub=legacy:gsub('%.html$','.epub')
    write(legacy,c.read(first)); write(epub,c.read(c.evidence..'/fm-seed.epub'))
    for _i,path in ipairs({legacy,epub}) do
        clear_individual(path)
        c.choose('hash',manager); Doc.setIsHashLocationEnabled(true)
        local directory=Model.hash_directory(path)
        local filename=Doc.getSidecarFilename(path)
        local primary='return '..require('dump')({doc_path=path,percent_finished=.42,summary={status='reading'},
            doc_pages=25,annotations={},preview_marker=path==legacy and 'TITLE_HTML_PRIMARY' or 'TITLE_EPUB_PRIMARY'},nil,true)
        local backup=primary..'\n-- distinct preview backup\n'
        write(directory..'/'..filename,primary); write(directory..'/'..filename..'.old',backup)
        expected[path]={primary,backup}
        c.choose('dir',manager); Doc.setIsHashLocationEnabled(true); List.resetBookInfoCache(path)
        local before=native_reads
        local info=List.getBookInfo(path)
        assert(info.percent_finished==.42 and native_reads==before+1 and archived(primary) and archived(backup))
        -- Native cache hits must not reopen settings or snapshot records again.
        assert(List.getBookInfo(path)==info and native_reads==before+1)
        cases[#cases+1]={kind=path==legacy and 'title_html_metadata' or 'title_epub_metadata',
            raw_candidates_committed_before_native_read=true,native_cache_hit_no_settings_read=true}
    end
    local history=require('readhistory')
    history.hist={}
    for _i,path in ipairs({first,legacy,epub}) do history:addItem(path) end
    for _i,path in ipairs({first,legacy,epub}) do List.resetBookInfoCache(path) end
    manager.history:onShowHist(); manager.history:showHistDialog()
    assert(not Reader.instance, 'history metadata opened a document')
    clean(manager)
    cases[#cases+1]={kind='actual_history_list_and_status_counts',no_reader_opened=true,native_status_counts_valid=true}
    -- Storage failure must neither enter DocSettings nor poison its cache.
    clear_individual(legacy)
    local directory=Model.hash_directory(legacy); local filename=Doc.getSidecarFilename(legacy)
    local failure_raw=expected[legacy][1]:sub(1,-4)..'\n-- failed preservation boundary\n'
    write(directory..'/'..filename,failure_raw);write(directory..'/'..filename..'.old',expected[legacy][2])
    expected[legacy]={failure_raw,expected[legacy][2]}
    local legacy_input=assert(Model.capture(host.settings,c.book,c.article,legacy))
    local frozen=Model.freeze(legacy_input)
    local before=native_reads
    local save=Store.save; Store.save=function() return false end
    List.resetBookInfoCache(legacy)
    local info=List.getBookInfo(legacy)
    assert(info._weread_metadata_unavailable and info.been_opened==false and info.percent_finished==nil
        and native_reads==before and not List.hasBookInfoCache(legacy),'failed snapshot read or cached invented metadata')
    local same_frozen=Model.freeze(legacy_input)
    assert(Data.same(frozen,same_frozen),'failed preservation changed source records')
    manager.file_chooser:changeToPath(legacy:match('^(.*)/[^/]+$'))
    local placeholder
    for _i,item in ipairs(manager.file_chooser.item_table) do if item.path==legacy then placeholder=item.mandatory end end
    assert(placeholder=='–','unavailable metadata displayed a fabricated percentage')
    manager.history:onShowHist(); manager.history:showHistDialog(); clean(manager)
    UI:forceRePaint(); screen:shot(c.evidence..'/mp-preview-save-failed.png')
    Store.save=save
    info=List.getBookInfo(legacy)
    assert(not info._weread_metadata_unavailable and native_reads>before,'repaired storage did not retry native metadata')
    cases[#cases+1]={kind='snapshot_save_failure_then_retry',native_read_blocked=true,raw_records_unchanged=true,
        no_invented_percentage=true,native_history_counts_safe=true,failed_result_not_cached=true,retry_succeeded=true}
    -- Continue from the actual FileManager after preview removed damaged data. Both old
    -- shared candidates must still be available for an explicit recovery.
    local created=0; local new=Reader.new
    Reader.new=function(class, options) created=created+1; return new(class, options) end
    manager:openFile(first)
    pump(function() return host._mp_records_menu or not host.mp_records_job end)
    local menu=assert(host._mp_records_menu)
    local selected
    for index,row in ipairs(assert(store:list(c.key))) do
        if store:get(c.key,row.id)==c.originals.backup then menu.item_table[index].callback(); selected=row; break end
    end
    assert(selected and not Reader.instance and created==0)
    local raw=assert(store:get(c.key,selected.id));local data=Data.record(raw)
    assert(host._mp_records_confirmation).ok_callback()
    pump(function() return Reader.instance and Reader.instance.document.file==Versions.resolve(c.book.cache_dir,c.key) end)
    Reader.new=new; c.count_external_open(created); assert(created==1)
    local reader=Reader.instance
    assert(c.same(c.projection(reader.annotation.annotations),c.projection(data.annotations)))
    local entry={path=reader.document.file,location='dir',word='OLDTEXT',annotations=c.projection(data.annotations),
        xpointer=data.last_xpointer,body_sha256=Crypto.sha256_hex(c.read(reader.document.file)),article_key=c.key,
        record_id=selected.id,record_sha256=Crypto.sha256_hex(raw)}
    c.close(reader); c.verify(entry)
    cases[#cases+1]={kind='explicit_recovery_after_metadata_preview',primary_and_backup_retained=true,
        native_reader_handoff=true,chosen_notes_and_position_restored=true}
    Doc.open=native
    return {entries={entry},cases=cases,expected_reader_opens=4}
end
