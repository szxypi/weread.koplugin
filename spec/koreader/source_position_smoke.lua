-- Actual ReaderUI lifecycle, cooperative viewport capture and memory-pipe source worker.
require("setupkoenv")
local home, evidence = assert(os.getenv("KO_HOME")), assert(os.getenv("WEREAD_EVIDENCE"))
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(home .. "/settings.reader.lua")
G_reader_settings:saveSetting("language", "zh_CN")
G_reader_settings:saveSetting("color_rendering", false)
G_reader_settings:saveSetting("extra_plugin_paths", { home .. "/plugins" })
require("gettext").changeLang("zh_CN")
local Device = require("device")
require("document/canvascontext"):init(Device)
local PluginLoader = require("pluginloader")
PluginLoader.enabled_plugins, PluginLoader.disabled_plugins, PluginLoader.loaded_plugins = {}, {}, {}
for _, entry in ipairs(PluginLoader:_discover()) do
    if entry.name == "weread" then PluginLoader:_load{ entry } end
end
assert(#PluginLoader.enabled_plugins == 1, "candidate plugin missing")
package.path = home .. "/plugins/weread.koplugin/?.lua;" .. package.path
local Content = require("weread.lib.content")
local settings = require("weread.lib.settings"):new()
assert(settings.mock_endpoint and settings.data_dir:match("/weread%-mock$"), "isolated profile required")
local Source=require('weread.lib.position_source')
local Identity=require('weread.lib.book_file_identity')
local Context=require('weread.lib.source_context')
local Dom=require('weread.lib.source_dom')
local WorkerTask=require('weread.lib.source_position_worker')
local socket=require('socket')
local ffi=require('ffi')
local util=require('ffi/util')
local UIManager=require('ui/uimanager')
local Event=require('ui/event')
local parent_pid=tonumber(ffi.C.getpid())
local chapters={{chapterUid=11,chapterIdx=1,title='第一章',wordCount=4000},
    {chapterUid=22,chapterIdx=2,title='第二章',wordCount=4000}}
local canary='SOURCE_BODY_MUST_STAY_OUT_OF_SETTINGS'
local function make_book(book_id,version)
    local book={book_id=book_id,bookId=book_id,bookVersion=version,title='阅读状态验证 '..book_id,chapters=chapters}
    local bodies,sources={},{}
    for _,chapter in ipairs(chapters) do
        local parts={'<h1>'..chapter.title..'</h1><p>Edition '..version..' '..canary..'。</p>'}
        for i=1,45 do
            parts[#parts+1]='<p>第'..chapter.chapterUid..'章第'..i..'段：'
                ..string.rep('阅读状态必须来自当前文档，后台任务不能覆盖新的页面。',3)..'</p>'
        end
        local body=table.concat(parts,'\n')
        bodies[tostring(chapter.chapterUid)]=body
        sources[tostring(chapter.chapterUid)]=assert(Source.capture(book,chapter,'<html><body>'..body..'</body></html>','web_xhtml'))
    end
    local file=Content.save_book_epub(settings,book,chapters,bodies,'full',{},nil,nil,Identity.capture(book),sources)
    book.cached_file,book.cached_full_book=file,file
    Content.save_catalog_cache(require('weread.lib.client'):new(settings),settings,book,chapters)
    return book,file
end
local book,path=make_book('900001',7)
local other,other_path=make_book('900002',1)
settings:set('books',{['900001']=book,['900002']=other})
settings:set('sync',{pull_on_open=false,upload_on_close=false})
local cache=settings:get('cache',{})
cache.auto_prefetch_next_chapter=false
cache.show_annotations=false
settings:set('cache',cache);settings:flush()
local reader,plugin,service,doc
local function guard_native(document)
    for _,name in ipairs({'getDocumentFileContent','getHTMLFromXPointers','getTextFromXPointers','getPrevVisibleChar','getNextVisibleChar'}) do
        local original=document[name]
        document[name]=function(self,...)
            assert(tonumber(ffi.C.getpid())==parent_pid,'worker touched inherited native document')
            return original(self,...)
        end
    end
end
local function open(file)
    reader=require('apps/reader/readerui'):new{dimen=Device.screen:getSize(),
        document=require('document/documentregistry'):openDocument(file)}
    UIManager:show(reader)
    plugin=assert(reader.weread);service=assert(plugin.source_position);doc=reader.document
    guard_native(doc)
end
UIManager:setRunForeverMode();UIManager:setInputTimeout(0)
local saw_worker=false
local function pump_until(predicate,timeout)
    local deadline=socket.gettime()+(timeout or 15)
    repeat
        UIManager:handleInput()
        local job=service and service.worker and service.worker.job
        if job then assert(job.pid~=parent_pid);saw_worker=true end
        if predicate() then return end
        assert(socket.gettime()<deadline,'reader source state timed out: '..tostring(service and service.state)..'/'..tostring(service and service.reason))
        util.usleep(10000)
    until false
end
local function ready()
    pump_until(function() return service:current()~=nil end)
    return assert(service:current())
end
local function assert_reference(position)
    local index,reason=Dom.open(doc,position.book_id,position.chapter_uid)
    assert(index,reason)
    local location=assert(Context.location(doc,reader.view.view_mode))
    local expected,why=index:capture(location.xpointer)
    assert(expected,why)
    assert(expected.co==position.chapter_offset,'background result differs from native chapter DOM reference')
    assert(position.upload_verified==false and position.basis=='filtered_xhtml_utf16','local check activated wire writes')
end
local function dismiss_info()
    local stack=UIManager._window_stack
    local top=stack[#stack]
    if top and getmetatable(top.widget)==require('ui/widget/infomessage') then UIManager:close(top.widget) end
end
open(path)
local initial=ready();assert_reference(initial)
assert(initial.book_version==7 and initial.book_id=='900001','initial source scope')
assert(initial.chapter_title=='第一章','chapter title was not read from the verified file')
assert(plugin.progress_sync:status().source_position.chapter_offset==initial.chapter_offset,'production sync status lacks local source position')
local legacy=assert(plugin.progress_sync:capture_local())
assert(legacy.source_position.chapter_offset==initial.chapter_offset and legacy.chapter_offset~=initial.chapter_offset,
    'source coordinate overwrote the existing wire units')
local source_menu
for _,item in ipairs(plugin:getMainMenuItems()) do
    if item.text==require('weread.lib.i18n').tr('Check reading position') then source_menu=item end
end
assert(source_menu,'production position-check menu missing')
source_menu.callback()
pump_until(function()
    local top=UIManager._window_stack[#UIManager._window_stack]
    return top and type(top.widget.text)=='string' and top.widget.text:find('精确云端同步',1,true)
end)
UIManager:forceRePaint();Device.screen:shot(evidence..'/source-state-ready.png')
assert(plugin._source_position_message,'source dialog was not tracked')
-- A confirmed live child remains responsive to a real native page event.
local original_capture=WorkerTask.capture
WorkerTask.capture=function(input) socket.sleep(0.8);return original_capture(input) end
service:on_view_changed(true)
assert(not plugin._source_position_message,'invalidated page retained a stale position dialog')
dismiss_info();dismiss_info()
pump_until(function() return service.worker and service.worker.job~=nil end)
local old_pid=service.worker.job.pid
reader.rolling:onGotoPage(2)
WorkerTask.capture=original_capture
local after_turn=ready();assert_reference(after_turn)
assert(after_turn.chapter_offset~=initial.chapter_offset,'real page turn retained old position')
pump_until(function() return util.isSubProcessDone(old_pid) end)
-- Scroll movement is observed through PosUpdate, without reading a footer cache.
reader:handleEvent(Event:new('SetViewMode','scroll'))
reader.rolling:onGotoPercent(35)
local scrolled=ready();assert_reference(scrolled)
reader.view.footer.percent_finished=0.99
assert(service:current().chapter_offset==scrolled.chapter_offset,'stale footer changed source position')
-- Account change cancels a live source worker and prepares a separate owner.
WorkerTask.capture=function(input) socket.sleep(0.8);return original_capture(input) end
service:on_view_changed(true)
pump_until(function() return service.worker and service.worker.job~=nil end)
old_pid=service.worker.job.pid
local account=plugin.settings:get('account')
plugin.settings:set('account',{user_vid='900099',name='Other synthetic owner'})
plugin:onWeReadAccountChanged()
WorkerTask.capture=original_capture
local after_account=ready();assert_reference(after_account)
assert(service.scope.account=='900099','source scope retained old account')
pump_until(function() return util.isSubProcessDone(old_pid) end)
plugin.settings:set('account',account);plugin:onWeReadAccountChanged();ready()
-- Native lifecycle callbacks cancel on suspend and refresh on resume.
plugin:onSuspend();assert(service.state=='paused' and not service:current(),'suspend retained source state')
plugin:onResume();ready()
-- Low-memory backoff recovers without a UI-thread fallback.
local memory=plugin.prefetch_worker.availableMemoryKB
plugin.prefetch_worker.availableMemoryKB=function() return 0 end
service:on_view_changed(true)
pump_until(function() return service.state=='deferred' end)
assert(not (service.worker and service.worker.job),'low memory spawned source worker')
plugin.prefetch_worker.availableMemoryKB=memory
ready()
-- Replacing the active pathname cannot relabel an old open reader as version 8.
WorkerTask.capture=function(input) socket.sleep(0.8);return original_capture(input) end
service:on_view_changed(true)
pump_until(function() return service.worker and service.worker.job~=nil end)
local replacement,replaced_path=make_book('900001',8)
assert(replaced_path==path,'replacement fixture changed pathname')
local books=plugin.settings:get('books',{});books['900001']=replacement;plugin.settings:set('books',books);plugin.settings:flush()
WorkerTask.capture=original_capture
pump_until(function() return service.state=='unavailable' or service.state=='unsupported' end)
assert(not service:current(),'open reader accepted a replaced file source')
assert(Identity.read_document(doc,'900001').book_version==7,'open reader rebound provenance')
local old_service=service
reader:onClose()
open(path)
local reopened=ready();assert_reference(reopened)
assert(reopened.book_version==8 and not old_service:current(),'reopening did not bind new file')
-- Closing and opening a different book rejects any old worker result.
WorkerTask.capture=function(input) socket.sleep(0.8);return original_capture(input) end
service:on_view_changed(true)
pump_until(function() return service.worker and service.worker.job~=nil end)
old_pid=service.worker.job.pid;old_service=service
reader:onClose();WorkerTask.capture=original_capture
open(other_path)
local next_book=ready();assert_reference(next_book)
assert(next_book.book_id=='900002' and not old_service:current(),'book switch retained old result')
pump_until(function() return util.isSubProcessDone(old_pid) end)
local result={status='PARTIAL',public_network_used=false,production_account_writes_attempted=0,
    wire_precision_sync_enabled=false,live_reader_capture=true,background_process_observed=saw_worker,
    native_document_kept_in_parent=true,menu_check=true,page_turn=true,scroll=true,account_change=true,
    suspend_resume_callbacks=true,low_memory_recovery=true,same_path_replacement=true,reopen_version=8,
    verified_file_chapter_title=true,stale_dialog_closed=true,
    book_switch=true,initial_co=initial.chapter_offset,page_two_co=after_turn.chapter_offset,
    screen={width=Device.screen:getWidth(),height=Device.screen:getHeight()}}
reader:onClose()
assert(not (service.worker and service.worker.job),'closed reader left a source worker')
local config=io.open(home..'/settings/weread.lua','rb')
if config then local text=config:read('*a');config:close();assert(not text:find(canary,1,true),'source body persisted in settings') end
local file=assert(io.open(evidence..'/source-state.json','wb'));file:write(require('rapidjson').encode(result));file:close()
UIManager:quit()
print('PASS: production ReaderUI -> bounded native context -> independent archive worker -> current local position; stale scopes cancelled')
