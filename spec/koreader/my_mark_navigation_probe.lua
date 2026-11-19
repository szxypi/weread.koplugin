-- Actual PluginLoader, FileManager/ReaderUI, native button and source navigator.
-- Private input and diagnostics use anonymous pipes; profiles must be tmpfs.
require('ffi').log=function() end
require('setupkoenv')
local ffi,json=require('ffi'),require('json');require('ffi/posix_h')
local mode=arg[1]
local report={result='UNVERIFIED',mode=mode,phase='init',failed_line=0,requests=0,located=0,buttons=0,
    native_filemanager=false,native_reader=false,archive_worker=false,heartbeat=false,exact_targets=false,
    workers_reaped=false,credential_audit=false,source_files=0,screenshots=0}
local descriptors,workers={},{};local counters,memory,plugin,reader,latest_cookies
local downloading=false
local ok,reason=pcall(function()
    local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/weread%-marknav%-[%w_]+/profile$'))
    assert(mode=='live' or mode=='reopen')
    local raw=assert(io.stdin:read(12*1024*1024+1));assert(#raw<=12*1024*1024)
    local input=json.decode(raw);assert(type(input.chapters)=='table' and #input.chapters>0 and #input.chapters<=8)
    downloading=input.download_missing==true;assert(downloading==(os.getenv('WEREAD_NOTE_DOWNLOAD')=='1'))
    if downloading then
        assert(type(input.cookies)=='table' and input.cookies.wr_vid == input.owner);latest_cookies=input.cookies
        for _i,key in ipairs({'missing_cache','download_confirmed','cancel_zero_requests','downloaded_source_verified','no_data_posts'}) do report[key]=false end
        for _i,key in ipairs({'confirmations','downloaded_chapters','http_gets','catalog_posts','content_posts','forbidden_requests','http_failures'}) do report[key]=0 end
    end
    local thoughts=input.variant=='thoughts';assert(thoughts==(os.getenv('WEREAD_MARKNAV_VARIANT')=='thoughts'))
    local bookmarks=input.variant=='bookmarks';assert(bookmarks==(os.getenv('WEREAD_MARKNAV_VARIANT')=='bookmarks'))
    local personal=os.getenv('WEREAD_PERSONAL_DISPLAY')=='1';assert(not personal or not thoughts and not downloading)
    if personal then
        report.personal_display=false;report.personal_native_text=false;report.personal_spans=0
        report.personal_position_notes_unchanged=false;report.personal_file_unchanged=false
    end
    local synthetic=os.getenv('WEREAD_MARKNAV_SYNTHETIC')=='1'
    assert((input.synthetic==true)==synthetic)
    if synthetic then assert(input.owner=='900000' and (input.book_id=='900001' or input.book_id=='CB_SyntheticNotes')) end
    G_defaults=require('luadefaults'):open();G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
    G_reader_settings:saveSetting('language','zh_CN');G_reader_settings:saveSetting('flash_ui',false)
    G_reader_settings:saveSetting('color_rendering',false);G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
    require('gettext').changeLang('zh_CN')
    local Device=require('device');require('document/canvascontext'):init(Device)
    local screen_shot=Device.screen.shot
    Device.screen.shot=function(self,path)
        assert(synthetic and os.getenv('WEREAD_MARKNAV_SHOTS') and type(path)=='string'
            and path:sub(1,#os.getenv('WEREAD_MARKNAV_SHOTS')+1)==os.getenv('WEREAD_MARKNAV_SHOTS')..'/')
        report.screenshots=report.screenshots+1;return screen_shot(self,path)
    end
    local function shot(name)
        if synthetic and os.getenv('WEREAD_MARKNAV_SHOTS') then Device.screen:shot(os.getenv('WEREAD_MARKNAV_SHOTS')..'/'..mode..'-'..name..'.png') end
    end
    local Network=require('ui/network/manager');Network.isOnline=function() return downloading and mode=='live' end;Network.isConnected=Network.isOnline
    package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
    pcall(ffi.cdef,'int memfd_create(const char *, unsigned int); void *mmap(void *, unsigned long, int, int, int, long); int munmap(void *, unsigned long);')
    local function anonymous(data)
        local fd=tonumber(ffi.C.memfd_create('weread-mark-navigation',1));assert(fd>=0);descriptors[#descriptors+1]=fd
        local bytes='return '..require('dump')(data,nil,true);local offset=0
        while offset<#bytes do local n=tonumber(ffi.C.write(fd,ffi.cast('const char *',bytes)+offset,#bytes-offset));assert(n>0);offset=offset+n end
        return '/proc/self/fd/'..fd
    end
    local auth={auth_schema_version=1,auth_epoch=1,account={user_vid=input.owner,name=''},cookies=latest_cookies or {},api_key=''}
    local auth_path=anonymous(auth)
    local Settings=require('weread.lib.settings');local new=Settings.new
    function Settings:new()
        local value=new(self);assert(not value.mock_endpoint)
        if downloading and synthetic then
            assert(type(input.mock_endpoint)=='string' and input.mock_endpoint:match('^http://127%.0%.0%.1:%d+$'))
            value.mock_endpoint=input.mock_endpoint
        end
        local flush=value.store.flush
        value.store.flush=function(store,...)
            local held={};local secrets={'account','cookies','api_key','wr_ticket','wr_wrpa','device_fingerprint'}
            for _i,key in ipairs(secrets) do held[key]=store.data[key];store.data[key]=nil end
            local result={pcall(flush,store,...)}
            for _i,key in ipairs(secrets) do store.data[key]=held[key] end
            if downloading then latest_cookies=held.cookies end
            assert(result[1]);return unpack(result,2)
        end
        for key,item in pairs(auth) do value.store:saveSetting(key,key=='cookies' and latest_cookies or item) end
        value.settings_file=auth_path
        local sync=value:get('sync');sync.pull_on_open=false;sync.upload_on_close=false;sync.upload_interval_minutes=0;value:set('sync',sync)
        local reporting=value:get('read_report');reporting.enabled=false;value:set('read_report',reporting)
        local cache=value:get('cache');cache.download_book_images=false;cache.download_underlines_and_thoughts=false;cache.auto_prefetch_next_chapter=false;value:set('cache',cache)
        return value
    end
    memory=ffi.C.mmap(nil,4096,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1));counters=ffi.cast('int *',memory)
    local navigation_reason,dom_reason,dom_phase,active_anchor
    local extracted,full_match,prefix_match=0,false,false
    local actual_contains_expected,expected_contains_actual,same_byte_length,same_first_scalar,same_last_scalar=false,false,false,false,false
    local Navigation=require('weread.lib.source_navigation');local finish_navigation=Navigation._finish
    function Navigation:_finish(job,position,why)
        if not position then navigation_reason=why end
        return finish_navigation(self,job,position,why)
    end
    local SourceDom=require('weread.lib.source_dom');local open_dom=SourceDom.open_prepared
    function SourceDom.open_prepared(...)
        local index,why=open_dom(...)
        if not index then dom_reason=why;return index,why end
        local locate=index.locate_anchor
        local endpoints=index._endpoints
        local checkpoint=index._page_checkpoint
        local extract=index._extract
        index._extract=function(self,...)
            local text=extract(self,...)
            if dom_phase=='verification' and active_anchor then
                extracted=extracted+1
                local normalized=SourceDom.normalize(text)
                if extracted==1 then
                    full_match=normalized==active_anchor.text
                    actual_contains_expected=normalized:find(active_anchor.text,1,true)~=nil
                    expected_contains_actual=#normalized>0 and active_anchor.text:find(normalized,1,true)~=nil
                    same_byte_length=#normalized==#active_anchor.text
                    local function scalars(value)
                        local first,last
                        for scalar in value:gmatch('[%z\1-\127\194-\244][\128-\191]*') do first=first or scalar;last=scalar end
                        return first,last
                    end
                    local actual_first,actual_last=scalars(normalized);local expected_first,expected_last=scalars(active_anchor.text)
                    same_first_scalar=actual_first~=nil and actual_first==expected_first
                    same_last_scalar=actual_last~=nil and actual_last==expected_last
                elseif extracted==2 then
                    prefix_match=normalized==require('weread.lib.protocol').utf8_substr(active_anchor.text,active_anchor.point_offset)
                end
            end
            return text
        end
        index._endpoints=function(self,...)
            dom_phase='endpoints'
            local a,b,c=endpoints(self,...)
            dom_phase='verification'
            return a,b,c
        end
        index._page_checkpoint=function(self,...)
            dom_phase='checkpoint'
            local value=checkpoint(self,...)
            dom_phase='endpoints'
            return value
        end
        index.locate_anchor=function(self,anchor)
            dom_phase='verification';active_anchor=anchor;extracted,full_match,prefix_match=0,false,false
            local point,reason_=locate(self,anchor)
            if not point then dom_reason=reason_ end
            return point,reason_
        end
        return index,why
    end
    local Client=require('weread.lib.client')
    if downloading then
        local fixtures=assert(debug.getinfo(1,'S').source:match('^@(.*/)'))
        local gate=dofile(fixtures..'note_download_transport.lua'):new(input,mode,counters,tonumber(ffi.C.getpid()))
        gate:install(Client)
    else Client.request=function() counters[0]=counters[0]+1;error('all network requests forbidden',0) end end
    local Worker=require('weread.lib.memory_worker');local start=Worker.start
    function Worker:start(...)
        local result={start(self,...)}
        if self.job then workers[#workers+1]={pid=self.job.pid,runner=self.runner};report.archive_worker=true end
        return unpack(result)
    end
    local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
    for _i,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
    assert(#Loader.enabled_plugins==1)
    local FM=require('apps/filemanager/filemanager');FM:showFiles(home);plugin=assert(FM.instance.weread)
    report.native_filemanager=not plugin.ui.document
    local UI,socket=require('ui/uimanager'),require('socket')
    local function tick() UI:setInputTimeout(0);UI:handleInput();socket.sleep(.005) end
    local function wait(predicate,seconds,on_timeout)
        local deadline=socket.gettime()+(seconds or 75)
        while not predicate() do
            local top=on_timeout and UI:getTopmostVisibleWidget()
            if top and (top.text==require('weread.lib.plugin_util').tr('Could not locate this highlight in the original text. Try downloading the chapter again.')
                or top.text==require('weread.lib.plugin_util').tr('Could not locate this thought quote in the original text. Try downloading the chapter again.')) then
                on_timeout();error('navigation unavailable',0)
            end
            if socket.gettime()>=deadline then if on_timeout then on_timeout() end;error('navigation deadline',0) end
            tick()
        end
    end
    local Content=require('weread.lib.content');local Source=require('weread.lib.position_source');local Identity=require('weread.lib.book_file_identity')
    local id=input.book_id;local book=plugin.settings:get_book(id)
    if mode=='live' and downloading then
        book={book_id=id,bookId=id,title='所选书籍',bookVersion=0,cached_chapters={},chapters={}}
        local books=plugin.settings:get('books',{});books[id]=book;plugin.settings:set('books',books);plugin.settings:flush()
        assert(not plugin:bookRecordHasDownload(book));report.missing_cache=true
        assert(require('weread.lib.my_cloud_marks_store'):new(plugin.library_db,plugin.client,thoughts and 'thoughts' or nil):write(input.model))
    elseif mode=='live' then
        local chapters,bodies,sources={},{},{}
        book={book_id=id,bookId=id,title='所选书籍',bookVersion=0,cached_chapters={}}
        for index,sample in ipairs(input.chapters) do
            local uid=sample.chapter_uid;chapters[index]={chapterUid=uid,chapterIdx=index,title='章节 '..index,wordCount=1000}
            local format=sample.format or 'web_xhtml'
            assert(format=='web_xhtml' or format=='web_txt')
            bodies[uid]=format=='web_txt' and Content.txt_to_xhtml(sample.raw) or sample.raw
            sources[uid]=assert(Source.capture(book,chapters[index],sample.raw,format))
        end
        book.chapters=chapters
        book.cached_full_book=Content.save_book_epub(plugin.settings,book,chapters,bodies,'navigation-full',{},nil,nil,Identity.capture(book),sources)
        report.source_files=1
        for index,chapter in ipairs(chapters) do
            local path=Content.save_book_epub(plugin.settings,book,{chapter},bodies,'navigation-'..index,{},nil,nil,Identity.capture(book),sources)
            book.cached_chapters[tostring(chapter.chapterUid)]=path;report.source_files=report.source_files+1
        end
        assert(Content.save_catalog_cache(plugin.client,plugin.settings,book,chapters))
        local books=plugin.settings:get('books',{});books[id]=book;plugin.settings:set('books',books);plugin.settings:flush()
        assert(require('weread.lib.my_cloud_marks_store'):new(plugin.library_db,plugin.client,thoughts and 'thoughts' or nil):write(input.model))
    elseif downloading then
        assert(book and not book.cached_full_book and type(book.cached_chapters)=='table')
        report.source_files=#input.chapters
    else
        assert(book and book.cached_full_book);book.cached_chapters={};book.cached_file=nil
        local books=plugin.settings:get('books',{});books[id]=book;plugin.settings:set('books',books);plugin.settings:flush();report.source_files=#input.chapters+1
    end
    local tr=require('weread.lib.plugin_util').tr
    local Target=require(thoughts and 'weread.lib.my_thought_target' or bookmarks and 'weread.lib.my_bookmark_target' or 'weread.lib.my_mark_target')
    local function note_id(row) return thoughts and row.reviewId or row.bookmarkId end
    local expected={}
    for _i,sample in ipairs(input.chapters) do
        for index,row in ipairs(sample.rows) do
            local target=assert(Target.project(sample.raw,id,sample.chapter_uid,row,sample.format))
            assert(target.chapter_offset==sample.targets[index].chapter_offset and target.raw_sha256==sample.targets[index].raw_sha256)
            expected[note_id(row)]=target
        end
    end
    local entries={}
    for _i,row in ipairs(thoughts and input.model.reviews or input.model.updated) do if expected[note_id(row)] then entries[#entries+1]=row end end
    assert(#entries>0)
    if mode=='reopen' then local reversed={};for index=#entries,1,-1 do reversed[#reversed+1]=entries[index] end;entries=reversed end
    report.phase='navigate'
    local downloaded={}
    local function file_bytes(path) local f=assert(io.open(path,'rb'));local bytes=f:read('*a');f:close();return bytes end
    for _i,row in ipairs(entries) do
        local requests_before=tonumber(counters[0]);local uid=tostring(row.chapterUid)
        if not reader then
            plugin:showBookMenu(book)
            local detail=assert(plugin._book_detail_view);local entry
            for _j,button in ipairs(detail._action_buttons) do if button.text==tr(thoughts and 'My cloud thoughts' or bookmarks and 'My cloud bookmarks' or 'My cloud highlights') then entry=button end end
            assert(entry);entry.callback()
        else assert(require('weread.ui.my_cloud_marks').show(plugin,id,thoughts and 'thoughts' or bookmarks and 'bookmarks' or nil)) end
        local owner=assert(plugin._my_marks_owner);assert(not owner.context)
        local menu=owner.menu;local index
        for at,item in ipairs(menu.item_table) do if item.my_note_id==note_id(row) then index=at end end
        assert(index);menu:onGotoPage(menu:getPageNumber(index));menu:onMenuSelect(menu.item_table[index]);UI:forceRePaint()
        local popup=assert(menu._shelf_popup);local button=assert(popup.button_table:getButtonById(thoughts and 'open_thought_quote' or bookmarks and 'open_bookmark' or 'open_highlight'))
        if _i==1 then shot('highlight') end
        if downloading then
            button:onTapSelectButton()
            if mode=='live' and not downloaded[uid] then
                wait(function() return owner.navigation and owner.navigation.confirm end)
                local confirm=owner.navigation.confirm;UI:forceRePaint()
                assert(counters[0]==requests_before)
                if report.confirmations==0 then
                    assert(requests_before==0);shot('download-confirm')
                    confirm.cancel_callback();UI:close(confirm);assert(not owner.navigation and counters[0]==0)
                    report.cancel_zero_requests=true
                    button:onTapSelectButton();wait(function() return owner.navigation and owner.navigation.confirm end)
                    confirm=owner.navigation.confirm;UI:forceRePaint()
                end
                counters[5]=1;report.confirmations=report.confirmations+1;confirm.ok_callback();downloaded[uid]=true
            end
        elseif synthetic and _i==1 then
            local resolve=Target.resolve
            Target.resolve=function(...) socket.sleep(.8);return resolve(...) end
            button:onTapSelectButton()
            local active=assert(owner.navigation);local busy=assert(plugin.busy_message)
            local old_dismiss=assert(busy.dismiss_callback)
            wait(function() return active.worker.job~=nil end)
            local child=active.worker.job.pid
            busy:onTapClose()
            assert(not owner.navigation and not require('apps/reader/readerui').instance)
            wait(function() return require('ffi/util').isSubProcessDone(child) end)
            Target.resolve=resolve
            button:onTapSelectButton()
            local replacement=assert(owner.navigation)
            old_dismiss()
            assert(owner.navigation==replacement,'old busy action cancelled new lookup')
        else button:onTapSelectButton() end
        assert(button.text==tr(thoughts and 'Open thought quoted text' or bookmarks and 'Open bookmark position' or 'Open highlighted text'));report.buttons=report.buttons+1
        local beat=false;UI:scheduleIn(.1,function() beat=true end)
        wait(function()
            reader=require('apps/reader/readerui').instance
            if reader and reader.weread then plugin=reader.weread end
            local held=reader and plugin.progress_sync:current_source_target()
            local target=expected[note_id(row)]
            return beat and not owner.navigation and reader and plugin.source_navigation.state=='ready'
                and held and held.chapter_uid==target.chapter_uid and held.chapter_offset==target.chapter_offset
        end,nil,function()
            local current=require('apps/reader/readerui').instance
            local active=current and current.weread or plugin
            local top=UI:getTopmostVisibleWidget()
            report.diagnostic={reader_open=current~=nil,owner_navigating=owner.navigation~=nil,
                busy_visible=active.busy_message~=nil,target_present=active.progress_sync:current_source_target()~=nil,
                source_ready=active.source_navigation and active.source_navigation.state=='ready' or false,
                error_visible=top and top.text==tr('Could not locate this highlight in the original text. Try downloading the chapter again.') or false,
                finish_target_unavailable=navigation_reason=='target_unavailable',
                finish_navigation_unavailable=navigation_reason=='navigation_unavailable',finish_target_changed=navigation_reason=='target_changed',
                finish_other=navigation_reason~=nil and navigation_reason~='target_unavailable'
                    and navigation_reason~='navigation_unavailable' and navigation_reason~='target_changed',
                dom_anchor_missing=dom_reason=='source_dom/anchor_missing',dom_anchor_ambiguous=dom_reason=='source_dom/anchor_ambiguous',
                dom_walk_diverged=dom_reason=='source_dom/walk_diverged',dom_other=dom_reason~=nil and dom_reason~='source_dom/anchor_missing'
                    and dom_reason~='source_dom/anchor_ambiguous' and dom_reason~='source_dom/walk_diverged',
                dom_failed_endpoints=dom_phase=='endpoints',dom_failed_checkpoint=dom_phase=='checkpoint',
                dom_failed_verification=dom_phase=='verification',dom_full_returned=extracted>=1,dom_full_match=full_match,
                dom_prefix_returned=extracted>=2,dom_prefix_match=prefix_match,
                dom_actual_contains_expected=actual_contains_expected,dom_expected_contains_actual=expected_contains_actual,
                dom_same_byte_length=same_byte_length,dom_same_first_scalar=same_first_scalar,dom_same_last_scalar=same_last_scalar}
        end)
        report.heartbeat=true;report.native_reader=reader.document~=nil
        local anchor=assert(plugin.progress_sync.source_anchor)
        assert(reader.document:isXPointerInCurrentPage(anchor.xpointer))
        local point=assert(plugin.source_position:current());assert(point.upload_verified==false and point.retained_source_target)
        local snapshot=assert(Source.document_metadata(reader.document,id,point.chapter_uid,point.render_path))
        assert(snapshot.record.raw_sha256==expected[note_id(row)].raw_sha256)
        assert(not plugin.progress_sync.verified and not plugin.read_report.job)
        if downloading then
            counters[5]=0
            if mode=='live' and tonumber(counters[0])>requests_before then
                report.downloaded_chapters=report.downloaded_chapters+1
                local record=assert(plugin.settings:get_book(id));local path=assert(record.cached_chapters[uid])
                assert(path==reader.document.file and not record.cached_full_book);report.source_files=report.source_files+1
            else assert(tonumber(counters[0])==requests_before) end
        else assert(counters[0]==0) end
        if personal then
            local origin=reader.document:getXPointer();local native_notes=json.encode(reader.annotation.annotations)
            local bytes=file_bytes(reader.document.file)
            wait(function() return plugin._personal_marks and plugin._personal_marks.complete end)
            local s=plugin._personal_marks;local own
            for _j,record in ipairs(bookmarks and s.bookmarks or s.records) do if record.bookmarkId==row.bookmarkId then own=record;break end end
            assert(own)
            if bookmarks then
                assert(not own.pos1 and reader.document:compareXPointers(own.pos0,anchor.xpointer)==0)
            else
                local text=reader.document:getTextFromXPointers(own.pos0,own.pos1);reader.document:clearSelection()
                local Dom=require('weread.lib.source_dom')
                assert(Dom.normalize(text)==Dom.normalize(row.markText))
            end
            assert(reader.document:getXPointer()==origin and json.encode(reader.annotation.annotations)==native_notes)
            assert(file_bytes(reader.document.file)==bytes)
            UI:forceRePaint();assert(bookmarks and s.indicator.enabled or not bookmarks and s.overlay.enabled)
            local box
            if bookmarks then
                for _j,entry in ipairs(s.indicator.visible) do if entry.bookmarkId==row.bookmarkId then box=s.indicator.rect;break end end
            else
                for _j,entry in ipairs(s.overlay.visible) do if entry.record.bookmarkId==row.bookmarkId then box=entry.rect;break end end
            end
            assert(box)
            if synthetic and _i==1 then
                assert(plugin:_onXPointerOverlayTap{pos={x=box.x+box.w/2,y=box.y+box.h/2}},'personal highlight tap was not routed')
                local tapped=assert(plugin._my_marks_owner);assert(tapped.menu._shelf_popup,'personal highlight detail was not opened')
                require('weread.ui.my_cloud_marks').cancel(plugin)
            end
            report.personal_spans=report.personal_spans+1
        end
        UI:forceRePaint();report.located=report.located+1
        if _i==1 then shot('located') end
    end
    report.exact_targets=true;report.phase='close'
    if personal then
        assert(report.personal_spans==#entries)
        report.personal_display=true;report.personal_native_text=true;report.personal_position_notes_unchanged=true;report.personal_file_unchanged=true
    end
    plugin:closeWeReadUI();if reader then reader:onClose() end
    plugin.settings:flush();G_reader_settings:flush()
    for _i,worker in ipairs(workers) do wait(function() return worker.runner.done(worker.pid) end) end
    report.workers_reaped=true
    local lfs=require('libs/libkoreader-lfs')
    local function audit(dir)
        for entry in lfs.dir(dir) do
            if entry~='.' and entry~='..' and not (dir==home and entry=='plugins') then
                local path=dir..'/'..entry;local stat=assert(lfs.symlinkattributes(path))
                if stat.mode=='directory' then audit(path) else
                    assert(stat.mode=='file' and stat.size<=16*1024*1024)
                    if downloading then
                        local file=assert(io.open(path,'rb'));local bytes=file:read('*a');file:close()
                        -- Short status flags (e.g. wr_ql=0) are not secret
                        -- tokens. The verified login key is at least 8 bytes.
                        for key,value in pairs(input.cookies) do if key~='wr_vid' and #value>=8 then assert(not bytes:find(value,1,true)) end end
                        for key,value in pairs(latest_cookies) do if key~='wr_vid' and #value>=8 then assert(not bytes:find(value,1,true)) end end
                    end
                end
            end
        end
    end
    audit(home);report.credential_audit=true
    if downloading then
        assert(counters[4]==0 and counters[6]==0)
        report.download_confirmed=mode=='live' and report.confirmations==#input.chapters
        report.downloaded_source_verified,report.no_data_posts=true,true
    else assert(counters[0]==0) end
    report.result,report.phase='PASS','complete'
end)
if not ok then report.failed_line=tonumber(type(reason)=='string' and reason:match('my_mark_navigation_probe%.lua:(%d+):')) or 0 end
if plugin then pcall(plugin.closeWeReadUI,plugin) end
if counters then
    report.requests=tonumber(counters[0])
    if downloading then report.http_gets,report.catalog_posts,report.content_posts,report.forbidden_requests,report.http_failures=tonumber(counters[1]),tonumber(counters[2]),tonumber(counters[3]),tonumber(counters[4]),tonumber(counters[6]) end
    ffi.C.munmap(memory,4096)
end
for _i,fd in ipairs(descriptors) do ffi.C.close(fd) end
io.write('\nWEREAD_MY_MARK_NAVIGATION_RESULT='..json.encode(downloading and {report=report,cookies=latest_cookies} or report)..'\n')
os.exit(ok and 0 or 1)
