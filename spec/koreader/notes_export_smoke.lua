-- Real ReaderUI, native dialogs, fork/pipe and exclusive output; synthetic only.
return function(plugin,count,flush,home,pump)
    local UIManager=require('ui/uimanager')
    local Screen=require('device').screen
    local ffi=require('ffi')
    local socket=require('socket')
    local lfs=require('libs/libkoreader-lfs')
    local Notes=require('weread.lib.notes_export')
    local Output=require('weread.lib.notes_export_file')
    local Export=require('weread.ui.notes_export')
    local tr=require('weread.lib.i18n').tr
    local client,settings=plugin.client,plugin.settings
    local annotation=assert(plugin.ui.annotation)
    local original_rows,original_props=annotation.annotations,plugin.ui.doc_props
    local parent=tonumber(ffi.C.getpid())
    local real_write=Notes.write
    local rows={
        {drawer='lighten',text='合成划线：第一行\n第二行 <script> [link](https://example.invalid)',note='合成附注\n![remote](secret)',
            chapter='合成章节',pageno=12,page='/not-an-exported-xpointer',datetime='2026-11-09 12:00:00',token='discarded-private-field'},
        {text='Bookmark only'},
        {drawer='underscore',text='',note='只有附注',pageref='xii'},
    }
    local pointer=assert(plugin.ui.document:getXPointer())
    for _,row in ipairs(rows) do row.page=pointer;row.pos0=pointer;row.pos1=pointer end
    Notes.write=function(...)
        assert(tonumber(ffi.C.getpid())~=parent,'export work ran on UI event loop')
        socket.sleep(0.4)
        return real_write(...)
    end
    local request=client.request
    client.request=function() error('local export attempted HTTP') end
    local function close_info()
        local widget=UIManager:getTopmostVisibleWidget()
        if widget and widget~=plugin.ui then UIManager:close(widget) end
    end
    local function read(path)
        local file=assert(io.open(path,'rb'));local bytes=file:read('*a');file:close();return bytes
    end
    local function start(format)
        annotation.annotations=rows;plugin.ui.doc_props={title='合成本机笔记',authors='合成作者'}
        local ok=Export.start(plugin,format)
        annotation.annotations=original_rows;plugin.ui.doc_props=original_props
        return ok
    end
    plugin:closeWeReadUI()
    local entry
    for _,item in ipairs(plugin:getMainMenuItems()) do if item.text==tr('Export local notes') then entry=item end end
    assert(entry and not entry.keep_menu_open,'local notes reader menu missing')
    entry.callback()
    local picker=assert(plugin._notes_export_picker)
    UIManager:forceRePaint();Screen:shot(home..'/../evidence/notes-export-picker.png')
    annotation.annotations=rows;plugin.ui.doc_props={title='合成本机笔记',authors='合成作者'}
    picker.other_buttons[1][1].callback()
    annotation.annotations=original_rows;plugin.ui.doc_props=original_props
    local job=assert(plugin.notes_export_job)
    local md_path=job.output.path
    assert(plugin.notes_export_worker.job.pid~=parent,'export did not spawn a child')
    local heartbeat=false
    UIManager:scheduleIn(0.1,function() heartbeat=true end)
    pump(function() return heartbeat end)
    assert(plugin.notes_export_job,'export blocked heartbeat')
    rows[1].text='Parent edited the highlight after fork'
    pump(function() return not plugin.notes_export_job end);flush()
    assert(not plugin.busy_message,'successful export retained loading')
    local md=read(md_path)
    assert(md:find('> 合成划线：第一行\n> 第二行',1,true) and not md:find('Parent edited',1,true),
        'worker did not retain its start snapshot')
    assert(md:find('&lt;script&gt;',1,true) and not md:find('<script>',1,true)
        and not md:find('[link](',1,true) and not md:find('![remote](',1,true),'Markdown enabled active content')
    assert(md:find(tr('Recorded page')..': xii',1,true) and not md:find('xpointer',1,true),'recorded page semantics wrong')
    UIManager:forceRePaint();Screen:shot(home..'/../evidence/notes-export-success.png');close_info()
    assert(annotation.annotations==original_rows and plugin.ui.doc_props==original_props,'export changed native book state')

    assert(start('json'));local json_path=plugin.notes_export_job.output.path
    pump(function() return not plugin.notes_export_job end);flush();close_info()
    local json=client:json_decode(read(json_path))
    assert(json.schema==1 and json.source=='KOReader' and json.book.title=='合成本机笔记' and #json.annotations==2,'JSON did not round trip')
    assert(json.annotations[1].text=='Parent edited the highlight after fork' and json.annotations[1].note==rows[1].note
        and json.annotations[1].page=='12' and json.annotations[2].page=='xii','JSON lost text/note/page')
    assert(json.annotations[1].token==nil and json.annotations[1].pos0==nil and json.annotations[1].pageno==nil,'JSON leaked native/private fields')
    local success_bytes=read(json_path)
    assert(start('json'));local duplicate=plugin.notes_export_job.output.path
    assert(duplicate~=json_path,'new export reused an existing output path')
    plugin.busy_message:onTapClose()
    assert(not lfs.attributes(duplicate) and not plugin.notes_export_job and not plugin.notes_export_worker.job,'dismiss retained worker/output')
    assert(read(json_path)==success_bytes,'repeated export changed earlier output')

    for _,change in ipairs({'session','account','close_ui','suspend','close_document'}) do
        assert(start('json'));local path=plugin.notes_export_job.output.path
        if change=='session' then
            plugin._reader_session_gen=plugin._reader_session_gen+1
            pump(function() return not plugin.notes_export_job end)
        elseif change=='account' then plugin:onWeReadAccountChanged()
        elseif change=='close_ui' then plugin:closeWeReadUI()
        elseif change=='suspend' then plugin:onSuspend();plugin:onResume()
        else
            -- Exercise the real close handler without closing the live fixture DOM.
            local close=plugin.cancelLocalNotesExport;local reached=false
            plugin.cancelLocalNotesExport=function(self) close(self);reached=true;error('stop after export cleanup',0) end
            local ok,err=pcall(require('weread.lib.reader_lifecycle').onCloseDocument,plugin)
            plugin.cancelLocalNotesExport=close
            assert(not ok and err=='stop after export cleanup' and reached,'close document missed export cancellation')
        end
        assert(not plugin.notes_export_job and not plugin.busy_message and not lfs.attributes(path),change..' retained partial output')
    end
    local deadline=socket.gettime()+0.5
    while socket.gettime()<deadline do flush();socket.sleep(0.01) end

    -- Exclusive creation and identity checks protect existing files and names.
    local directory=assert(Notes.directory(settings))
    local factory_env=getfenv(Output.create)
    local stamp=os.date('%Y%m%d-%H%M%S')
    -- Freeze only this factory's clock; keep the running reader's os unchanged.
    setfenv(Output.create,setmetatable({os=setmetatable({date=function() return stamp end},{__index=os})},{__index=factory_env}))
    local first=assert(Output.create(directory,'Collision','json'))
    assert(first:write('original') and first:sync() and first:accept(8))
    local second=assert(Output.create(directory,'Collision','json'))
    assert(second.path==first.path:gsub('%-1%.json$','-2.json') and read(first.path)=='original',
        'exclusive create did not advance a same-second collision or overwrote an existing file')
    assert(first.identity.permissions=='rw-------','Linux output was not created with private permissions')
    second:abort();assert(not second.path,'aborted descriptor retained path')
    local owned=assert(Output.create(directory,'Replacement','markdown'))
    local replaced=owned.path;local moved=replaced..'.old'
    assert(os.rename(replaced,moved))
    local replacement=assert(io.open(replaced,'wb'));replacement:write('keep replacement');replacement:close()
    owned:abort()
    assert(read(replaced)=='keep replacement','abort removed a replacement inode')
    os.remove(replaced);os.remove(moved);os.remove(first.path);setfenv(Output.create,factory_env)

    local old_cache,old_doc=settings.cache_dir,plugin.ui.document
    settings.cache_dir=settings.data_dir
    plugin.ui.document={file=json_path}
    assert(plugin:detectWeReadBook()==nil,'export under custom cache root became a cloud book')
    plugin.ui.document=old_doc;settings.cache_dir=old_cache
    plugin.create_notes_output=function() return nil end
    assert(not start('json') and not plugin.notes_export_job,'storage failure started export')
    plugin.create_notes_output=nil;close_info()
    Notes.write=real_write;client.request=request
    assert(annotation.annotations==original_rows and plugin.ui.doc_props==original_props,'native annotation state was not restored')
    local report={result='PASS',synthetic_only=true,native_reader_menu=true,native_format_picker=true,
        background_process=true,ui_heartbeat=true,start_snapshot=true,markdown_escaped=true,json_round_trip=true,
        native_private_fields_excluded=true,existing_export_preserved=true,exclusive_file_creation=true,
        cancellation_removes_partial=true,session_guard=true,account_cleanup=true,suspend_cleanup=true,document_cleanup=true,
        replacement_inode_preserved=true,same_second_collision_verified=true,linux_private_permissions=true,custom_cache_root_excluded=true,storage_failure_clean=true,network_calls=0}
    local file=assert(io.open(home..'/../evidence/notes-export.json','w'));file:write(client:json_encode(report));file:close()
    -- Verify the actual mock server remains reachable only after restoring HTTP.
    count('/web/book/read')
    print('PASS: native local-notes Markdown/JSON -> background snapshot -> actual exclusive file/round trip; dismiss/session/account/suspend/close cleanup and replacement-inode guard; no export HTTP')
end
