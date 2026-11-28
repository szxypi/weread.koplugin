-- Full packaged ReaderUI; all books, identifiers and text are synthetic.
require('setupkoenv')
local home,evidence=assert(os.getenv('KO_HOME')),assert(os.getenv('WEREAD_EVIDENCE'))
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
require('gettext').changeLang('zh_CN')
local Device=require('device');require('document/canvascontext'):init(Device)
local Loader=require('pluginloader')
Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
for _,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
assert(#Loader.enabled_plugins==1)
package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
local UIManager=require('ui/uimanager')
local Reader=require('apps/reader/readerui')
local Content=require('weread.lib.content')
local Archive=require('weread.lib.translation_archive')
local Source=require('weread.lib.position_source')
local Identity=require('weread.lib.book_file_identity')
local tr=require('weread.lib.i18n').tr
local settings=require('weread.lib.settings'):new()
local chapters={{chapterUid=1,chapterIdx=1,title='Chapter One',wordCount=1000},{chapterUid=2,chapterIdx=2,title='Chapter Two',wordCount=1000}}
local bodies={['1']=[[<html><body><h1>Chapter One</h1>
<p id="pair">ORIGINALONE English paragraph.</p><p id="pair" class="wr-translation">TRANSLATIONONE 中文译文。</p>
<p>NOIDORIGINAL English paragraph.</p><p class="wr-translation">NOIDTRANSLATION 中文译文。</p>
<p id="keep">KEEPORIGINAL unpaired source.</p><p id="other" class="wr-translation">ORPHANTRANSLATION 独立译文。</p>
<p>LINKORIGINAL <a href="#note">footnote</a></p><p class="wr-translation">LINKTRANSLATION 保留链接。</p>
<p id="note">Note text.</p></body></html>]],
['2']=[[<html><body><h1>Chapter Two</h1><p id="pair">ORIGINALTWO Another chapter.</p>
<p id="pair" class="wr-translation">TRANSLATIONTWO 第二章译文。</p></body></html>]]}
local book={book_id='900001',bookVersion=7,title='原生双语阅读验证',author='Synthetic',chapters=chapters}
local sources={}
for index,chapter in ipairs(chapters) do sources[tostring(index)]=assert(Source.capture(book,chapter,bodies[tostring(index)],'web_xhtml')) end
local path=Content.save_book_epub(settings,book,chapters,bodies,'reader-translation',nil,nil,nil,Identity.capture(book),sources)
book.cached_file,book.cached_full_book=path,path
assert(Content.save_catalog_cache(require('weread.lib.client'):new(settings),settings,book,chapters))
settings:set('books',{['900001']=book})
settings:set('sync',{pull_on_open=false,upload_on_close=false})
settings:set('read_report',{enabled=false})
local cache=settings:get('cache');cache.auto_prefetch_next_chapter=false;cache.show_annotations=false
settings:set('cache',cache);settings:flush()
local function bytes(file) local fd=assert(io.open(file,'rb'));local value=fd:read('*a');fd:close();return value end
local before=bytes(path)
local fixture=home..'/../books/archive-'
local inspected=assert(Archive.inspect(fixture..'valid.epub','900001'))
assert(inspected.chapters[1].fragment_index==1 and inspected.chapters[2].fragment_index==2 and inspected.pairs==2)
for _,variant in ipairs({'duplicate','missing','wrong-book'}) do assert(not Archive.inspect(fixture..variant..'.epub','900001'),'ambiguous archive accepted') end
local socket,ffi=require('socket'),require('ffi')
local pid=tonumber(ffi.C.getpid())
local reader,plugin,document
UIManager:setRunForeverMode();UIManager:setInputTimeout(0)
local function pump(predicate,timeout)
    local deadline=socket.gettime()+(timeout or 30)
    repeat
        UIManager:handleInput()
        if predicate() then return end
        assert(socket.gettime()<deadline,'translation reader deadline')
        socket.sleep(0.01)
    until false
end
local function adopt(value)
    reader=value;plugin,document=assert(reader.weread),reader.document
    assert(plugin._current_weread_book_id=='900001')
end
local function open()
    local value=Reader:new{dimen=Device.screen:getSize(),document=require('document/documentregistry'):openDocument(path)}
    UIManager:show(value);adopt(value)
end
local function clean_popups()
    while UIManager:getTopmostVisibleWidget() and UIManager:getTopmostVisibleWidget()~=reader do UIManager:close(UIManager:getTopmostVisibleWidget()) end
end
local function visible(page)
    reader.rolling:onGotoPage(page)
    local value=document:getTextFromPositions({x=1,y=1},{x=Device.screen:getWidth()-2,y=Device.screen:getHeight()-2},true)
    return value and value.text or ''
end
local function has(text,word) return text:find(word,1,true)~=nil end
local function verify(mode)
    assert(plugin._translation_mode==mode,'new reader did not restore selected mode')
    assert(not document:isBuiltDomStale(),'display mode built a stale DOM')
    local first,second=visible(1),visible(document:getPageCount())
    assert(has(first,'ORIGINALONE')==(mode~='translation') and has(first,'TRANSLATIONONE')==(mode~='original'),'native paired paragraph visibility wrong')
    assert(has(first,'NOIDORIGINAL')==(mode~='translation') and has(first,'NOIDTRANSLATION')==(mode~='original'),'native id-less pair wrong')
    assert(has(first,'KEEPORIGINAL') and has(first,'LINKORIGINAL'),'original unpaired content or link removed')
    assert(has(second,'ORIGINALTWO')==(mode~='translation') and has(second,'TRANSLATIONTWO')==(mode~='original'),'chapter-scoped same ID wrong')
    assert(bytes(path)==before,'display transition rewrote the EPUB')
end
local function choices()
    plugin:showReadingLanguage()
    if plugin.translation_job then pump(function() return not plugin.translation_job end) end
    return assert(plugin._translation_menu,'native language menu missing')
end
local function select(menu,index,mode)
    local old=reader
    menu:onMenuSelect(menu.item_table[index])
    pump(function() return Reader.instance and Reader.instance~=old and Reader.instance.weread and Reader.instance.weread._translation_mode==mode end)
    adopt(Reader.instance);clean_popups()
    assert(not plugin.progress_sync.verified,'display change granted upload verification')
end
local function translation_height()
    reader.rolling:onGotoPage(1)
    local boxes=document:getScreenBoxesFromPositions('/body/DocFragment[1]/body/p[2]/text().0','/body/DocFragment[1]/body/p[2]/text().14',true)
    assert(#boxes>0,'translated line has no native text boxes')
    return boxes[1].h
end
open();verify('original')
local entry
for _,item in ipairs(plugin:getMainMenuItems()) do if item.text==tr('Reading language') then entry=item end end
assert(entry and not entry.keep_menu_open,'reading language entry missing')
-- A canary rejects child access to the parent's live archive; the local worker
-- must open its own descriptor. The event loop keeps ticking during inspection.
local original_read=document.getDocumentFileContent
document.getDocumentFileContent=function(self,name) assert(tonumber(ffi.C.getpid())==pid,'child touched inherited native archive');return original_read(self,name) end
entry.callback()
assert(plugin.translation_job and plugin.translation_worker.job and plugin.translation_worker.job.pid~=pid,'native inspection bypassed independent worker')
local heartbeat=false;UIManager:scheduleIn(0.1,function() heartbeat=true end)
pump(function() return not plugin.translation_job and heartbeat end)
assert(plugin._translation_profile.blocks==5 and plugin._translation_profile.pairs==3,'actual EPUB translation counts wrong')
document.getDocumentFileContent=original_read
UIManager:forceRePaint();Device.screen:shot(evidence..'/translation-reader-menu.png')
reader.rolling:onGotoXPointer('/body/DocFragment[1]/body/p[1]/text().3')
reader.bookmark:onToggleBookmark()
local saved_bookmark=assert(reader.annotation.annotations[1]).page
-- Queue a synthetic old upload and enable normal sync. The local transition
-- must cancel that unsent task and the new reader's delayed automatic pull.
plugin.settings:set('api_key','synthetic')
plugin.settings:set('sync',{pull_on_open=true,upload_on_close=true});plugin.settings:flush()
plugin.isNetworkOnline=function() return true end
plugin.progress_sync.verified=true;plugin.progress_sync.dirty=true
assert(plugin.progress_sync:_upload_snapshot(assert(plugin.progress_sync:capture_local()),'synthetic-display-transition',false))
assert(plugin.progress_sync.upload_job,'old upload was not queued')
local durable=assert(plugin.settings:get_book('900001').pending_upload_position)
local snapshot=assert(Source.document_metadata(document,'900001','1'))
local point=assert(require('weread.lib.source_dom').open(document,'900001','1')):capture('/body/DocFragment[1]/body/p[1]/text().3')
assert(point,'native source position unavailable')
local held={basis='filtered_xhtml_utf16',upload_verified=false,chapter_offset=point.co}
for _,key in ipairs({'book_id','chapter_uid','file_id','book_version','raw_sha256','render_path'}) do held[key]=snapshot.record[key] end
assert(plugin.progress_sync:retain_source_target(held,'/body/DocFragment[1]/body/p[1]/text().3',snapshot.metadata),'source target was not tied to visible original')
select(plugin._translation_menu,2,'bilingual')
local retained=assert(plugin.progress_sync:current_source_target(),'bilingual lost read-only source provenance')
assert(retained.chapter_offset==held.chapter_offset and retained.upload_verified==false,'display switch changed source offset or granted write verification')
assert(reader.annotation.annotations[1].page==saved_bookmark,'display reload replaced local bookmark position')
local remaining=assert(plugin.settings:get_book('900001').pending_upload_position)
assert(remaining.chapter_uid==durable.chapter_uid and remaining.chapter_offset==durable.chapter_offset,'display change dropped durable unsent intent')
local until_time=socket.gettime()+0.7
pump(function() return socket.gettime()>=until_time end)
assert(not plugin.progress_sync.upload_job and not plugin.progress_sync.verified,'delayed sync survived display handoff')
plugin.settings:set('sync',{pull_on_open=false,upload_on_close=false});plugin.settings:set('api_key','');plugin.settings:flush()
assert(document:isXPointerInCurrentPage('/body/DocFragment[1]/body/p[1]'),'bilingual handoff lost paragraph')
verify('bilingual');reader.rolling:onGotoPage(1)
UIManager:forceRePaint();Device.screen:shot(evidence..'/translation-reader-bilingual.png')
select(choices(),3,'translation')
assert(document:isXPointerInCurrentPage('/body/DocFragment[1]/body/p[2]'),'translation handoff lost paired paragraph')
verify('translation');reader.rolling:onGotoPage(1)
UIManager:forceRePaint();Device.screen:shot(evidence..'/translation-reader-translation.png')
local original_height=translation_height()
local sizes=choices();sizes:onMenuSelect(sizes.item_table[4]);sizes=assert(plugin._translation_menu)
select(sizes,6,'translation');assert(plugin._translation_scale==140,'translation size not retained after native reload')
assert(translation_height()>original_height,'native translation font did not grow')
verify('translation')
assert(reader.annotation.annotations[1].page==saved_bookmark,'ordinary reopen lost original bookmark position')
-- Closing normally removes all in-memory transfer/profile state. A fresh open
-- restores the sidecar preference and inspects the archive before first render.
reader:onClose(false);open()
assert(plugin._translation_mode=='translation' and plugin._translation_scale==140,'ordinary reopen lost mode/size')
verify('translation')
reader.rolling:onGotoXPointer('/body/DocFragment[2]/body/p[2]/text().2')
select(choices(),1,'original')
assert(document:isXPointerInCurrentPage('/body/DocFragment[2]/body/p[1]'),'original return jumped to the other chapter sharing an ID')
verify('original')
-- Parent-level cancellation uses the actual worker, native busy dialog and
-- plugin suspend lifecycle. Late results must not reopen choices.
plugin._translation_profile=nil
assert(plugin:showReadingLanguage());plugin.busy_message:onTapClose()
assert(not plugin.translation_job and not plugin.translation_worker.job and not plugin._translation_menu,'dismiss retained inspection')
assert(plugin:showReadingLanguage());plugin:onSuspend()
assert(not plugin.translation_job and not plugin.translation_worker.job and not plugin._translation_menu,'suspend retained inspection')
plugin:onResume();clean_popups()
local report={result='PASS',synthetic_only=true,native_engine=true,reader_menu_integrated=true,mode_persistence_integrated=true,
    independent_archive_worker=true,ui_heartbeat=true,archive_duplicate_missing_owner_rejected=true,paragraph_handoff=true,
    same_ids_cross_chapter=true,unpaired_original_and_links_preserved=true,ordinary_reopen_mode_and_size=true,
    suspend_and_dismiss_cancelled=true,dom_stale=false,epub_unchanged=true,bookmark_position_preserved=true,native_font_size_changed=true,
    old_upload_cancelled=true,durable_upload_intent_preserved=true,delayed_pull_cancelled=true,read_only_source_target_retained=true,
    upload_permission_granted=false,network_requests=0}
local fd=assert(io.open(evidence..'/translation-reader.json','w'));fd:write(require('json').encode(report));fd:close()
reader:onClose(false)
print('PASS: full native translation reader menus, worker, original/bilingual/translation reload, font size, persistence, paragraph handoff, original EPUB and cancellation')
