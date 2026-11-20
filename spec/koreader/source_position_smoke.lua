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
local source_format=os.getenv('WEREAD_TEST_SOURCE_FORMAT') or 'web_xhtml'
assert(source_format=='web_xhtml' or source_format=='web_txt')
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
        for i=1,450 do
            parts[#parts+1]='<p>第'..chapter.chapterUid..'章第'..i..'段：'
                ..string.rep('阅读状态必须来自当前文档，后台任务不能覆盖新的页面。',3)..'</p>'
        end
        local body=table.concat(parts,'\n')
        local original='<html><body>'..body..'</body></html>'
        if source_format=='web_txt' then
            local lines={'\239\187\191'..chapter.title,'Edition '..version..' '..canary..'。'}
            for _i=1,450 do
                lines[#lines+1]='第'..chapter.chapterUid..'章第'.._i..'段：'
                    ..string.rep('阅读状态必须来自当前文档，后台任务不能覆盖新的页面。',3)..'\t<tag>&amp;😀\194\160\227\128\128  '
            end
            original=table.concat(lines,'\r\n\r\n')..'\r\n'
            body=Content.txt_to_xhtml(original)
        end
        bodies[tostring(chapter.chapterUid)]=body
        sources[tostring(chapter.chapterUid)]=assert(Source.capture(book,chapter,original,source_format))
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
        local navigation_job=plugin and plugin.source_navigation and plugin.source_navigation.worker and plugin.source_navigation.worker.job
        if navigation_job then assert(navigation_job.pid~=parent_pid);saw_worker=true end
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
    assert(position.upload_verified==false and position.basis==Source.coordinate_basis(source_format),'local check activated wire writes or used another format')
end
local function dismiss_info()
    local stack=UIManager._window_stack
    local top=stack[#stack]
    if top and getmetatable(top.widget)==require('ui/widget/infomessage') then UIManager:close(top.widget) end
end
local candidate_count,held_candidate_count,candidate_summaries=0,0,{}
local function check_upload_candidate(position)
    local value,reason,done
    local legacy=assert(plugin.progress_sync:capture_local())
    service:prepare_upload_preview(function(candidate,why) value,reason,done=candidate,why,true end)
    pump_until(function() return done end)
    if source_format=='web_txt' then
        assert(not value and reason=='source_unsupported','TXT acquired unverified cloud semantics')
        return
    end
    assert(value and not reason,'upload candidate unavailable: '..tostring(reason))
    assert(value.book_id==position.book_id and value.chapter_uid==position.chapter_uid
        and value.chapter_offset==position.chapter_offset and value.percent==legacy.percent
        and value.upload_verified==false,'candidate mixed source/word/display units')
    local expected_index
    for _i,chapter in ipairs(chapters) do
        if tostring(chapter.chapterUid)==value.chapter_uid then expected_index=chapter.chapterIdx end
    end
    assert(value.chapter_idx==expected_index,'candidate guessed current chapter from whole-book fraction')
    local index=assert(Dom.open(doc,position.book_id,position.chapter_uid))
    local target=assert(index:locate(value.chapter_offset))
    local ending=target.xpointer
    for _i=1,80 do
        local next_point=doc:getNextVisibleChar(ending)
        if not next_point or Dom.fragment(next_point)~=Dom.fragment(target.xpointer) then break end
        ending=next_point
    end
    local actual=assert(Dom.normalize(doc:getTextFromXPointers(target.xpointer,ending)))
    doc:clearSelection()
    local chars={}
    for char in actual:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
        if #chars==20 then break end
        chars[#chars+1]=char
    end
    assert(value.summary==table.concat(chars),'source summary differs from actual native DOM text')
    assert(not service:current().summary and not service:current().candidate,'candidate leaked into local checkpoint')
    assert(plugin.progress_sync:capture_local().chapter_offset==legacy.chapter_offset,'preview changed ordinary upload units')
    candidate_count=candidate_count+1;candidate_summaries[#candidate_summaries+1]=value.summary
    if position.retained_source_target then held_candidate_count=held_candidate_count+1 end
end
open(path)
local initial=ready();assert_reference(initial)
check_upload_candidate(initial)
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
local deferred_preview_cancelled
do
    local capture=WorkerTask.capture
    WorkerTask.capture=function(input) socket.sleep(0.8);return capture(input) end
    service:on_view_changed(true)
    local cancelled_callback=false
    service:prepare_upload_preview(function() cancelled_callback=true end)
    service:cancel_upload_preview()
    ready();WorkerTask.capture=capture
    assert(not cancelled_callback and not service.preview_job,'cancelled preview resumed after deferred capture')
    deferred_preview_cancelled=true
end
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
check_upload_candidate(after_turn)
assert(after_turn.chapter_offset~=initial.chapter_offset,'real page turn retained old position')
pump_until(function() return util.isSubProcessDone(old_pid) end)
local preview_cancelled=false
local preview_catalog_change_rejected=false
if source_format=='web_xhtml' then
    local original_preview=WorkerTask.prepare_upload
    WorkerTask.prepare_upload=function(input) socket.sleep(0.8);return original_preview(input) end
    local stale_callback=false
    service:prepare_upload_preview(function() stale_callback=true end)
    pump_until(function() return service.preview_worker and service.preview_worker.job end)
    local preview_pid=service.preview_worker.job.pid
    reader.rolling:onGotoPage(3)
    WorkerTask.prepare_upload=original_preview
    local moved=ready();assert_reference(moved);check_upload_candidate(moved)
    pump_until(function() return util.isSubProcessDone(preview_pid) end)
    assert(not stale_callback and not service.preview_job,'old preview committed after a real page turn')
    preview_cancelled=true
    -- A normal sync frame caches its catalog. Preview completion must consult
    -- the currently persisted catalog rather than that older in-memory frame.
    local live=assert(service.get_upload_context())
    local catalog=assert(plugin.library_db:getChapters(live.book_id))
    local changed={}
    for _i,row in ipairs(catalog) do
        local copy={};for key,item in pairs(row) do copy[key]=item end
        if tostring(copy.chapterUid)==service:current().chapter_uid then copy.chapterIdx=copy.chapterIdx+100 end
        changed[#changed+1]=copy
    end
    local rejected,completed
    WorkerTask.prepare_upload=function(input) socket.sleep(0.8);return original_preview(input) end
    service:prepare_upload_preview(function(value) rejected,completed=value==nil,true end)
    pump_until(function() return service.preview_worker and service.preview_worker.job end)
    assert(plugin.library_db:putChapters(live.book_id,changed))
    pump_until(function() return completed end)
    assert(plugin.library_db:putChapters(live.book_id,catalog))
    WorkerTask.prepare_upload=original_preview
    assert(rejected,'older sync catalog accepted a changed chapter index')
    preview_catalog_change_rejected=true
end
-- Scroll movement is observed through PosUpdate, without reading a footer cache.
reader:handleEvent(Event:new('SetViewMode','scroll'))
reader.rolling:onGotoPercent(35)
local scrolled=ready();assert_reference(scrolled)
check_upload_candidate(scrolled)
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
local fixture_dir=debug.getinfo(1,'S').source:match('^@(.*/)')
dofile(fixture_dir..'source_navigation_smoke.lua')(reader,plugin,pump_until,evidence,check_upload_candidate)
check_upload_candidate(ready())
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
check_upload_candidate(reopened)
assert(reopened.book_version==8 and not old_service:current(),'reopening did not bind new file')
-- An independent target-preparation child also dies when the reader closes;
-- reopening the same pathname cannot revive its deferred native navigation.
local original_target=WorkerTask.prepare_target
WorkerTask.prepare_target=function(input) socket.sleep(0.8);return original_target(input) end
local closed_navigation=plugin.source_navigation
local old_target_callback=false
assert(plugin:openSourcePosition(reopened,function() old_target_callback=true end))
pump_until(function() return closed_navigation.worker and closed_navigation.worker.job~=nil end)
local target_pid=closed_navigation.worker.job.pid
reader:onClose();WorkerTask.prepare_target=original_target
open(path);ready()
pump_until(function() return util.isSubProcessDone(target_pid) end)
assert(not old_target_callback and not closed_navigation.job,'closed target job committed into reopened reader')
-- Closing and opening a different book rejects any old worker result.
WorkerTask.capture=function(input) socket.sleep(0.8);return original_capture(input) end
service:on_view_changed(true)
pump_until(function() return service.worker and service.worker.job~=nil end)
old_pid=service.worker.job.pid;old_service=service
reader:onClose();WorkerTask.capture=original_capture
open(other_path)
local next_book=ready();assert_reference(next_book)
check_upload_candidate(next_book)
assert(next_book.book_id=='900002' and not old_service:current(),'book switch retained old result')
pump_until(function() return util.isSubProcessDone(old_pid) end)
local result={status='PARTIAL',public_network_used=false,production_account_writes_attempted=0,
    source_format=source_format,coordinate_basis=Source.coordinate_basis(source_format),
    wire_precision_sync_enabled=false,live_reader_capture=true,background_process_observed=saw_worker,
    native_document_kept_in_parent=true,menu_check=true,page_turn=true,scroll=true,account_change=true,
    suspend_resume_callbacks=true,low_memory_recovery=true,same_path_replacement=true,reopen_version=8,
    verified_file_chapter_title=true,stale_dialog_closed=true,
    source_navigation=true,source_navigation_close_reopen=true,
    source_upload_candidates=candidate_count,source_upload_summary_native_dom_verified=source_format=='web_xhtml',
    source_upload_retained_target_candidates=held_candidate_count,
    source_upload_preview_child_cancelled_and_reaped=preview_cancelled,
    source_upload_preview_deferred_cancellation=deferred_preview_cancelled,
    source_upload_preview_current_catalog_rechecked=preview_catalog_change_rejected,
    txt_upload_preview_rejected=source_format=='web_txt',
    book_switch=true,initial_co=initial.chapter_offset,page_two_co=after_turn.chapter_offset,
    screen={width=Device.screen:getWidth(),height=Device.screen:getHeight()}}
reader:onClose()
assert(not (service.worker and service.worker.job),'closed reader left a source worker')
assert(not (service.preview_worker and service.preview_worker.job),'closed reader left a preview worker')
local config=io.open(home..'/settings/weread.lua','rb')
if config then
    local text=config:read('*a');config:close();assert(not text:find(canary,1,true),'source body persisted in settings')
    for _i,summary in ipairs(candidate_summaries) do assert(not text:find(summary,1,true),'candidate summary persisted in settings') end
end
local file=assert(io.open(evidence..'/source-state.json','wb'));file:write(require('rapidjson').encode(result));file:close()
UIManager:quit()
print('PASS: production ReaderUI -> bounded native context -> independent archive worker -> current local position; stale scopes cancelled')
