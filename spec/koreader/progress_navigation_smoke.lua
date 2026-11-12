-- Real cached chapter switching must transfer an intent to the new plugin.
require('setupkoenv')
local home,evidence=assert(os.getenv('KO_HOME')),assert(os.getenv('WEREAD_EVIDENCE'))
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
G_reader_settings:saveSetting('language','zh_CN')
G_reader_settings:saveSetting('color_rendering',false)
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
require('gettext').changeLang('zh_CN')
local Device=require('device')
require('document/canvascontext'):init(Device)
local PluginLoader=require('pluginloader')
PluginLoader.enabled_plugins,PluginLoader.disabled_plugins,PluginLoader.loaded_plugins={},{},{}
for _,entry in ipairs(PluginLoader:_discover()) do if entry.name=='weread' then PluginLoader:_load{entry} end end
assert(#PluginLoader.enabled_plugins==1,'candidate plugin missing')
package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
local Content=require('weread.lib.content')
local Identity=require('weread.lib.book_file_identity')
local Source=require('weread.lib.position_source')
local settings=require('weread.lib.settings'):new()
assert(settings.mock_endpoint,'isolated profile required')
local chapters={{chapterUid=1,chapterIdx=1,title='第一章',wordCount=101},
    {chapterUid=2,chapterIdx=2,title='第二章',wordCount=301}}
local book={book_id='900001',bookId='900001',bookVersion=7,title='跨章位置验证',chapters=chapters,cached_chapters={}}
local paths={}
for index,chapter in ipairs(chapters) do
    local parts={'<h1>'..chapter.title..'</h1>'}
    for paragraph=1,80 do parts[#parts+1]='<p>章节'..index..'段落'..paragraph..'：'
        ..string.rep('切换章节会创建新的阅读器，必须保留本人刚选择的位置。',3)..'</p>' end
    local body=table.concat(parts)
    local original=assert(Source.capture(book,chapter,'<html><body>'..body..'</body></html>','web_xhtml'))
    paths[index]=Content.save_chapter_epub(settings,book,chapter,body,{},nil,Identity.capture(book),original)
    book.cached_chapters[tostring(chapter.chapterUid)]=paths[index]
end
book.cached_file=paths[1]
Content.save_catalog_cache(require('weread.lib.client'):new(settings),settings,book,chapters)
settings:set('books',{['900001']=book})
settings:set('sync',{pull_on_open=false,upload_on_close=false})
local cache=settings:get('cache',{});cache.auto_prefetch_next_chapter=false;cache.show_annotations=false
settings:set('cache',cache);settings:flush()
local UIManager=require('ui/uimanager')
local ReaderUI=require('apps/reader/readerui')
local old_reader=ReaderUI:new{dimen=Device.screen:getSize(),document=require('document/documentregistry'):openDocument(paths[1])}
UIManager:show(old_reader)
UIManager:setRunForeverMode();UIManager:setInputTimeout(0)
local socket=require('socket')
local function pump(predicate)
    local deadline=socket.gettime()+25
    repeat
        UIManager:handleInput()
        if predicate() then return end
        assert(socket.gettime()<deadline,'chapter navigation timed out')
        require('ffi/util').usleep(10000)
    until false
end
local old_sync=old_reader.weread.progress_sync
pump(function() return old_sync.current_book_id=='900001' end)
local _,_,context=old_sync:capture_local()
assert(old_sync:_apply_remote({book_id='900001',chapter_uid=2,chapter_idx=2,chapter_offset=154,
    percent=(101+154)/402*100,has_chapter_offset=true},context))
pump(function() return ReaderUI.instance and ReaderUI.instance~=old_reader and ReaderUI.instance.document.file==paths[2] end)
local reader=ReaderUI.instance
local sync=reader.weread.progress_sync
pump(function() return sync.current_book_id=='900001' end)
assert(sync~=old_sync,'fixture did not create a new progress controller')
local position=assert(sync:capture_local())
assert(position.chapter_uid==2 and position.chapter_offset==154,'cross-chapter target was lost in the new ReaderUI instance')
assert(sync.verified and not sync.dirty,'selected target not verified or became reverse upload intent')
local cached_position=position.chapter_offset
local ConfirmBox=require('ui/widget/confirmbox')
local function confirm()
    for index=#UIManager._window_stack,1,-1 do
        local widget=UIManager._window_stack[index].widget
        if getmetatable(widget)==ConfirmBox and type(widget.ok_callback)=='function' then return widget end
    end
end
local function current_first()
    reader.weread:openFile(paths[1])
    local previous=reader
    pump(function() return ReaderUI.instance and ReaderUI.instance~=previous and ReaderUI.instance.document.file==paths[1] end)
    reader=ReaderUI.instance;sync=reader.weread.progress_sync
    pump(function() return sync.current_book_id=='900001' and reader.weread.source_position:current()~=nil end)
end
local function uncached()
    local books=reader.weread.settings:get('books',{})
    books['900001'].cached_chapters['2']=nil
    reader.weread.settings:set('books',books);reader.weread.settings:flush()
    sync.document_context=nil
end
local function select_target()
    local _,_,current=sync:capture_local()
    assert(sync:_apply_remote({book_id='900001',chapter_uid=2,chapter_idx=2,chapter_offset=154,
        percent=(101+154)/402*100,has_chapter_offset=true},current))
end
current_first();uncached();select_target()
local stale=assert(confirm(),'native target confirmation missing')
UIManager:forceRePaint();Device.screen:shot(evidence..'/chapter-confirmation.png')
sync:begin_local_navigation()
select_target()
local latest=assert(confirm());local pending=sync.pending_jump
stale.ok_callback();stale.cancel_callback()
assert(sync.pending_jump==pending and not reader.weread.downloader._active_job,'stale native confirmation acted on new intent')
UIManager:close(latest);latest.cancel_callback()
-- The old target may finish downloading into cache, but a newer local source
-- request must prevent its automatic open. The new source jump is real too.
select_target();assert(confirm()).ok_callback()
local original_reader=reader
assert(reader.weread.downloader._active_job,'real target download did not start')
local source_target=assert(reader.weread.source_position:current())
local local_done=false
assert(reader.weread:openSourcePosition(source_target,function(value) assert(value);local_done=true end))
pump(function() return not reader.weread.downloader._active_job and local_done end)
assert(ReaderUI.instance==original_reader and reader.document.file==paths[1],
    'late downloaded chapter overrode newer local navigation')
assert(not sync.pending_jump,'new source request retained old chapter intent')
local saved=reader.weread.settings:get('books')['900001'].cached_chapters['2']
assert(saved and require('weread.lib.plugin_util').file_exists(saved),'superseded download did not retain its cache')
-- A fresh confirmed download still switches through the native ReaderUI and
-- delivers the exact chosen offset to its new progress-controller instance.
uncached();select_target();assert(confirm()).ok_callback()
local downloading_reader=reader
pump(function() return ReaderUI.instance and ReaderUI.instance~=downloading_reader and ReaderUI.instance.document.file==saved end)
reader=ReaderUI.instance;sync=reader.weread.progress_sync
pump(function() return sync.current_book_id=='900001' end)
local downloaded=assert(sync:capture_local())
assert(downloaded.chapter_uid==2 and downloaded.chapter_offset==154 and sync.verified and not sync.dirty,
    'confirmed download lost selected target in new reader')
UIManager:forceRePaint();Device.screen:shot(evidence..'/chapter-target.png')
local file=assert(io.open(evidence..'/navigation-intent.json','wb'))
file:write(require('rapidjson').encode({status='PARTIAL',public_network_used=false,production_account_writes_attempted=0,
    precision_wire_sync_enabled=false,native_reader_replaced=true,cached_chapter_switch=true,cached_offset=cached_position,
    stale_native_prompt_rejected=true,old_download_cached_without_open=true,new_local_source_request=true,
    downloaded_chapter_switch=true,target_chapter=2,target_offset=154,
    current_page=reader.document:getCurrentPage(),total_pages=reader.document:getPageCount()}));file:close()
reader:onClose();UIManager:quit()
print('PASS: native confirmations and real HTTP downloads respect new navigation; new ReaderUI receives selected chapter offset')
