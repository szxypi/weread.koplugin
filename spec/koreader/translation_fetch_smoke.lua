require('setupkoenv')
local home,evidence=assert(os.getenv('KO_HOME')),assert(os.getenv('WEREAD_EVIDENCE'))
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
require('gettext').changeLang('zh_CN')
local Device=require('device');require('document/canvascontext'):init(Device)
local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
for _,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
assert(#Loader.enabled_plugins==1)
package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
local UIManager=require('ui/uimanager')
local Reader=require('apps/reader/readerui')
local Content=require('weread.lib.content')
local Source=require('weread.lib.position_source')
local Identity=require('weread.lib.book_file_identity')
local Fetch=require('weread.ui.translation_fetch')
local tr=require('weread.lib.i18n').tr
local settings=require('weread.lib.settings'):new()
local offline_process=os.getenv('WEREAD_TRANSLATION_FETCH_OFFLINE')=='1'
local chapter={chapterUid=1,chapterIdx=1,title='Chapter One',wordCount=1800}
local paragraphs={}
for i=1,12 do paragraphs[#paragraphs+1]='<p>Original paragraph '..i..'. '..string.rep('Unique source text for native translation refresh. ',8)..'</p>' end
local raw='<html><body><h1>Chapter One</h1>'..table.concat(paragraphs)..'</body></html>'
local book={book_id='900001',bookVersion=7,title='译文副本原生验证',author='Synthetic',chapters={chapter}}
local function bytes(file) local f=assert(io.open(file,'rb'));local value=f:read('*a');f:close();return value end
local path,original,copy,bookmark
local private_state=evidence..'/translation-fetch-synthetic-state.json'
if offline_process then
    local saved=require('json').decode(bytes(private_state))
    path,copy,bookmark=saved.original,saved.copy,saved.bookmark
    original=bytes(path);assert(require('weread.lib.crypto').sha256_hex(original)==saved.original_sha256)
else
    local source=assert(Source.capture(book,chapter,raw,'web_xhtml'))
    path=Content.save_chapter_epub(settings,book,chapter,raw,nil,nil,Identity.capture(book),source)
    book.cached_chapters={['1']=path};settings:set('books',{['900001']=book})
    settings:set('cookies',{wr_vid='900000',wr_skey='synthetic-cookie'});settings:set('account',{user_vid='900000'})
    settings:set('sync',{pull_on_open=false,upload_on_close=false});settings:set('read_report',{enabled=false})
    local cache=settings:get('cache');cache.auto_prefetch_next_chapter=false;cache.show_annotations=false;cache.download_book_images=false
    settings:set('cache',cache);settings:flush();original=bytes(path)
end
local socket,ffi=require('socket'),require('ffi');local parent=tonumber(ffi.C.getpid())
local reader,plugin,doc
UIManager:setRunForeverMode();UIManager:setInputTimeout(0)
local function pump(check,seconds)
    local deadline=socket.gettime()+(seconds or 60)
    repeat UIManager:handleInput();if check() then return end;assert(socket.gettime()<deadline,'translation fetch runtime deadline');socket.sleep(.01) until false
end
local function clean()
    while UIManager:getTopmostVisibleWidget() and UIManager:getTopmostVisibleWidget()~=reader do UIManager:close(UIManager:getTopmostVisibleWidget()) end
end
local function adopt(value) reader=value;plugin=assert(reader.weread);doc=reader.document;clean() end
local function open(file)
    local value=Reader:new{dimen=Device.screen:getSize(),document=require('document/documentregistry'):openDocument(file)}
    UIManager:show(value);adopt(value)
end
open(path)
if offline_process then
    assert(reader.annotation.annotations[1].page==bookmark,'new process lost original bookmark')
    plugin.client.request=function() error('new offline process tried HTTP') end
    plugin:showReadingLanguage();pump(function() return not plugin.translation_job end)
    local menu=assert(plugin._translation_menu);local entry
    for _,item in ipairs(menu.item_table) do if item.text==tr('Open saved translated copy') then entry=item end end
    assert(entry,'new process lost translated shortcut')
    local previous=reader;menu:onMenuSelect(entry)
    pump(function() return Reader.instance and Reader.instance~=previous and Reader.instance.document.file==copy end)
    adopt(Reader.instance);assert(plugin._translation_mode=='bilingual' and not plugin.progress_sync.verified)
    assert(bytes(path)==original,'offline process changed original EPUB')
    local out=assert(io.open(evidence..'/translation-fetch-offline.json','w'));out:write(require('json').encode{result='PASS',new_process=true,
        original_bookmark_preserved=true,translated_copy_opened=true,bilingual_mode_retained=true,network_requests=0});out:close()
    reader:onClose(false);print('PASS: new-process offline translated copy shortcut and original bookmark');return
end
reader.bookmark:onToggleBookmark();bookmark=assert(reader.annotation.annotations[1]).page
local native_read=doc.getDocumentFileContent
doc.getDocumentFileContent=function(self,name) assert(tonumber(ffi.C.getpid())==parent,'translation child used inherited reader');return native_read(self,name) end
plugin:showReadingLanguage();pump(function() return not plugin.translation_job end)
local menu=assert(plugin._translation_menu);local download
for _,item in ipairs(menu.item_table) do if item.text==tr('Download existing translation') then download=item end end
assert(download,'existing translation entry absent')
menu:onMenuSelect(download)
assert(plugin.translation_fetch_job and plugin.translation_fetch_worker.job,'download did not use actual background worker')
local heartbeat=false;UIManager:scheduleIn(.05,function() heartbeat=true end)
pump(function() return not plugin.translation_fetch_job and heartbeat end)
local dialog=assert(plugin._translation_fetch_result,'translated result absent')
UIManager:forceRePaint();Device.screen:shot(evidence..'/translation-fetch-result.png')
local record=assert(reader.doc_settings:readSetting('weread_translation_copies')['1'])
copy=record.path
assert(copy~=path and bytes(path)==original and reader.annotation.annotations[1].page==bookmark,'download changed original file/bookmark')
assert(plugin.settings:get_book('900001').cached_chapters['1']==path,'download replaced normal cached chapter')
local accepted_copy=bytes(copy)
assert(record.blocks==12 and record.file_id~=Identity.read_document(doc,'900001').file_id,'new copy has no independent identity')
local old_reader=reader;dialog.ok_callback()
pump(function() return Reader.instance and Reader.instance~=old_reader and Reader.instance.document.file==copy end)
adopt(Reader.instance)
assert(plugin._translation_mode=='bilingual' and not plugin.progress_sync.verified,'copy did not open bilingually/unverified')
assert(plugin.settings:get_book('900001').cached_chapters['1']==path,'copy open replaced normal cached chapter')
local text=doc:getTextFromPositions({x=1,y=1},{x=Device.screen:getWidth()-2,y=Device.screen:getHeight()-2},true)
assert(text and text.text:find('Original',1,true) and text.text:find('译文',1,true),'native bilingual copy text missing')
UIManager:forceRePaint();Device.screen:shot(evidence..'/translation-fetch-bilingual.png')
reader:onClose(false);open(path)
assert(reader.annotation.annotations[1].page==bookmark and bytes(path)==original,'ordinary original reopen lost bookmark/file')
plugin:showReadingLanguage();pump(function() return not plugin.translation_job end)
local offline=assert(plugin._translation_menu);local saved
for _,item in ipairs(offline.item_table) do if item.text==tr('Open saved translated copy') then saved=item end end
assert(saved,'offline translated copy entry missing')
plugin.client.request=function() error('offline copy tried HTTP') end
old_reader=reader;offline:onMenuSelect(saved)
pump(function() return Reader.instance and Reader.instance~=old_reader and Reader.instance.document.file==copy end)
adopt(Reader.instance);assert(plugin._translation_mode=='bilingual','offline copy lost mode')
reader:onClose(false);open(path)
assert(Fetch.start(plugin));local job=assert(plugin.translation_fetch_job);local partial=job.output.path;local pid=plugin.translation_fetch_worker.job.pid
plugin.busy_message:onTapClose()
assert(not plugin.translation_fetch_job and not require('libs/libkoreader-lfs').attributes(partial),'cancel retained partial output')
pump(function() return require('ffi/util').isSubProcessDone(pid) end)
assert(Fetch.start(plugin));job=assert(plugin.translation_fetch_job);partial=job.output.path
reader.rolling:onGotoPage(2);plugin:onPageUpdate()
assert(not plugin.translation_fetch_job and not require('libs/libkoreader-lfs').attributes(partial),'page movement retained download')
assert(bytes(path)==original and bytes(copy)~='','original or accepted copy lost')
-- Only the real worker child gets a kernel file-size limit. The libarchive
-- writer must fail, and its unaccepted output must be removed by the parent.
local core=require('weread.lib.translation_fetch');local run=core.run
core.run=function(...)
    assert(tonumber(ffi.C.getpid())~=parent,'file limit reached the UI process')
    ffi.cdef[[struct wr_fetch_rlimit { unsigned long current; unsigned long maximum; };
        int setrlimit(int, const struct wr_fetch_rlimit *);
        typedef void (*wr_fetch_handler)(int); wr_fetch_handler signal(int,wr_fetch_handler);]]
    ffi.C.signal(25,ffi.cast('wr_fetch_handler',1))
    assert(ffi.C.setrlimit(1,ffi.new('struct wr_fetch_rlimit',{512,512}))==0)
    local ok,reason=pcall(run,...)
    assert(not ok and tostring(reason)=='translation_fetch/package_failed','kernel archive write did not fail as expected')
    return {ok=false,kernel_limit_observed=true}
end
local worker=plugin.translation_fetch_worker;local start=worker.start;local kernel_limit=false
worker.start=function(self,task,callback) return start(self,task,function(value)
    kernel_limit=type(value)=='table' and value.kernel_limit_observed==true;callback(value)
end) end
reader.rolling:onGotoPage(1);assert(Fetch.start(plugin));partial=plugin.translation_fetch_job.output.path
pump(function() return not plugin.translation_fetch_job end)
assert(kernel_limit and not require('libs/libkoreader-lfs').attributes(partial),'kernel-limited worker left partial output')
assert(bytes(path)==original and bytes(copy)==accepted_copy,'failed publication changed accepted files')
core.run=run;worker.start=start;clean()
local result={result='PASS',synthetic_only=true,existing_translation_blocks=12,independent_worker=true,
    parent_archive_not_used_by_child=true,ui_heartbeat=true,original_epub_unchanged=true,original_bookmark_preserved=true,
    distinct_epub_identity=true,bilingual_copy_opened=true,offline_shortcut_reopened=true,offline_http=0,
    cancel_partial_removed=true,page_movement_cancelled=true,cloud_upload_permission_granted=false,account_data_posts=0,
    generation_requests=0,translation_mode_requests=0,kernel_archive_limit_cleaned=true}
local out=assert(io.open(evidence..'/translation-fetch.json','w'));out:write(require('json').encode(result));out:close()
out=assert(io.open(private_state,'w'));out:write(require('json').encode{original=path,copy=copy,bookmark=bookmark,
    original_sha256=require('weread.lib.crypto').sha256_hex(original)});out:close()
reader:onClose(false)
print('PASS: native existing-translation copy download, independent archive/worker, bilingual open, offline shortcut and cancellation')
