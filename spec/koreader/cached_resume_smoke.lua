-- Normal plugin selection with multiple real cached chapter files and a full
-- download. All traffic uses the isolated synthetic HTTP server.
require('setupkoenv')
local home,evidence=assert(os.getenv('KO_HOME')),assert(os.getenv('WEREAD_EVIDENCE'))
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
G_reader_settings:saveSetting('language','zh_CN');G_reader_settings:saveSetting('color_rendering',false)
require('gettext').changeLang('zh_CN')
package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
local Device=require('device');require('document/canvascontext'):init(Device)
assert(require('weread.lib.mock_environment').save{enabled=true,host='127.0.0.1',port=tonumber(os.getenv('WEREAD_MOCK_PORT'))})
local settings=require('weread.lib.settings'):new();assert(settings.mock_endpoint)
local cb_resume=os.getenv('WEREAD_TEST_CB_RESUME')=='1'
local sync=settings:get('sync');sync.pull_on_open=false;sync.upload_on_close=false;sync.upload_interval_minutes=0;settings:set('sync',sync)
local cache=settings:get('cache');cache.auto_prefetch_next_chapter=false;cache.download_book_images=false;cache.download_underlines_and_thoughts=false;settings:set('cache',cache)
local config=settings:get('read_report');config.enabled=false;settings:set('read_report',config);settings:flush()
local offline=os.getenv('WEREAD_READING_REOPEN')=='1'
local Common=require('weread.ui.common')
Common.isNetworkOnline=function() return not offline end;Common.isNetworkConnected=Common.isNetworkOnline
local Client=require('weread.lib.client');local request=Client.request
function Client:request(options) assert(not offline,'offline HTTP attempted');return request(self,options) end
local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
for _i,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
assert(#Loader.enabled_plugins==1)
package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
local UI=require('ui/uimanager');UI:setRunForeverMode();UI:setInputTimeout(0)
local socket,json=require('socket'),require('json')
local FM,Reader=require('apps/filemanager/filemanager'),require('apps/reader/readerui')
local Source,Dom=require('weread.lib.position_source'),require('weread.lib.source_dom')
local tr=require('weread.lib.plugin_util').tr
local id=cb_resume and 'CB_SyntheticResume' or '900001'
local format=os.getenv('WEREAD_TEST_CONTENT_FORMAT')=='txt' and 'web_txt' or 'web_xhtml'
local function tick()
    UI:setInputTimeout(0);UI:handleInput()
    local dialog=UI:getTopmostVisibleWidget()
    if dialog and dialog.ok_callback and (dialog.ok_text==tr('Download') or dialog.ok_text==tr('Read now')) then
        UI:close(dialog);dialog.ok_callback()
    end
end
local function pump(predicate)
    local deadline=socket.gettime()+65
    while not predicate() do assert(socket.gettime()<deadline,'cached resume deadline');tick();socket.sleep(.01) end
end
local function clean(reader)
    while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=reader do UI:close(UI:getTopmostVisibleWidget()) end
end
local function close_reader()
    local reader=assert(Reader.instance)
    pump(function() return reader.weread.progress_sync.current_book_id==id end)
    clean(reader)
    reader.weread:onFlushSettings();reader:onClose(false)
    assert(not Reader.instance)
    if not FM.instance then FM:showFiles(home) end
end
local function press(view,label)
    for _i,buttons in ipairs({view._action_buttons or {},view._footer_actions or {}}) do
        for _j,button in ipairs(buttons) do if button.text==tr(label) then assert(button.enabled~=false);button.callback();return end end
    end
    error('missing cached reading action',0)
end
local function book(host) return assert(host.settings:get_book(id)) end
local function patch(host,values)
    local books=host.settings:get('books',{});local latest=book(host)
    for key,value in pairs(values) do if value==false then latest[key]=nil else latest[key]=value end end
    books[id]=latest;host.settings:set('books',books);host.settings:flush()
end
local function detail()
    if not FM.instance then FM:showFiles(home) end
    local host=assert(FM.instance.weread)
    host:closeWeReadUI();host:showBookshelf()
    local view=assert(host.shelf_view);local selected
    if cb_resume then
        for index,row in ipairs(view.books) do
            if tostring(row.bookId or row.book_id)==id then
                local page=math.floor((index-1)/view.page_size)+1
                if view.page~=page then host:showShelfView('books',nil,nil,{page=page});view=assert(host.shelf_view) end
                break
            end
        end
    end
    for _i,row in ipairs(view:getVisibleBooks()) do if tostring(row.bookId or row.book_id)==id then selected=row end end
    assert(selected);UI:forceRePaint();view.on_select(selected,'books')
    pump(function() return host._book_detail_view and not host.book_metadata_context end)
    return host,host._book_detail_view
end
local function read_from_shelf(expected,before_read)
    local selected_host,detail_view=detail()
    if before_read then before_read(selected_host) end
    press(detail_view,'▤ Read')
    pump(function() return Reader.instance and Reader.instance.document and (not expected or Reader.instance.document.file==expected) end)
    return Reader.instance,Reader.instance.weread
end
local function ready(reader)
    pump(function() return reader.weread.source_position:current()~=nil end)
    return assert(reader.weread.source_position:current())
end
FM:showFiles(home)
local host=assert(FM.instance.weread)
if offline then
    local file=assert(io.open(evidence..'/cached-resume-checkpoint.json','rb'));local expected=json.decode(file:read('*a'));file:close()
    local reader=read_from_shelf(expected.file)
    assert(reader.document:isXPointerInCurrentPage(expected.xpointer) and reader:getCurrentPage()==expected.page)
    local position=ready(reader);assert(position.chapter_uid==expected.chapter_uid and position.basis==Source.coordinate_basis(format))
    UI:forceRePaint();Device.screen:shot(evidence..'/cached-resume-offline.png')
    close_reader()
    print('PASS: fresh offline plugin selection -> full cached EPUB -> saved page and chapter; zero HTTP')
    os.exit(0)
end
local loaded=false;host:refreshBookshelf(nil,{on_loaded=function(ok) loaded=ok end})
pump(function() return not host.shelf_refreshing end);assert(loaded)
local reader,current=read_from_shelf()
local first=book(current).cached_chapters['2'];assert(first==reader.document.file)
current:showChapterList(book(current))
pump(function() return current._chapter_list_view~=nil end)
local view=assert(current._chapter_list_view);assert(view._chapter_rows[4]);view._chapter_rows[4].callback()
pump(function()
    local active=Reader.instance
    return active and active.document and active.document.file~=first and active.weread.settings:get_book(id).cached_chapters['4']==active.document.file
end)
reader,current=Reader.instance,Reader.instance.weread
local second=reader.document.file
local second_checkpoint={page=reader:getCurrentPage(),xpointer=reader.document:getXPointer()}
current:showChapterList(book(current));view=assert(current._chapter_list_view);view._chapter_rows[2].callback()
pump(function() return Reader.instance and Reader.instance.document.file==first end)
reader,current=Reader.instance,Reader.instance.weread
pump(function() return current.progress_sync.current_book_id==id end)
reader.rolling:onGotoPage(math.min(3,reader.document:getPageCount()));tick();ready(reader)
local expected={page=reader:getCurrentPage(),xpointer=reader.document:getXPointer()}
close_reader();host=assert(FM.instance.weread)
local saved=book(host);assert(tostring(saved.pending_upload_position.chapter_uid)=='2')
local local_pending=json.decode(json.encode(saved.pending_upload_position))
local last_local=json.decode(json.encode(saved.last_local_position))
local catalog=assert(host.library_db:getChapters(id))
local report={result='PASS',synthetic_only=true,content_format=format,chapter_files=2,full_chapters=6,
    pending_priority=false,last_local_priority=false,foreign_owner_ignored=false,native_position_restored=false,
    missing_catalog_uid=false,
    full_download=false,full_source_records=false,full_native_navigation=false}
if cb_resume then report.cb_reading=true end
for _i,mode in ipairs({'pending','last_local','foreign_owner','no_catalog'}) do
    host=assert(FM.instance.weread)
    local values={chapter_uid=4,chapter_idx=4,progress=70,pending_upload_position=local_pending,
        last_local_position=last_local,recent_read_account=saved.pending_upload_account,
        pending_upload_account=mode=='foreign_owner' and 'other-synthetic-owner' or saved.pending_upload_account}
    if mode=='last_local' then values.pending_upload_position=false end
    if mode=='foreign_owner' then
        values.pending_upload_position={book_id=id,chapter_uid=4,chapter_idx=4,percent=70}
    end
    if mode=='no_catalog' then
        values.chapters={};values.chapter_uid=2;values.chapter_idx=2
        values.pending_upload_position={book_id=id,chapter_uid=4,percent=70}
    end
    patch(host,values)
    if mode=='no_catalog' then
        assert(host.library_db:putChapters(id,{}))
        local path=require('weread.lib.content').catalog_cache_path(host.settings,book(host))
        assert(path:sub(1,#home)==home);os.remove(path)
    end
    if mode=='last_local' then assert(not book(host).pending_upload_position) end
    reader,current=read_from_shelf(mode=='no_catalog' and second or first,function(selected_host)
        local snapshot=book(selected_host)
        if mode=='no_catalog' then assert(snapshot.chapters==nil and not selected_host.library_db:getChapters(id)) end
        if mode=='foreign_owner' then
            assert(snapshot.pending_upload_position and snapshot.pending_upload_position.chapter_uid==4
                and snapshot.pending_upload_account=='other-synthetic-owner')
        end
    end)
    local checkpoint=mode=='no_catalog' and second_checkpoint or expected
    assert(reader:getCurrentPage()==checkpoint.page and reader.document:isXPointerInCurrentPage(checkpoint.xpointer))
    assert(book(current).cached_chapters['4']==second)
    report[mode=='pending' and 'pending_priority' or mode=='last_local' and 'last_local_priority'
        or mode=='no_catalog' and 'missing_catalog_uid' or 'foreign_owner_ignored']=true
    report.native_position_restored=true
    UI:forceRePaint()
    if mode=='pending' then Device.screen:shot(evidence..'/cached-resume-pending.png') end
    close_reader()
end
host=assert(FM.instance.weread);assert(host.library_db:putChapters(id,catalog))
local handoff_position
if os.getenv('WEREAD_TEST_RESUME_HANDOFF')=='1' then
    current=select(2,read_from_shelf())
    current:showChapterList(book(current));view=assert(current._chapter_list_view);view._chapter_rows[2].callback()
    pump(function() return Reader.instance and Reader.instance.document.file==first end)
    reader,current=Reader.instance,Reader.instance.weread
    pump(function() return current.progress_sync.current_book_id==id end)
    local chapter_index=assert(Dom.open(reader.document,id,2))
    local quote=format=='web_txt' and '这是第2章的第8段。窗外的风穿过树梢' or '这是第2章的第8段。我们沿着小路慢慢前行'
    local point=assert(chapter_index.map:locate(quote))
    local original=assert(Source.read_document(reader.document,id,2))
    local target={book_id=id,chapter_uid='2',chapter_offset=point.co,basis=Source.coordinate_basis(format),upload_verified=false}
    for _i,key in ipairs({'file_id','book_version','raw_sha256','render_path'}) do target[key]=original[key] end
    local applied;assert(current:openSourcePosition(target,function(result) applied=result or false end))
    pump(function() return applied~=nil end);assert(applied)
    close_reader()
    handoff_position=assert(book(assert(FM.instance.weread)).last_local_position.source_position)
    assert(handoff_position.chapter_uid=='2' and handoff_position.chapter_offset==point.co)
end
host,view=detail();press(view,'⇩ Download full book')
pump(function() return book(host).cached_full_book~=nil and not host.downloader._active_job end)
local full=assert(book(host).cached_full_book)
pump(function() return Reader.instance and Reader.instance.document.file==full end)
reader,current=Reader.instance,Reader.instance.weread;report.full_download=true
if handoff_position then
    local deadline=socket.gettime()+12
    while not current.progress_sync:current_source_target() and socket.gettime()<deadline do tick();socket.sleep(.01) end
    local retained=assert(current.progress_sync:current_source_target(),'single-chapter position was not restored in the full EPUB')
    assert(retained.chapter_uid==handoff_position.chapter_uid and retained.chapter_offset==handoff_position.chapter_offset
        and retained.raw_sha256==handoff_position.raw_sha256 and retained.file_id~=handoff_position.file_id
        and retained.upload_verified==false and current.progress_sync.verified==false)
    report.single_to_full_handoff=true
end
for uid=1,6 do
    local original=assert(Source.read_document(reader.document,id,uid));assert(original.format==format)
end
report.full_source_records=true
if handoff_position then
    local live_index=assert(Dom.open(reader.document,id,2))
    local quote=format=='web_txt' and '这是第2章的第12段。窗外的风穿过树梢' or '这是第2章的第12段。我们沿着小路慢慢前行'
    local point=assert(live_index.map:locate(quote))
    local located=assert(live_index:locate(point.co))
    local Task=require('weread.lib.source_position_worker')
    local capture=Task.capture
    Task.capture=function(input) socket.sleep(.8);return capture(input) end
    reader.rolling:onGotoXPointer(located.xpointer)
    current.source_position:on_view_changed(true)
    current:showChapterList(book(current));view=assert(current._chapter_list_view);view._chapter_rows[2].callback()
    assert(Reader.instance==reader and current._read_resume_token and not current._read_resume_token.dispatched)
    pump(function() return current.source_position.worker and current.source_position.worker.job~=nil end)
    local pid=current.source_position.worker.job.pid
    clean(reader);reader.rolling:onGotoPage(reader:getCurrentPage()+1)
    Task.capture=capture
    pump(function() return require('ffi/util').isSubProcessDone(pid) end)
    assert(Reader.instance==reader and reader.document.file==full and not current._read_resume_token)
    report.cancelled_live_file_open=true

    reader.rolling:onGotoXPointer(located.xpointer)
    current.source_position:on_view_changed(true)
    local location=assert(require('weread.lib.source_context').location(reader.document,reader.view.view_mode))
    local live_expected=assert(live_index:capture(location.xpointer)).co
    assert(not current.source_position:current())
    current:showChapterList(book(current));view=assert(current._chapter_list_view);view._chapter_rows[2].callback()
    assert(Reader.instance==reader and current._read_resume_token and not current._read_resume_token.dispatched)
    pump(function() return Reader.instance and Reader.instance.document.file==first
        and Reader.instance.weread.progress_sync:current_source_target()~=nil end)
    current=Reader.instance.weread
    local retained=assert(current.progress_sync:current_source_target())
    assert(retained.chapter_uid=='2' and retained.chapter_offset==live_expected and retained.file_id==handoff_position.file_id)
    report.full_to_single_handoff=true;report.live_source_preparation=true
    current:showBookMenu(book(current))
    pump(function() return current._book_detail_view and not current.book_metadata_context end)
    press(current._book_detail_view,'▤ Read')
    pump(function() return Reader.instance and Reader.instance.document.file==full
        and Reader.instance.weread.progress_sync:current_source_target()~=nil end)
    reader,current=Reader.instance,Reader.instance.weread
    retained=assert(current.progress_sync:current_source_target())
    assert(retained.chapter_uid=='2' and retained.chapter_offset==live_expected and retained.file_id~=handoff_position.file_id)
    report.live_single_to_full_handoff=true
end
local index,why=Dom.open(reader.document,id,4);assert(index,why)
local quote=format=='web_txt' and '这是第4章的第8段。窗外的风穿过树梢' or '这是第4章的第8段。我们沿着小路慢慢前行'
local point=assert(index.map:locate(quote))
local original=assert(Source.read_document(reader.document,id,4))
local target={book_id=id,chapter_uid='4',chapter_offset=point.co,basis=Source.coordinate_basis(format),upload_verified=false}
for _i,key in ipairs({'file_id','book_version','raw_sha256','render_path'}) do target[key]=original[key] end
local applied;assert(current:openSourcePosition(target,function(result) applied=result or false end))
pump(function() return applied~=nil end);assert(applied and applied.chapter_uid=='4')
local bound=assert(current.progress_sync.source_anchor)
assert(assert(index:capture(bound.xpointer)).co==point.co and reader.document:isXPointerInCurrentPage(bound.xpointer))
assert(assert(current.source_position:current()).chapter_offset==point.co)
report.full_native_navigation=true
UI:forceRePaint();Device.screen:shot(evidence..'/cached-resume-full.png')
local checkpoint={file=full,page=reader:getCurrentPage(),xpointer=bound.xpointer,chapter_uid='4'}
local file=assert(io.open(evidence..'/cached-resume-checkpoint.json','wb'));assert(file:write(json.encode(checkpoint)));file:close()
close_reader()
file=assert(io.open(evidence..'/cached-resume-result.json','wb'));assert(file:write(json.encode(report)));file:close()
print('PASS: plugin cached chapter selection prefers local intent; six-chapter full download -> bound native navigation')
