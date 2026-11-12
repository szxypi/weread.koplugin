-- Real packaged ReaderUI, HTTP, independent archive and native cloud navigation.
require('setupkoenv')
local home=assert(os.getenv('KO_HOME'))
local evidence=assert(os.getenv('WEREAD_EVIDENCE'))
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
require('gettext').changeLang('zh_CN')
local Device=require('device')
require('document/canvascontext'):init(Device)
local Loader=require('pluginloader')
Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
for _,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
assert(#Loader.enabled_plugins==1)
package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
local UIManager=require('ui/uimanager')
local Settings=require('weread.lib.settings')
local Client=require('weread.lib.client')
local Content=require('weread.lib.content')
local Source=require('weread.lib.position_source')
local Dom=require('weread.lib.source_dom')
local Identity=require('weread.lib.book_file_identity')
local settings=Settings:new()
local client=Client:new(settings)
local book=client:get_book_info('900001')
Content.ensure_reader_state(client,book)
local chapters=Content.fetch_catalog(client,book)
assert(Content.save_catalog_cache(client,settings,book,chapters))
local full=Content.fetch_chapters_epub(client,settings,book,chapters,{suffix='cloud-target'})
book.cached_file,book.cached_full_book=full,full
settings:set('books',{['900001']=book})
settings:set('api_key','')
settings:set('sync',{pull_on_open=false,upload_on_close=false})
settings:set('read_report',{enabled=false})
local cache=settings:get('cache');cache.auto_prefetch_next_chapter=false;cache.show_annotations=false
settings:set('cache',cache);settings:flush()
local socket=require('socket')
local ffi=require('ffi')
local pid=tonumber(ffi.C.getpid())
local reader,plugin,document
UIManager:setRunForeverMode();UIManager:setInputTimeout(0)
local function pump(predicate,timeout)
    local deadline=socket.gettime()+(timeout or 30)
    repeat
        UIManager:handleInput()
        if predicate() then return end
        assert(socket.gettime()<deadline,'cloud source runtime deadline')
        socket.sleep(0.01)
    until false
end
local function open(path)
    reader=require('apps/reader/readerui'):new{dimen=Device.screen:getSize(),
        document=require('document/documentregistry'):openDocument(path)}
    UIManager:show(reader)
    plugin,document=assert(reader.weread),reader.document
    plugin.isNetworkOnline=function() return true end
    plugin.isNetworkConnected=function() return true end
    pump(function() return plugin._current_weread_book_id=='900001' end)
end
local function request(path,data)
    local http,ltn12=require('socket.http'),require('ltn12')
    local chunks={};local body=data and client:json_encode(data)
    local _,code=http.request{url=settings.mock_endpoint..path,proxy=settings.mock_endpoint,method=data and 'POST' or 'GET',
        source=body and ltn12.source.string(body),sink=ltn12.sink.table(chunks),
        headers=body and {['content-type']='application/json',['content-length']=#body} or {}}
    assert(code==200);return client:json_decode(table.concat(chunks))
end
local function count(path)
    local total=0;for _,row in ipairs(request('/__state').requests) do if row.path==path then total=total+1 end end;return total
end
local function control(data) request('/__control',data) end
local function close_info()
    local top=UIManager:getTopmostVisibleWidget()
    if top and top~=reader then UIManager:close(top) end
end
open(full)
local remote=request('/__state').progress['900001']
local source=assert(Source.read_document(document,'900001',6))
local reference=assert(Dom.open(document,'900001',6))
local target=assert(reference:locate(remote.chapterOffset))
reader.rolling:onGotoPage(1)
local original_read=document.getDocumentFileContent
document.getDocumentFileContent=function(self,name)
    assert(tonumber(ffi.C.getpid())==pid,'child touched inherited native archive')
    assert(not name:find('/raw-',1,true) and not name:match('^OEBPS/text/'),'parent read chapter bytes during cloud navigation')
    return original_read(self,name)
end
local writes=count('/web/book/read')
local entry
for _,item in ipairs(plugin:getMainMenuItems()) do
    if item.text==require('weread.lib.i18n').tr('Open cloud reading position precisely') then entry=item end
end
assert(entry and not entry.keep_menu_open,'precise cloud menu is missing or hides the reader')
control{match='/web/book/getProgress',times=0,delay=0.3}
plugin.progress_sync.verified=true
local unsent=assert(plugin.progress_sync:capture_local())
assert(plugin.progress_sync:_upload_snapshot(unsent,'synthetic-before-cloud-choice',false))
local menu
menu=require('ui/widget/menu'):new{title='WeRead cloud navigation',item_table={entry},
    close_callback=function() UIManager:close(menu) end}
UIManager:show(menu);menu:onMenuSelect(entry)
assert(UIManager:getTopmostVisibleWidget()~=menu and plugin.busy_message,'native menu did not yield to the loading dialog')
local child_seen,heartbeat=false,false
UIManager:scheduleIn(0.1,function() heartbeat=true end)
pump(function()
    local worker=plugin.cloud_source_worker and plugin.cloud_source_worker.job
    if worker then assert(worker.pid~=pid);child_seen=true end
    return not plugin.cloud_source_request
end)
assert(child_seen and heartbeat,'cloud target HTTP blocked UI or bypassed child')
assert(not plugin.busy_message and document:isXPointerInCurrentPage(target.xpointer),'precise cloud target is not visible')
local held=assert(plugin.source_position:current())
assert(held.retained_source_target and held.chapter_uid=='6' and held.chapter_offset==remote.chapterOffset
    and not held.upload_verified,'cloud target lost source units or granted upload verification')
assert(not plugin.progress_sync.verified and not plugin.settings:get('books')['900001'].pending_upload_position,
    'old queued local intent or report permission survived the cloud choice')
assert(document:getCurrentPage()>1,'whole-book cloud target did not cross chapters')
close_info();UIManager:forceRePaint();Device.screen:shot(evidence..'/cloud-source-target.png')
document.getDocumentFileContent=original_read
control{match='',times=0,delay=0}

-- Offline and rate failures preserve the current native viewport.
reader.rolling:onGotoPage(1)
plugin.isNetworkOnline=function() return false end
local before=count('/web/book/getProgress')
assert(not plugin:showCloudSourcePosition() and count('/web/book/getProgress')==before)
close_info();plugin.isNetworkOnline=function() return true end
control{match='/web/book/getProgress',times=1,status=429,delay=0}
assert(plugin:showCloudSourcePosition());pump(function() return not plugin.cloud_source_request end)
assert(count('/web/book/getProgress')==before+1 and document:getCurrentPage()==1 and not plugin.busy_message,'429 retried or moved viewport')
close_info();control{match='/web/book/getProgress',times=0,delay=0.6}
assert(plugin:showCloudSourcePosition())
pump(function() return plugin.cloud_source_worker.job~=nil end)
plugin.busy_message:onTapClose()
assert(not plugin.cloud_source_worker.job and not plugin.cloud_source_request,'dismissed cloud child survived')
local deadline=socket.gettime()+0.7
while socket.gettime()<deadline do UIManager:handleInput();socket.sleep(0.01) end
assert(document:getCurrentPage()==1 and not plugin.busy_message,'cancelled cloud read applied late target')

-- Cancellation from the existing native navigator must notify the cloud UI.
control{match='',times=0,delay=0}
assert(plugin:showCloudSourcePosition())
pump(function() return plugin.cloud_source_request and plugin.cloud_source_request.navigation~=nil end)
plugin.source_navigation:cancel()
assert(not plugin.cloud_source_request and not plugin.busy_message,'native navigator cancellation retained cloud spinner')
assert(document:getCurrentPage()==1,'cancelled native target still moved')

-- Reader lifecycle must terminate the real child before it can navigate.
assert(plugin:showCloudSourcePosition());pump(function() return plugin.cloud_source_worker.job~=nil end)
plugin:onSuspend()
assert(not plugin.cloud_source_worker.job and not plugin.cloud_source_request and not plugin.busy_message,'suspend retained cloud work')
control{match='',times=0,delay=0};plugin:onResume()
local account=plugin.settings:get('account')
control{match='/web/book/getProgress',times=0,delay=0.6}
assert(plugin:showCloudSourcePosition());pump(function() return plugin.cloud_source_worker.job~=nil end)
plugin.settings:set('account',{user_vid='90009999'});plugin.settings:flush();plugin:onWeReadAccountChanged()
assert(not plugin.cloud_source_worker.job and not plugin.cloud_source_request,'account switch retained cloud work')
plugin.settings:set('account',account);plugin.settings:flush();plugin:onWeReadAccountChanged()
control{match='',times=0,delay=0}
assert(count('/web/book/read')==writes,'cloud navigation wrote progress or reading time')

control{match='/web/book/getProgress',times=0,delay=0.6}
assert(plugin:showCloudSourcePosition());pump(function() return plugin.cloud_source_worker.job~=nil end)
local previous_plugin=plugin
reader:onClose()
assert(not previous_plugin.cloud_source_request and not previous_plugin.cloud_source_worker.job,'closing the reader retained cloud child')
control{match='',times=0,delay=0};open(full)
assert(document:getCurrentPage()==1 and not plugin.cloud_source_request,'reopened reader inherited an old cloud target')

-- A chapter file can hand off to a validated full-book cache.
-- Enable ordinary startup pulling here: a precise handoff must supersede it.
local config=plugin.settings:get('sync');config.pull_on_open=true
plugin.settings:set('sync',config);plugin.settings:flush()
local first=assert(Source.read_document(document,'900001',1))
local rendered=assert(document:getDocumentFileContent(first.render_path))
local single_book={book_id='900001',bookId='900001',bookVersion=7,title='Cloud single fixture',chapters=chapters}
local single=Content.save_chapter_epub(plugin.settings,single_book,chapters[1],rendered,{},nil,
    Identity.capture(single_book),assert(Source.capture(single_book,chapters[1],first.raw,'web_xhtml')))
local function adopt_target(previous)
    pump(function()
        local next_reader=require('apps/reader/readerui').instance
        if next_reader and next_reader~=previous then
            reader=next_reader;plugin=assert(reader.weread);document=reader.document
            plugin.isNetworkOnline=function() return true end
            plugin.isNetworkConnected=function() return true end
        end
        local held_target=reader~=previous and plugin.source_position:current()
        return held_target and held_target.retained_source_target and held_target.chapter_uid=='6'
            and not plugin.cloud_source_request and not plugin.cloud_source_incoming
    end)
    assert(not plugin.progress_sync.verified and not plugin.busy_message,'cross-file target granted report permission or leaked busy state')
    local startup_deadline=socket.gettime()+0.7
    local reads_after_target=count('/web/book/getProgress')
    while socket.gettime()<startup_deadline do UIManager:handleInput();socket.sleep(0.01) end
    assert(count('/web/book/getProgress')==reads_after_target and not plugin.progress_sync.verified,
        'ordinary startup pull overwrote precise handoff or granted report permission')
    local native_target=assert(assert(Dom.open(document,'900001',6)):locate(remote.chapterOffset))
    assert(document:isXPointerInCurrentPage(native_target.xpointer),'cross-file source target is not visible in the native viewport')
end
reader:onClose();open(single)
local previous_reader=reader
assert(plugin:showCloudSourcePosition());adopt_target(previous_reader)
assert(document.file==full,'matching full-book cache was not selected')
close_info()

-- Clear only synthetic cache references to exercise confirmation and download.
local function clear_candidates()
    local saved=plugin.settings:get('books')
    saved['900001'].cached_file=nil;saved['900001'].cached_full_book=nil;saved['900001'].cached_chapters=nil
    plugin.settings:set('books',saved);plugin.settings:flush()
end
clear_candidates();reader:onClose();open(single)
assert(plugin:showCloudSourcePosition())
pump(function() return plugin.cloud_source_request and plugin.cloud_source_request.confirm end)
local confirmation=plugin.cloud_source_request.confirm
UIManager:forceRePaint();Device.screen:shot(evidence..'/cloud-source-download-confirm.png')
confirmation:onClose()
assert(not plugin.cloud_source_request and document.file==single and not plugin.downloader._active_job,'declining target download changed book')

-- Cancel the real downloader child; its completion must not schedule a switch.
control{match='/web/book/chapter/e_0',times=0,delay=0.4}
assert(plugin:showCloudSourcePosition())
pump(function() return plugin.cloud_source_request and plugin.cloud_source_request.confirm end)
plugin.cloud_source_request.confirm.ok_callback()
pump(function() return plugin.downloader._active_job and plugin.downloader._active_job.progress_dialog
    and plugin.downloader._active_job.progress_dialog.dismiss_callback end)
local owned=plugin.downloader._active_job
plugin:cancelCloudSourcePosition()
assert(owned.cancelled and not plugin.cloud_source_request and not plugin.downloader._active_job,'cancel left owned downloader/child active')
local cancel_deadline=socket.gettime()+0.6
while socket.gettime()<cancel_deadline do UIManager:handleInput();socket.sleep(0.01) end
assert(document.file==single and not plugin.cloud_source_incoming,'cancelled download reopened a book')
control{match='',times=0,delay=0}

assert(plugin:showCloudSourcePosition())
pump(function() return plugin.cloud_source_request and plugin.cloud_source_request.confirm end)
previous_reader=reader
local reads_before_download=count('/web/book/getProgress')
plugin.cloud_source_request.confirm.ok_callback()
adopt_target(previous_reader)
assert(document.file~=single and not plugin.downloader._active_job,'downloaded chapter was not opened after cleanup')
assert(count('/web/book/getProgress')==reads_before_download+2,'download was not reverified with one fresh stable cloud snapshot')
local downloaded=document.file
local verified=assert(plugin.source_position:current())
assert(verified.chapter_offset==remote.chapterOffset,'downloaded chapter lost exact cloud source offset')
close_info();UIManager:forceRePaint();Device.screen:shot(evidence..'/cloud-source-downloaded-target.png')

-- The chapter cache is preferred over legacy/full paths on the next request.
reader:onClose();open(single)
previous_reader=reader
assert(plugin:showCloudSourcePosition());adopt_target(previous_reader)
assert(document.file==downloaded,'matching chapter cache was not reused')
close_info()
-- Different original bytes cannot use cloud offsets, even in the same chapter.
clear_candidates();reader:onClose()
local changed_book={book_id='900001',bookId='900001',bookVersion=7,title='Cloud changed fixture',chapters=chapters}
local changed=Content.save_chapter_epub(settings,changed_book,chapters[6],'<html><body><p>Different source fixture.</p></body></html>',{},nil,
    Identity.capture(changed_book),assert(Source.capture(changed_book,chapters[6],source.raw..'\n','web_xhtml')))
open(changed)
assert(plugin:showCloudSourcePosition())
pump(function() return plugin.cloud_source_request and plugin.cloud_source_request.confirm end)
assert(document.file==changed and document:getCurrentPage()==1 and not plugin.source_navigation.job,'different source guessed a position')
plugin.cloud_source_request.confirm:onClose();reader:onClose()
assert(count('/web/book/read')==writes,'cross-file continuation wrote progress or reading time')
local report={result='PASS',synthetic_only=true,source_target_visible=true,cross_chapter_full_book=true,
    background_http=true,independent_archive=true,retained_original_offset=true,upload_verified=false,
    offline_no_request=true,rate_no_retry=true,dismiss_cancelled=true,suspend_cancelled=true,account_cancelled=true,
    navigator_cancelled=true,reader_reopen_cancelled=true,old_queued_upload_cancelled=true,report_gate_not_granted=true,
    cached_full_handoff=true,cached_chapter_handoff=true,startup_pull_superseded=true,download_declined=true,
    owned_download_cancelled=true,download_reverified=true,downloaded_source_target_visible=true,changed_source_no_guess=true,reading_writes=0}
local file=assert(io.open(evidence..'/cloud-source.json','w'));file:write(client:json_encode(report));file:close()
print('PASS: cloud GET/Reader/3 read shards/GET -> same-source EPUB -> native cross-chapter target/retention; offline/429/cancel/suspend/account/cached full/cached chapter/confirmed download/cancel; no reading writes')
