-- Packaged plugin widgets and actual background worker, using a synthetic server.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
assert(os.getenv('WEREAD_SYNTHETIC')=='1')
local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/'))
package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
G_reader_settings=require('luasettings'):wrap({});G_defaults=require('luadefaults'):open()
local Device=require('device');require('document/canvascontext'):init(Device)
local json=require('json');local input=json.decode(assert(io.stdin:read('*a')))
local scope={vid=input.credentials.vid,epoch=1}
local settings={data_dir=home,cache_dir=home,mock_endpoint=input.mock_endpoint,
    get=function(_,_,default) return default end,get_auth_scope=function() return scope end,
    auth_scope_matches=function(_,value) return value==scope end}
local store={read=function() return input.credentials,1,nil,false end}
local Access=require('weread.lib.native_read_access');local capture=Access.capture
Access.capture=function(s,existing) return capture(s,existing or store) end
local UI=require('ui/uimanager');local socket=require('socket')
local function pump(predicate)
    local deadline=socket.gettime()+100
    while not predicate() do
        assert(socket.gettime()<deadline,'native batch timeout')
        UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
    end
end
if input.mode=='cleanup_ui_cancel' or input.mode=='cleanup_ui_stale' or input.mode=='cleanup_ui_run'
    or input.mode=='cleanup_ui_cancel_during'
    or input.mode=='cleanup_ui_pending' or input.mode=='cleanup_ui_active' or input.mode=='cleanup_ui_corrupt' then
    assert(dofile(assert(arg[1])..'/spec/koreader/offline_network_guard.lua')())
    local cache=require('weread.lib.native_direct_cache')
    local book={book_id='42',title='Synthetic',author='Fixture',chapters={}}
    settings=require('weread.lib.settings'):new()
    settings.data_dir=home;settings.cache_dir=home..'/book-cache'
    assert(require('util').makePath(settings.cache_dir))
    settings:set('account',{user_vid='12345678',name='Synthetic',login_method='qr'})
    settings:set('cookies',{wr_vid='12345678',wr_skey='synthetic'})
    settings:set('books',{['42']=book});settings:flush()
    scope=assert(settings:get_auth_scope())
    local client=require('weread.lib.client'):new(settings)
    local library=require('weread.lib.library_db'):new(settings)
    local coverage=require('weread.lib.readtime_coverage'):new(home);assert(coverage:initialize())
    local host={settings=settings,client=client,library_db=library,readtime_coverage=coverage,
        offline_time={store=require('weread.lib.offline_time_store'):new(home)},ui={},
        discovery_epoch=1,_reader_session_gen=1,isNetworkConnected=function() return true end,
        showBusy=function(self,label,cancel)
            self.busy_message=require('ui/widget/infomessage'):new{text=label,callback=cancel};UI:show(self.busy_message)
        end,
        closeBusy=function(self) UI:close(self.busy_message);self.busy_message=nil end,
        showInfo=function(self,message) self.message=message end,
        showList=require('weread.ui.common').showList,showBookMenu=require('weread.ui.library').showBookMenu,
        getFullBookCachePath=function() return home..'/missing.epub' end,bookRecordHasDownload=function() return false end,
        safeCallback=function(_,_,callback) return callback end,refreshShelfCacheIndicators=function() end,
        cancelBookMetadata=function() end,cancelBookReading=function() end}
    host:showBookMenu(book)
    local action
    for _,button in ipairs(host._book_detail_view._action_buttons) do
        if button.text==require('weread.lib.plugin_util').tr('Clear unused E-Ink chapters') then action=button end
    end
    assert(action,'cleanup action missing')
    local state_path,state_backup
    if input.mode=='cleanup_ui_active' then
        local rows=assert(cache.list(settings,scope.vid,'42',function() return true end))
        host.ui.document={file=assert(cache.open(settings,scope.vid,'42',rows[3],function() return true end)).path}
    elseif input.mode=='cleanup_ui_pending' then
        package.loaded['weread.lib.native_position_store']={new=function() return {read=function() return {phase='pending'} end} end}
    elseif input.mode=='cleanup_ui_corrupt' then
        state_path=assert(settings:get_book('42')).cache_dir..'/.weread-accounts/'..library:accountKey()..'/reading_state.json'
        local state=assert(io.open(state_path,'rb'));state_backup=assert(state:read('*a'));assert(state:close())
        state=assert(io.open(state_path,'wb'));assert(state:write('corrupt'));assert(state:close())
    elseif input.mode=='cleanup_ui_cancel_during' then
        local model=require('weread.lib.native_direct_cleanup');local step=model.step
        model.step=function(...)
            local ok,reason=step(...)
            if ok then
                local hit=assert(io.open(home..'/cleanup-hit','wb'));assert(hit:write('done'));assert(hit:close())
                while true do socket.sleep(.1) end
            end
            return ok,reason
        end
    end
    action.callback()
    if input.mode=='cleanup_ui_active' or input.mode=='cleanup_ui_pending' or input.mode=='cleanup_ui_corrupt' then
        pump(function() return host.message~=nil end)
        assert(not host._native_cleanup and not host.busy_message,'unsafe cleanup was offered')
        assert(#assert(cache.list(settings,scope.vid,'42',function() return true end))==3)
        if state_path then
            local state=assert(io.open(state_path,'wb'));assert(state:write(state_backup));assert(state:close())
        end
        print('WEREAD_DIRECT_BATCH='..json.encode{ok=true,mode=input.mode,network_blocked=true});os.exit(0)
    end
    pump(function() return host._native_cleanup and host._native_cleanup.dialog or host.message end)
    assert(not host.message,host.message)
    local dialog=assert(host._native_cleanup.dialog)
    if input.mode=='cleanup_ui_cancel' then dialog.cancel_callback();UI:close(dialog)
    elseif input.mode=='cleanup_ui_stale' then
        settings:set('account',{user_vid='87654321'});settings:flush()
        dialog.ok_callback();UI:close(dialog)
    elseif input.mode=='cleanup_ui_cancel_during' then
        dialog.ok_callback();UI:close(dialog)
        pump(function() local file=io.open(home..'/cleanup-hit','rb');if file then file:close();return true end end)
        require('weread.ui.native_direct_cleanup').cancel(host)
    else
        dialog.ok_callback();UI:close(dialog)
        pump(function() return host.message~=nil end)
        assert(host.message==require('weread.lib.plugin_util').T(
            require('weread.lib.plugin_util').tr('Cleared %1 unused E-Ink chapters.'),'1'),host.message)
    end
    assert(not host._native_cleanup and not host.busy_message)
    local saved=assert(cache.list(settings,'12345678','42',function() return true end))
    assert(#saved==((input.mode=='cleanup_ui_run' or input.mode=='cleanup_ui_cancel_during') and 2 or 3),
        'unexpected number of saved chapters')
    assert(cache.present(settings,'12345678','42'),'remaining saved chapters lost their indicator')
    print('WEREAD_DIRECT_BATCH='..json.encode{ok=true,mode=input.mode,network_blocked=true});os.exit(0)
end
if input.mode=='cleanup_start' or input.mode=='cleanup_recover' or input.mode=='cleanup_corrupt' then
    assert(dofile(assert(arg[1])..'/spec/koreader/offline_network_guard.lua')())
    local cache=require('weread.lib.native_direct_cache')
    local cleanup=require('weread.lib.native_direct_cleanup')
    local ledger=require('weread.lib.offline_time_store'):new(home)
    local owner=require('weread.lib.native_position_contract').account_key(scope.vid)
    local codec=require('weread.lib.client'):new(settings)
    local current=function() return true end
    local rows=assert(cache.list(settings,scope.vid,'42',current))
    if input.mode=='cleanup_start' then
        assert(#rows==3)
        local first=assert(cache.open(settings,scope.vid,'42',rows[1],current))
        local second=assert(cache.open(settings,scope.vid,'42',rows[2],current))
        local sidecar=require('docsettings'):getSidecarDir(first.path,'doc')
        assert(require('util').makePath(sidecar))
        local note=assert(io.open(sidecar..'/metadata.epub.lua','wb'));assert(note:write('synthetic note'));assert(note:close())
        assert(ledger:begin(owner,{book_id='42',stats_book=1,start_time=100,time_zone='+08:00',
            book_version=second.book_version,file_id=second.file_id,version_source='native_direct'}))
    else assert(#rows==2,'interrupted copy was exposed to the reader') end
    local lease=assert(cache.acquire(settings,scope.vid,'42'))
    local plan=assert(cleanup.scan(settings,scope.vid,'42',owner,codec,current,lease))
    if input.mode=='cleanup_corrupt' then
        assert(#plan.items==0 and plan.protected==3,'corrupt recovery record was trusted')
        lease:release()
        print('WEREAD_DIRECT_BATCH='..json.encode{ok=true,mode=input.mode,network_blocked=true});os.exit(0)
    end
    assert(#plan.items==1 and plan.protected==2,'protected chapters were selected')
    local again=assert(cleanup.scan(settings,scope.vid,'42',owner,codec,current,lease))
    assert(cleanup.same_plan(plan,again),'stable cleanup plan changed')
    if input.mode=='cleanup_start' then
        local item=plan.items[1];assert(not item.staged and item.record.files['catalog.txt'])
        local lfs=require('libs/libkoreader-lfs');local stat=lfs.symlinkattributes
        local target=plan.root..'/'..item.folder..'/wr-chapter-'
            ..require('weread.lib.crypto').sha256_hex('42\0'..item.record.chapter)..'.epub'
        rawset(lfs,'symlinkattributes',function(path,...)
            local attr,err,number=stat(path,...)
            if path==target and type(attr)=='table' then attr.ino=1e18 end
            return attr,err,number
        end)
        local large_inode=assert(cleanup.scan(settings,scope.vid,'42',owner,codec,current,lease))
        rawset(lfs,'symlinkattributes',stat)
        assert(#large_inode.items==1,'large filesystem inode was rejected')
        local pinned=rows[3]
        pinned.file_id=assert(cache.open(settings,scope.vid,'42',pinned,current)).file_id
        local database=require('lua-ljsqlite3/init').open(home..'/library-'..owner..'.db')
        database:exec([[CREATE TABLE native_direct_mark_source (
            cache_key TEXT PRIMARY KEY,book_id TEXT NOT NULL,chapter_uid TEXT NOT NULL,file_id TEXT NOT NULL,
            source_hash TEXT NOT NULL,body TEXT NOT NULL,serial INTEGER NOT NULL)]])
        local statement=database:prepare('INSERT INTO native_direct_mark_source VALUES(?,?,?,?,?,?,?)')
        statement:bind(pinned.key,'42',pinned.chapter_uid,pinned.file_id,pinned.source_sha256,'synthetic',1):step()
        statement:close();database:close()
        local marked=assert(cleanup.scan(settings,scope.vid,'42',owner,codec,current,lease))
        assert(#marked.items==0 and marked.protected==3,'cached mark source was selected')
        assert(not cleanup.step(settings,codec,plan,lease,1,current),'new cached mark source did not invalidate cleanup')
        database=require('lua-ljsqlite3/init').open(home..'/library-'..owner..'.db')
        database:exec('DELETE FROM native_direct_mark_source');database:close()
        -- A retained selection draft protects its chapter even if the
        -- verified raw-source cache has since been evicted.
        database=require('lua-ljsqlite3/init').open(home..'/library-'..owner..'.db')
        database:exec('CREATE TABLE thought_drafts (book_id TEXT,operation TEXT,reference_id TEXT)')
        statement=database:prepare('INSERT INTO thought_drafts VALUES(?,?,?)')
        statement:bind('42','create','selection:'..pinned.chapter_uid..':1-2:'..pinned.source_sha256):step()
        statement:close();database:close()
        local draft_plan=assert(cleanup.scan(settings,scope.vid,'42',owner,codec,current,lease))
        assert(#draft_plan.items==0 and draft_plan.protected==3,'draft chapter was selected after source eviction')
        assert(not cleanup.step(settings,codec,plan,lease,1,current),'new thought draft did not invalidate cleanup')
        database=require('lua-ljsqlite3/init').open(home..'/library-'..owner..'.db')
        database:exec("UPDATE thought_drafts SET reference_id='selection:invalid'");database:close()
        local invalid_draft=assert(cleanup.scan(settings,scope.vid,'42',owner,codec,current,lease))
        assert(#invalid_draft.items==0 and invalid_draft.protected==3,'unverifiable draft allowed cleanup')
        database=require('lua-ljsqlite3/init').open(home..'/library-'..owner..'.db')
        database:exec('DROP TABLE thought_drafts');database:close()
        local library={accountKey=function() return owner end,
            open=function() return require('lua-ljsqlite3/init').open(home..'/library-'..owner..'.db') end}
        assert(require('weread.lib.native_direct_pending').save(library,settings,scope,pinned,'/synthetic.1',current))
        local pending_plan=assert(cleanup.scan(settings,scope.vid,'42',owner,codec,current,lease))
        assert(#pending_plan.items==0 and pending_plan.protected==3,'pending offline page was selected')
        assert(not cleanup.step(settings,codec,plan,lease,1,current),'new offline reminder did not invalidate cleanup')
        database=require('lua-ljsqlite3/init').open(home..'/library-'..owner..'.db')
        database:exec('DELETE FROM native_direct_offline_pending');database:close()
        settings.get_book=function() return {native_home_resume={entry=pinned}} end
        local referenced=assert(cleanup.scan(settings,scope.vid,'42',owner,codec,current,lease))
        assert(#referenced.items==0 and referenced.protected==3,'home resume chapter was selected')
        assert(not cleanup.step(settings,codec,plan,lease,1,current),'new home resume did not invalidate cleanup')
        settings.get_book=function() return {last_local_position={file_id=pinned.file_id}} end
        referenced=assert(cleanup.scan(settings,scope.vid,'42',owner,codec,current,lease))
        assert(#referenced.items==0 and referenced.protected==3,'saved position source was selected')
        settings.get_book=function() return {pending_upload_position={file_id='invalid'}} end
        referenced=assert(cleanup.scan(settings,scope.vid,'42',owner,codec,current,lease))
        assert(#referenced.items==0 and referenced.protected==3,'unverified position source was ignored')
        settings.get_book=function() return {book_id='43'} end
        referenced=assert(cleanup.scan(settings,scope.vid,'42',owner,codec,current,lease))
        assert(#referenced.items==0 and referenced.protected==3,'mismatched book metadata was ignored')
        settings.get_book=nil
        local legacy_dir=home..'/legacy-book';assert(require('libs/libkoreader-lfs').mkdir(legacy_dir))
        local state=assert(io.open(legacy_dir..'/reading_state.json','wb'));assert(state:write('corrupt'));assert(state:close())
        settings.get_book_indexes=function() return {['42']={cache_dir=legacy_dir}} end
        referenced=assert(cleanup.scan(settings,scope.vid,'42',owner,codec,current,lease))
        assert(#referenced.items==0 and referenced.protected==3,'corrupt reading state was ignored')
        assert(os.remove(legacy_dir..'/reading_state.json'));assert(require('libs/libkoreader-lfs').rmdir(legacy_dir))
        settings.get_book_indexes=nil
        local unknown=plan.root..'/'..item.folder..'/unexpected.txt'
        local extra=assert(io.open(unknown,'wb'));assert(extra:write('do not delete'));assert(extra:close())
        local changed=assert(cleanup.scan(settings,scope.vid,'42',owner,codec,current,lease))
        assert(#changed.items==0 and not cleanup.same_plan(plan,changed),'unexpected file did not invalidate preview')
        assert(not cleanup.step(settings,codec,plan,lease,1,current),'stale plan removed files')
        assert(os.remove(unknown))
        local old_remove=os.remove
        rawset(os,'remove',function(path) if path:match('/catalog%.txt$') then return nil end return old_remove(path) end)
        local ok=cleanup.step(settings,codec,plan,lease,1,current)
        rawset(os,'remove',old_remove)
        assert(not ok,'injected interruption did not stop cleanup')
        local dir=plan.root..'/'..item.folder
        assert(require('libs/libkoreader-lfs').symlinkattributes(dir..'/'..cache.RETIRING),'missing recovery record')
        assert(not require('libs/libkoreader-lfs').symlinkattributes(dir..'/wr-chapter-'
            ..require('weread.lib.crypto').sha256_hex('42\0'..item.record.chapter)..'.epub'))
        assert(not cache.open(settings,scope.vid,'42',rows[3],current),'partially cleaned copy was opened')
    else
        assert(plan.items[1].staged,'new process did not find interrupted deletion')
        local ok,why=cleanup.step(settings,codec,plan,lease,1,current)
        assert(ok and why=='done','recovery did not finish')
        assert(not require('libs/libkoreader-lfs').symlinkattributes(plan.root..'/'..plan.items[1].folder))
        assert(#assert(cache.list(settings,scope.vid,'42',current))==2)
    end
    lease:release()
    print('WEREAD_DIRECT_BATCH='..json.encode{ok=true,mode=input.mode,network_blocked=true});os.exit(0)
end
if input.mode=='presence_repair' or input.mode=='presence_unwritable' then
    assert(dofile(assert(arg[1])..'/spec/koreader/offline_network_guard.lua')())
    local cache=require('weread.lib.native_direct_cache')
    assert(not cache.present(settings,scope.vid,'42'),'invalid presence marker was accepted')
    local old_output
    if input.mode=='presence_unwritable' then
        old_output=package.loaded['weread.lib.notes_export_file']
        package.loaded['weread.lib.notes_export_file']={create=function() return nil end}
    end
    local rows=assert(cache.list(settings,scope.vid,'42',function() return true end));assert(#rows==(input.expected_rows or 3))
    if input.mode=='presence_unwritable' then
        assert(not cache.present(settings,scope.vid,'42'),'failed index write claimed success')
        package.loaded['weread.lib.notes_export_file']=old_output
        rows=assert(cache.list(settings,scope.vid,'42',function() return true end));assert(#rows==3)
    end
    assert(cache.present(settings,scope.vid,'42'),'saved chapters did not repair the presence marker')
    assert(not cache.present(settings,'87654321','42'),'presence escaped its account')
    print('WEREAD_DIRECT_BATCH='..json.encode{ok=true,mode=input.mode,network_blocked=true});os.exit(0)
end
if input.mode=='offline' or input.mode=='offline_locked' or input.mode=='offline_partial' or input.mode=='offline_range' then
    assert(dofile(assert(arg[1])..'/spec/koreader/offline_network_guard.lua')())
    local cache=require('weread.lib.native_direct_cache')
    local rows=assert(cache.list(settings,scope.vid,'42',function() return true end))
    local single=input.mode=='offline_partial' or input.mode=='offline_range'
    assert(#rows==(single and 1 or input.mode=='offline_locked' and 2 or 3))
    assert(cache.present(settings,scope.vid,'42'),'verified chapters missing shelf presence')
    if input.mode=='offline_partial' then
        local lease=assert(cache.acquire(settings,scope.vid,'42'),'cancelled worker kept the book lease')
        lease:release()
    end
    local seen={};local cache_dir
    for _,row in ipairs(rows) do
        local saved,checked=cache.open(settings,scope.vid,'42',row,function() return true end,true)
        assert(saved and checked and checked.file_id==saved.file_id and checked.key==row.key and checked.copy==row.copy
            and checked.catalog_sha256==row.catalog_sha256 and checked.catalog_order==row.catalog_order and not row.file_id,
            'opened file did not return its verified identity and catalog')
        cache_dir=assert(saved.path:match('^(.*)/[^/]+/[^/]+$'))
        local doc=assert(require('document/documentregistry'):openDocument(saved.path))
        assert(doc:loadDocument());doc:setFontFace('Noto Sans');doc:setFontSize(Device.screen:scaleBySize(24));doc:render()
        local hits=assert(doc:findAllText('Chapter '..row.chapter_uid..', synthetic paragraph',false,0,8,false,0))
        assert(hits[1],'saved chapter content did not render');doc:close();seen[row.chapter_uid]=true
    end
    if input.mode=='offline_range' then
        assert(seen['38'] and rows[1].catalog_order==2 and rows[1].catalog_count==3
            and rows[1].catalog_prev=='37' and rows[1].catalog_next=='39','range lost its full catalog position')
    else
        assert(seen['37'] and (seen['38']~=nil)==(input.mode~='offline_partial')
            and (seen['39']~=nil)==(input.mode=='offline'))
    end
    if input.mode=='offline' then
        -- A future cache cleanup and chapter publishing must never overlap.
        local held=assert(cache.acquire(settings,scope.vid,'42'))
        local blocked,reason=cache.acquire(settings,scope.vid,'42')
        assert(not blocked and reason=='busy','concurrent cache operation was not excluded')
        local digest=string.rep('a',64)
        local saved,why=cache.publish(settings,scope.vid,{book_id='42',title='Synthetic',author='Fixture'},
            {chapterUid='51',title='Fixture'},{book_id='42',chapter_uid='51',book_version=1,missing_images=0,
                catalog_sha256=digest,reading_catalog_sha256=digest,source_sha256=digest,source_channel='eink',
                coordinate_source_authoritative=false,xhtml='<p>synthetic</p>',css='',assets={}},function() return true end)
        assert(not saved and why=='storage','publishing ignored an existing cache operation')
        assert(#assert(cache.list(settings,scope.vid,'42',function() return true end))==3,'blocked publisher changed chapters')
        held:release();local resumed=assert(cache.acquire(settings,scope.vid,'42'));resumed:release()

        local function save_capacity_fixture(id,uid,reservation)
            return cache.publish(settings,scope.vid,{book_id=id,title='Synthetic',author='Fixture'},
                {chapterUid=uid,title='Fixture'},{book_id=id,chapter_uid=uid,book_version=1,missing_images=0,
                    catalog_sha256=digest,reading_catalog_sha256=digest,source_sha256=digest,source_channel='eink',
                    coordinate_source_authoritative=false,xhtml='<p>synthetic</p>',css='',assets={}},
                function() return true end,reservation)
        end
        assert(save_capacity_fixture('51','1'))
        local lfs=require('libs/libkoreader-lfs')
        local list_dir,scans=lfs.dir,0
        local dir=assert(cache.book_directory(settings,scope.vid,'51'))
        rawset(lfs,'dir',function(path,...)
            if path==dir then scans=scans+1 end
            return list_dir(path,...)
        end)
        local old_limit=cache.MAX_ENTRIES
        cache.MAX_ENTRIES=2
        local function current() return true end
        local reservation=assert(cache.begin_capacity(settings,scope.vid,'51',current))
        assert(cache.remaining(settings,scope.vid,'51',current,reservation)==1)
        blocked,reason=cache.acquire(settings,scope.vid,'51')
        assert(not blocked and reason=='busy','reservation allowed a concurrent book operation')
        local wrong=save_capacity_fixture('52','1',reservation)
        assert(not wrong and not cache.book_directory(settings,scope.vid,'52'),'reservation crossed book directories')
        local reused=assert(save_capacity_fixture('51','1',reservation))
        assert(reused.reused and cache.remaining(settings,scope.vid,'51',current,reservation)==1)
        local fresh=assert(save_capacity_fixture('51','2',reservation))
        assert(not fresh.reused and cache.remaining(settings,scope.vid,'51',current,reservation)==0)
        assert(not save_capacity_fixture('51','3',reservation),'full reservation allocated another slot')
        reservation.lease:release()
        assert(cache.remaining(settings,scope.vid,'51',current,reservation)==nil and scans==1,
            'reservation rescanned or remained usable after release')
        rawset(lfs,'dir',list_dir)
        assert(cache.remaining(settings,scope.vid,'51',current)==0)
        cache.MAX_ENTRIES=old_limit
        local acquired=assert(cache.acquire(settings,scope.vid,'51'));acquired:release()

        -- The cleanup planner must retain sources referenced by all local time
        -- windows, including unknown legacy records, without creating a DB.
        local Ledger=require('weread.lib.offline_time_store')
        local ledger=Ledger:new(home);local owner=string.rep('a',20);local path=assert(ledger:path(owner))
        local absent=assert(ledger:source_references(owner,'42'))
        assert(not absent.unverified and not next(absent.files) and not io.open(path,'rb'))
        local journal=assert(io.open(path..'-wal','wb'));assert(journal:write('synthetic'));assert(journal:close())
        assert(not ledger:source_references(owner,'42'),'orphaned ledger journal was ignored')
        assert(os.remove(path..'-wal'))
        assert(not ledger:source_references(owner,'042'),'invalid book id was accepted')
        local file_id=string.rep('b',64)
        assert(ledger:begin(owner,{book_id='42',stats_book=1,start_time=100,time_zone='+08:00',
            book_version=1,file_id=file_id,version_source='native_direct'}))
        assert(ledger:begin(owner,{book_id='43',stats_book=2,start_time=100,time_zone='+08:00'}))
        local references=assert(ledger:source_references(owner,'42'))
        assert(references.files[file_id] and not references.unverified,'verified source was not protected')
        references=assert(ledger:source_references(owner,'43'))
        assert(references.unverified,'unverified legacy source was treated as safe')
        local invalid=Ledger:new(home..'/missing-parent')
        assert(not invalid:source_references(owner,'42'),'missing storage was treated as an empty ledger')
        local linked=assert(ledger:path(string.rep('c',20)))
        assert(lfs.link(path,linked,true))
        assert(not ledger:source_references(string.rep('c',20),'42'),'linked ledger was treated as safe')
        assert(os.remove(linked))
        local broken=assert(ledger:path(string.rep('d',20)))
        local old=assert(io.open(broken,'wb'));assert(old:write('not a database'));assert(old:close())
        assert(not ledger:source_references(string.rep('d',20),'42'),'unreadable ledger was treated as safe')

        local protection=require('weread.lib.native_direct_protection')
        local saved_chapter=assert(cache.open(settings,scope.vid,'42',rows[1],function() return true end)).path
        assert(protection.no_sidecars(saved_chapter),'unused chapter incorrectly protected')
        local short_path=home..'/protection.epub'
        local fixture=assert(io.open(short_path,'wb'));assert(fixture:write('synthetic'));assert(fixture:close())
        local docsettings=require('docsettings')
        for _,location in ipairs({'doc','dir','hash'}) do
            local sidecar=docsettings:getSidecarDir(short_path,location)
            assert(require('util').makePath(sidecar))
            assert(protection.no_sidecars(short_path)==false,'sidecar was missed: '..location)
            assert(lfs.rmdir(sidecar))
        end
        local history=docsettings:getHistoryPath(short_path)
        assert(require('util').makePath(assert(history:match('^(.*)/[^/]+$'))))
        for _,sidecar in ipairs({history,history..'.old',short_path..'.kpdfview.lua'}) do
            local file=assert(io.open(sidecar,'wb'));assert(file:write('synthetic'));assert(file:close())
            assert(protection.no_sidecars(short_path)==false,'legacy sidecar was missed')
            assert(os.remove(sidecar))
        end
        assert(protection.no_sidecars(short_path),'removed fixture sidecars were not cleared')
        assert(not protection.no_sidecars(home..'/missing.epub'),'missing chapter was treated as safe')
    end
    local lfs=require('libs/libkoreader-lfs')
    if input.mode=='offline' then
        local remaining_before=assert(cache.remaining(settings,scope.vid,'42',function() return true end))
        local fake_entries={}
        for index=1,138 do
            local path=cache_dir..'/capacity-fixture-'..index
            assert(lfs.mkdir(path));fake_entries[index]=path
        end
        local calls=0
        local function counted()
            calls=calls+1;return true
        end
        local room=cache.remaining(settings,scope.vid,'42',counted)
        assert(room==remaining_before-#fake_entries,'capacity scan ignored directory entries')
        assert(calls==2+math.floor((cache.MAX_ENTRIES-room)/32),'capacity scan repeated authorization checks')
        for _,expired_at in ipairs({1,3,calls}) do
            local checked=0
            local cancelled=cache.remaining(settings,scope.vid,'42',function()
                checked=checked+1;return checked<expired_at
            end)
            assert(cancelled==nil and checked==expired_at,'capacity scan accepted a changed account')
        end
        calls=0
        local listed=assert(cache.list(settings,scope.vid,'42',counted))
        assert(#listed==#rows,'metadata scan included non-chapter entries')
        for index,entry in ipairs(listed) do
            local expected=rows[index]
            assert(entry.key==expected.key and entry.copy==expected.copy
                and entry.catalog_sha256==expected.catalog_sha256,'metadata scan changed chapter order or catalog')
        end
        assert(calls==2+math.floor((cache.MAX_ENTRIES-room)/32),'metadata scan repeated authorization checks')
        for _,expired_at in ipairs({1,3,calls}) do
            local checked=0
            local cancelled=cache.list(settings,scope.vid,'42',function()
                checked=checked+1;return checked<expired_at
            end)
            assert(cancelled==nil and checked==expired_at,'metadata scan returned rows for a changed account')
        end
        local function current() return true end
        assert(rows[1].chapter_uid=='37' and rows[2].chapter_uid=='38')
        local source=assert(cache.open(settings,scope.vid,'42',rows[1],current))
        local target=assert(cache.open(settings,scope.vid,'42',rows[2],current))
        local source_dir=assert(source.path:match('^(.*)/[^/]+$'))
        local unrelated=source_dir..assert(target.path:match('(/[^/]+)$'))
        local file=assert(io.open(unrelated,'wb'));assert(file:write('synthetic'));assert(file:close())
        local selected=assert(cache.list(settings,scope.vid,'42',current,'38'))
        assert(#selected==1 and selected[1].key==rows[2].key and selected[1].copy==rows[2].copy
            and selected[1].catalog_sha256==rows[2].catalog_sha256,'chapter lookup trusted the filename over metadata')
        assert(os.remove(unrelated))
        local open,catalog_reads=io.open,0
        rawset(io,'open',function(path,...)
            if path:match('/catalog%.txt$') then catalog_reads=catalog_reads+1 end
            return open(path,...)
        end)
        local subset=cache.list(settings,scope.vid,'42',current,{['37']=true,['39']=true})
        rawset(io,'open',open)
        assert(catalog_reads==2,'range lookup read unrelated catalog records')
        assert(subset and #subset==2 and subset[1].key==rows[1].key and subset[2].key==rows[3].key
            and subset[2].catalog_sha256==rows[3].catalog_sha256,'range lookup returned the wrong copies or order')
        local entry_path=source_dir..'/entry.txt'
        local original=assert(io.open(entry_path,'rb'));local bytes=assert(original:read('*a'));assert(original:close())
        local corrupt=assert(io.open(entry_path,'wb'));assert(corrupt:write((bytes:gsub('title=','title=Changed ',1))))
        assert(corrupt:close())
        local checked=cache.list(settings,scope.vid,'42',current,{['37']=true,['39']=true})
        original=assert(io.open(entry_path,'wb'));assert(original:write(bytes));assert(original:close())
        assert(checked and #checked==1 and checked[1].key==rows[3].key,'range lookup accepted a changed entry')
        assert(#assert(cache.list(settings,scope.vid,'42',current,{}))==0,'empty selection returned cached chapters')
        assert(#assert(cache.list(settings,scope.vid,'42',current,'99'))==0,'missing chapter found a copy')
        assert(cache.list(settings,scope.vid,'42',current,'../38')==nil,'invalid chapter selector was accepted')
        assert(cache.list(settings,scope.vid,'42',function() return false end,'38')==nil,
            'chapter lookup returned rows for a changed account')
        for _,path in ipairs(fake_entries) do assert(lfs.rmdir(path)) end
    end
    cache.MAX_ENTRIES=3
    local added={}
    for index=1,4-#rows do
        local path=cache_dir..'/synthetic-damaged-'..index
        assert(lfs.mkdir(path));added[#added+1]=path
        local remaining=cache.remaining(settings,scope.vid,'42',function() return true end)
        if index==4-#rows then
            assert(remaining==nil,'overfull cache accepted')
            assert(cache.list(settings,scope.vid,'42',function() return true end)==nil,'overfull metadata list accepted')
            assert(cache.list(settings,scope.vid,'42',function() return true end,rows[1].chapter_uid)==nil,
                'targeted lookup ignored the metadata scan limit')
            assert(cache.list(settings,scope.vid,'42',function() return true end,{[rows[1].chapter_uid]=true})==nil,
                'range lookup ignored the metadata scan limit')
        else assert(remaining==3-#rows-index,'incorrect cache capacity') end
    end
    for _,path in ipairs(added) do assert(lfs.rmdir(path)) end
    print('WEREAD_DIRECT_BATCH='..json.encode{ok=true,mode=input.mode,network_blocked=true});os.exit(0)
end
local client=require('weread.lib.client'):new(settings)
local host={settings=settings,client=client,discovery_epoch=1,_reader_session_gen=1,
    library_db={accountKey=function() return 'synthetic' end,getChapters=function() return {} end},ui={},
    isNetworkConnected=function() return true end,
    showBusy=function(self,label,cancel)
        self.busy_message=require('ui/widget/infomessage'):new{text=label,callback=cancel};UI:show(self.busy_message)
    end,
    closeBusy=function(self) UI:close(self.busy_message);self.busy_message=nil end,
    showInfo=function(self,message) self.message=message end,
    showOffline=function() error('unexpected offline') end,
    showList=require('weread.ui.common').showList,showBookMenu=require('weread.ui.library').showBookMenu,
    getFullBookCachePath=function() return home..'/missing.epub' end,bookRecordHasDownload=function() return false end,
    safeCallback=function(_,_,callback) return callback end,openFile=function() error('batch unexpectedly opened reader') end}
if input.mode=='catalog_capture' then
    settings.get=function(_,key,default) if key=='account' then return {user_vid=scope.vid} end return default end
    host.library_db=require('weread.lib.library_db'):new(settings)
end
host:showBookMenu({book_id='42',title='Synthetic',author='Fixture',chapters={}})
local view=assert(host._book_detail_view);local action
for _,button in ipairs(view._action_buttons) do
    if button.text==require('weread.lib.plugin_util').tr('Download E-Ink chapters') then action=button end
end
assert(action);action.callback()
pump(function() return host._native_direct_reading and host._native_direct_reading.confirm end)
local confirm=host._native_direct_reading.confirm
local range_mode=input.mode=='range' or input.mode=='range_repeat' or input.mode=='range_cancel'
if range_mode then
    G_reader_settings:saveSetting('items_per_page',2)
    local ctx=host._native_direct_reading
    confirm.choice1_callback();UI:close(confirm)
    local start=assert(ctx.menu)
    assert(start.page_num==2 and start.item_table[3].select_enabled)
    start:onGotoPage(2);UI:forceRePaint();start:onMenuSelect(start.item_table[3])
    local ending=assert(ctx.menu)
    assert(ending~=start and ending.page==2)
    ending:onGotoPage(1);UI:forceRePaint();ending:onMenuSelect(ending.item_table[2])
    confirm=assert(ctx.confirm)
    assert(not host._native_direct_worker.job and ctx.phase=='catalog')
end
if input.mode=='catalog_capture' then
    local cache=require('weread.lib.native_direct_cache')
    local rows=assert(cache.list(settings,scope.vid,'42',function() return true end));assert(#rows==3)
    local entry=rows[1];entry.file_id=assert(cache.open(settings,scope.vid,'42',entry,function() return true end)).file_id
    local catalog_store=require('weread.lib.native_direct_catalog_store')
    local saved=assert(catalog_store.read(host.library_db,settings,client,scope,entry,function() return true end))
    assert(catalog_store.estimate(saved,entry,50)>0,
        'production chapter catalog was not saved for local progress')
    local old_scope=scope;scope={vid='87654321',epoch=2}
    assert(not catalog_store.read(host.library_db,settings,client,scope,entry,function() return true end),
        'another account read this catalog')
    scope=old_scope
    local original=host._native_direct_reading.catalog
    local changed={book_id=original.book_id,version=original.version,reading_digest=original.reading_digest,chapters={}}
    for index,row in ipairs(original.chapters) do
        changed.chapters[index]={};for key,value in pairs(row) do changed.chapters[index][key]=value end
    end
    changed.chapters[1].wordCount=changed.chapters[1].wordCount+1
    local checks=0
    assert(not catalog_store.save(host.library_db,settings,client,scope,changed,function()
        checks=checks+1;return checks<3
    end),'stale catalog was committed')
    local restored=assert(catalog_store.read(host.library_db,settings,client,scope,entry,function() return true end))
    assert(restored.chapters[1].words==saved.chapters[1].words,'failed save changed the stored catalog')
    confirm.cancel_callback();UI:close(confirm)
    assert(not host._native_direct_reading and not host.busy_message)
elseif input.mode=='cancel' or input.mode=='range_cancel' then
    confirm.cancel_callback();UI:close(confirm)
    assert(not host._native_direct_reading and not host.busy_message)
elseif input.mode=='stale' then
    scope={vid='87654321',epoch=2}
    confirm.choice2_callback();UI:close(confirm)
    assert(not host._native_direct_reading and not host.busy_message,'old confirmation started after account change')
else
    if range_mode then confirm.ok_callback() else confirm.choice2_callback() end
    UI:close(confirm)
    if input.mode=='cancel_running' then
        pump(function()
            local ctx=host._native_direct_reading;local file=io.open(home..'/hold','rb')
            if file then file:close() end
            return ctx and (ctx.batch_progress or -1)>=33 and file~=nil
        end)
        local ctx=host._native_direct_reading
        local lease,reason=require('weread.lib.native_direct_cache').acquire(settings,scope.vid,'42')
        assert(not lease and reason=='busy','running batch did not retain its capacity lease')
        ctx.busy.buttons[1][1].callback()
        assert(not host._native_direct_reading and not host.busy_message)
        print('WEREAD_DIRECT_BATCH='..json.encode{ok=true,mode=input.mode});os.exit(0)
    end
    pump(function() return host.message~=nil end)
    local text=host.message
    if input.mode=='fail' then
        assert(text==require('weread.lib.plugin_util').tr('WeRead is limiting requests. Completed chapters were kept; try again later.'))
    else
        local T=require('weread.lib.plugin_util').T;local tr=require('weread.lib.plugin_util').tr
        local template=tr('E-Ink chapters ready: %1 downloaded, %2 already saved, %3 unavailable. %4 chapters have missing images.')
        local downloaded=input.mode=='resume' and '2' or input.mode=='locked' and '2'
            or (input.mode=='cleanup_redownload' or input.mode=='range') and '1' or '0'
        local saved=(input.mode=='resume' or input.mode=='range_repeat') and '1'
            or (input.mode=='locked' or input.mode=='range') and '0' or input.mode=='cleanup_redownload' and '2' or '3'
        assert(text==T(template,downloaded,saved,(input.mode=='locked' or range_mode) and '1' or '0','0'),text)
    end
    assert(not host._native_direct_reading and not host.busy_message)
end
print('WEREAD_DIRECT_BATCH='..json.encode{ok=true,mode=input.mode})
