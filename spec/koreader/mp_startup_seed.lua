-- Seed actual old records and enable protection through the native setting.
return function(c)
    local UI,FM=require('ui/uimanager'),require('apps/filemanager/filemanager')
    local Model=require('weread.lib.startup_patch')
    local Records=require('weread.lib.mp_record_recovery')
    local Data=require('weread.lib.mp_record_data')
    local Doc=require('docsettings')
    local Crypto=require('weread.lib.crypto')
    local function write(path,raw)
        require('util').makePath(path:match('^(.*)/[^/]+$'))
        local f=assert(io.open(path,'wb'));assert(f:write(raw));assert(f:close())
    end
    local target=c.sources[1].path
    local chosen=c.originals.backup
    local primary=c.originals.primary
    local opens=2
    if os.getenv('WEREAD_STARTUP_CONTENT')=='epub' then
        target=require('weread.lib.content').mp_article_legacy_path(c.settings,c.book,c.article):gsub('%.html$','.epub')
        write(target,c.read(c.evidence..'/fm-seed.epub'))
        c.choose('hash');Doc.setIsHashLocationEnabled(true)
        local reader=c.open(target);reader.rolling:onGotoPage(3)
        local selection=assert(reader.document:getTextFromPositions({x=1,y=1},
            {x=require('device').screen:getWidth()-2,y=require('device').screen:getHeight()-2},true))
        reader.annotation:addItem{page=selection.pos0,pos0=selection.pos0,pos1=selection.pos1,text=selection.text,
            note='STARTUP_EPUB_RECORD',drawer='lighten',datetime='2026-11-10 22:00:00'}
        c.close(reader);opens=opens+1
        chosen=c.read(assert(Doc:findSidecarFile(target)));primary=chosen
    end
    FM:showFiles(c.book.cache_dir)
    local manager=assert(FM.instance);local host=assert(manager.weread)
    local advanced
    for _i,row in ipairs(host:getSettingsMenuItems()) do
        if row.text==require('weread.lib.plugin_util').tr('Advanced options') then advanced=row end
    end
    local entry=assert(advanced).sub_item_table_func()[1]
    assert(entry.text==require('weread.lib.plugin_util').tr('Protect old article records at startup') and not entry.checked_func())
    local root=assert(require('ffi/util').realpath(host.path))
    local store=assert(Model.new(root));assert(store:status()=='absent')
    local function clean()
        while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=manager do UI:close(UI:getTopmostVisibleWidget()) end
    end
    entry.callback();UI:close(assert(UI:getTopmostVisibleWidget()))
    assert(store:status()=='absent','cancelled startup setting wrote an executable bridge')
    entry.callback();assert(UI:getTopmostVisibleWidget().ok_callback)()
    clean();assert(entry.checked_func() and c.read(store.path)==store.raw)
    entry.callback();assert(UI:getTopmostVisibleWidget().ok_callback)()
    clean();assert(not entry.checked_func() and store:status()=='absent')
    write(store.path,'-- unrelated user-owned startup file\n')
    entry.callback();clean()
    assert(c.read(store.path)=='-- unrelated user-owned startup file\n' and not store:disable(), 'foreign startup file was changed')
    assert(os.remove(store.path))
    entry.callback();assert(UI:getTopmostVisibleWidget().ok_callback)()
    clean();assert(entry.checked_func() and store:status()=='installed')
    UI:forceRePaint();require('device').screen:shot(c.evidence..'/startup-enabled.png')
    -- Make these exact raw bytes new only after the seed UI has finished.
    -- The next process must preserve them before its first provider lookup.
    local dir=Records.hash_directory(target);local name=Doc.getSidecarFilename(target)
    primary=primary..'\n-- cold startup primary boundary\n'
    chosen=chosen..'\n-- cold startup backup boundary\n'
    for _i,location in ipairs({'doc','dir'}) do
        local base=Doc:getSidecarDir(target,location)
        os.remove(base..'/'..name);os.remove(base..'/'..name..'.old')
    end
    write(dir..'/'..name,primary);write(dir..'/'..name..'.old',chosen)
    local input=assert(Records.capture(host.settings,c.book,c.article,target))
    local frozen=Records.freeze(input)
    local hashes={};for _i,row in ipairs(frozen) do hashes[#hashes+1]=Crypto.sha256_hex(row.raw) end
    local data=Data.record(chosen)
    write(c.evidence..'/startup-original.bin',c.read(target))
    write(c.evidence..'/startup-input.json',require('json').encode{target=target,key=c.key,root=c.book.cache_dir,
        original_raw_hashes=hashes,chosen_raw_sha256=Crypto.sha256_hex(chosen),annotations=c.projection(data.annotations),
        xpointer=data.last_xpointer,source_sha256=Crypto.sha256_hex(c.read(target)),source_backup=c.evidence..'/startup-original.bin',
        patch_path=store.path,plugin_root=root,content=os.getenv('WEREAD_STARTUP_CONTENT') or 'html'})
    G_reader_settings:saveSetting('lastfile',target)
    G_reader_settings:saveSetting('start_with','last')
    G_reader_settings:saveSetting('quickstart_shown_version',9999999999)
    G_reader_settings:flush()
    return {entries={},cases={{kind='native_startup_setting',default_off=true,cancel_no_write=true,enable_reread=true,
        disable_only_owned=true,foreign_file_kept=true,final_enabled=true}},expected_reader_opens=opens}
end
