-- Actual history module, provider lookup, record choices and ReaderUI handoff.
return function(c)
    local UI,Reader,Doc=require('ui/uimanager'),require('apps/reader/readerui'),require('docsettings')
    local Model,Store=require('weread.lib.mp_record_recovery'),require('weread.lib.mp_records_db')
    local Data,Versions=require('weread.lib.mp_record_data'),require('weread.lib.mp_cache_versions')
    local Guard,Registry=require('weread.ui.mp_reader_open'),require('document/documentregistry')
    local Screen=require('device').screen
    local Crypto,fs,socket=require('weread.lib.crypto'),require('libs/libkoreader-lfs'),require('socket')
    local function write(path,value)
        require('util').makePath(path:match('^(.*)/[^/]+$'))
        local f=assert(io.open(path,'wb'));assert(f:write(value));f:close()
    end
    local function pump(predicate)
        local deadline=socket.gettime()+25
        while not predicate() do assert(socket.gettime()<deadline,'reader recovery deadline');UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01) end
    end
    local legacy=require('weread.lib.content').mp_article_legacy_path(c.settings,c.book,c.article)
    local epub=legacy:gsub('%.html$','.epub')
    write(legacy,c.read(c.sources[1].path));write(epub,c.read(c.evidence..'/fm-seed.epub'))
    local html_raw,epub_raw=c.read(legacy),c.read(epub)
    local function note(reader,value)
        local selection=assert(reader.document:getTextFromPositions({x=1,y=1},{x=Screen:getWidth()-2,y=Screen:getHeight()-2},true))
        reader.annotation:addItem{page=selection.pos0,pos0=selection.pos0,pos1=selection.pos1,text=selection.text,
            note=value,drawer='lighten',datetime='2026-11-10 20:00:00'}
    end
    c.choose('hash');local reader=c.open(epub);reader.rolling:onGotoPage(3);note(reader,'READER_EPUB_SOURCE');c.close(reader)
    local function current(location)
        c.choose('hash');write(c.shared,c.originals.primary);write(c.shared..'.old',c.originals.backup)
        local value=c.open(c.sources[2].path)
        note(value,'UNSAVED_READER_NOTE');c.choose(location,value);Doc.setIsHashLocationEnabled(true)
        return value,assert(value.weread)
    end
    local function choose(host,wanted)
        pump(function() return host._mp_records_menu or not host.mp_records_job end)
        assert(host._mp_records_menu,'native reader bypassed record selection')
        local store=assert(Store.new(host.settings,host.library_db:accountKey()))
        for index,row in ipairs(assert(store:list(c.key))) do
            if row.valid then
                local data=Data.record(assert(store:get(c.key,row.id)))
                for _i,annotation in ipairs(data.annotations or {}) do
                    if annotation.note==wanted then host._mp_records_menu.item_table[index].callback();return host._mp_records_confirmation,row,store end
                end
            end
        end
        error('expected reader record not preserved')
    end
    local entries,cases={},{}
    for index,scene in ipairs({{path=c.sources[1].path,location='doc',note='UNSAVED_READER_NOTE'},
        {path=legacy,location='dir',note='合成旧笔记 backup'},
        {path=epub,location='hash',note='READER_EPUB_SOURCE',epub=true},
        {path=epub,location='doc',note='READER_EPUB_SOURCE',epub=true,direct=true}}) do
        local host;reader,host=current(scene.location)
        local expected=Model.freeze(Model.capture(host.settings,c.book,c.article,scene.path))
        local function preserved()
            local store=assert(Store.new(host.settings,host.library_db:accountKey()));local raws={}
            for _i,row in ipairs(assert(store:list(c.key))) do raws[assert(store:get(c.key,row.id))]=true end
            for _i,row in ipairs(expected) do assert(raws[row.raw],'provider read before raw candidate preservation') end
        end
        local get_provider=Registry.getProvider;local provider_reads=0
        Registry.getProvider=function(self,path,...)
            if path==scene.path then preserved();provider_reads=provider_reads+1 end
            return get_provider(self,path,...)
        end
        if index==1 then
            -- Exercise the real unprotected core ordering without allowing its
            -- provider call to mutate records. Reattach before the actual test.
            Guard.detach(host);local reached=false
            Registry.getProvider=function(self,path,...)
                if path==scene.path then reached=true;error('unprotected native provider lookup',0) end
                return get_provider(self,path,...)
            end
            local ok=pcall(reader.history.onMenuSelect,reader.history,{file=scene.path})
            assert(not ok and reached and Reader.instance==reader)
            Guard.attach(host)
            Registry.getProvider=function(self,path,...)
                if path==scene.path then preserved();provider_reads=provider_reads+1 end
                return get_provider(self,path,...)
            end
        end
        local create=Reader.new;local created=0;Reader.new=function(class,options) created=created+1;return create(class,options) end
        local after=0
        if scene.direct then
            local provider=Registry:getProviders(scene.path)[1].provider
            reader:switchDocument(scene.path,true,function() after=after+1 end,provider,true)
        else reader.history:onShowHist();reader.history:onMenuSelect{file=scene.path} end
        local dialog,row,store=choose(host,scene.note)
        assert(Reader.instance==reader and created==0 and not reader.tearing_down and (scene.direct or provider_reads>=1))
        preserved()
        if index==1 then UI:forceRePaint();Screen:shot(c.evidence..'/mp-reader-confirm.png') end
        local raw=assert(store:get(c.key,row.id));local data=Data.record(raw)
        dialog.ok_callback()
        pump(function() return Reader.instance and Reader.instance~=reader and Reader.instance.document.file==Versions.resolve(c.book.cache_dir,c.key) end)
        Reader.new=create;Registry.getProvider=get_provider;c.count_external_open(created)
        assert(created==1,'history created more than one target reader')
        if scene.direct then assert(after==1,'direct forced-provider callback lost') end
        local opened=Reader.instance;assert(c.same(c.projection(opened.annotation.annotations),c.projection(data.annotations)))
        local entry={path=opened.document.file,location=scene.location,word=scene.epub and 'FM_EPUB_TEXT' or 'OLDTEXT',
            annotations=c.projection(data.annotations),xpointer=data.last_xpointer,body_sha256=Crypto.sha256_hex(c.read(opened.document.file)),
            article_key=c.key,record_id=row.id,record_sha256=Crypto.sha256_hex(raw)}
        c.close(opened);c.verify(entry);entries[#entries+1]=entry
        cases[#cases+1]={kind=scene.direct and 'direct_forced_epub_switch' or scene.epub and 'native_history_epub' or index==1 and 'native_history_managed_html_live_notes' or 'native_history_title_html',
            provider_reads=provider_reads,raw_candidates_saved_before_provider=true,explicit_record_choice=true,stock_reader_instances=created}
    end
    local host;reader,host=current('doc');reader.history:onMenuSelect{file=legacy}
    local dialog=choose(host,'合成旧笔记 backup');dialog.cancel_callback()
    assert(Reader.instance==reader and not reader.tearing_down);host:closeWeReadUI();c.close(reader)
    cases[#cases+1]={kind='cancel_record_confirmation',current_reader_kept=true}
    reader,host=current('doc');G_reader_settings:saveSetting('file_ask_to_open',true)
    reader.history:onMenuSelect{file=legacy};dialog=assert(host._mp_reader_open_confirmation)
    dialog.cancel_callback();dialog.ok_callback()
    assert(Reader.instance==reader and not host.mp_records_job and not host._mp_reader_open_confirmation)
    G_reader_settings:delSetting('file_ask_to_open');c.close(reader)
    cases[#cases+1]={kind='cancel_native_open_prompt',late_callback_ignored=true}
    reader,host=current('doc');G_reader_settings:saveSetting('file_ask_to_open',true)
    reader.history:onMenuSelect{file=legacy};dialog=assert(host._mp_reader_open_confirmation);dialog.ok_callback()
    dialog=choose(host,'合成旧笔记 backup');dialog.cancel_callback()
    assert(Reader.instance==reader and not reader.tearing_down)
    G_reader_settings:delSetting('file_ask_to_open');host:closeWeReadUI();c.close(reader)
    cases[#cases+1]={kind='confirm_native_open_prompt',current_reader_kept_before_record_choice=true}
    reader,host=current('doc');G_reader_settings:saveSetting('file_ask_to_open',true)
    reader.history:onMenuSelect{file=legacy};dialog=assert(host._mp_reader_open_confirmation)
    write(legacy,html_raw..'changed');dialog.ok_callback()
    assert(Reader.instance==reader and not host.mp_records_job and not host._mp_reader_open_confirmation)
    write(legacy,html_raw);G_reader_settings:delSetting('file_ask_to_open');host:closeWeReadUI();c.close(reader)
    cases[#cases+1]={kind='source_changed_during_native_prompt',no_switch_or_recovery=true}
    reader,host=current('doc');reader:switchDocument(legacy)
    dialog=choose(host,'合成旧笔记 backup')
    local writer=Model.write;local ready=c.evidence..'/reader-copy-ready'
    Model.write=function(...) write(ready,'ready');socket.sleep(10);return writer(...) end
    dialog.ok_callback();Model.write=writer;pump(function() return fs.symlinkattributes(ready) end)
    local stage=assert(host.mp_records_job.stage);local worker=host.mp_records_worker;local pid=assert(worker.job.pid)
    host:onSuspend()
    pump(function() return worker.runner.done(pid) and not fs.symlinkattributes(stage.directory) end)
    assert(Reader.instance==reader and not host.mp_records_job);host:onResume();c.close(reader)
    cases[#cases+1]={kind='suspend_during_direct_switch_copy',child_reaped=true,current_reader_kept=true,stage_cleaned=true}
    for _i,entry in ipairs(entries) do c.verify(entry) end
    assert(c.read(legacy)==html_raw and c.read(epub)==epub_raw)
    return {entries=entries,cases=cases,expected_reader_opens=24}
end
