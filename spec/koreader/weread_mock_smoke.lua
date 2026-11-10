-- Standalone real-KOReader smoke. See docs/mock-weread.md for the command.
-- luacheck: globals fastforward_ui_events
require("setupkoenv")
local home = assert(os.getenv("KO_HOME"))
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(home .. "/settings.reader.lua")
G_reader_settings:saveSetting("language", "zh_CN")
G_reader_settings:saveSetting("color_rendering", false)
G_reader_settings:saveSetting("extra_plugin_paths", { home .. "/plugins" })
require("gettext").changeLang("zh_CN")
local Device = require("device")
require("document/canvascontext"):init(Device)
-- Isolate the candidate using the native PluginLoader (no unit-test runtime).
local PluginLoader = require("pluginloader")
local test_offline_time = os.getenv("WEREAD_TEST_OFFLINE_TIME") == "1"
PluginLoader.enabled_plugins, PluginLoader.disabled_plugins, PluginLoader.loaded_plugins = {}, {}, {}
for _, entry in ipairs(PluginLoader:_discover()) do
    if entry.name == "weread" or (test_offline_time and entry.name == "statistics") then PluginLoader:_load{ entry } end
end
assert(#PluginLoader.enabled_plugins == (test_offline_time and 2 or 1), "candidate discovery failed")
local function fastforward_ui_events()
    local manager = require("ui/uimanager")
    manager:shiftScheduledTasksBy(-1e9)
    manager:setInputTimeout(0)
    manager:handleInput()
end
-- PluginLoader restores package.path after loading; later lazy requires in
-- this standalone test need the same installed candidate directory.
package.path = home .. "/plugins/weread.koplugin/?.lua;" .. package.path

local Settings = require("weread.lib.settings")
local Client = require("weread.lib.client")
local Content = require("weread.lib.content")
local settings = Settings:new()
assert(settings.mock_endpoint and settings.data_dir:match("/weread%-mock$"), "isolated mock environment")
local client = Client:new(settings)
-- Exercise the migrated protocol through the actual JSON, socket and sink
-- implementations. Native fixture credentials stay in this local scope.
do
    local authorization = require("weread.lib.native_authorization"):new(client, { expected_vid = "900000" })
    assert(authorization:begin():find("https://open.weixin.qq.com/connect/confirm?", 1, true), "native QR target")
    assert(authorization:poll() == "confirmed", "native owner confirmation")
    local credentials, native_shelf = authorization:finish()
    assert(credentials.vid == "900000" and credentials.accessToken and credentials.refreshToken
        and #credentials.deviceId == 32 and #native_shelf.books == 26, "native verified shelf")
    assert(not pcall(authorization.finish, authorization), "native login was replayable")
    print("PASS: native QR/ticket/login signature -> real Client/JSON/HTTP -> verified shelf; no credential persistence")
end
-- A configured Internet proxy must not intercept local mock traffic or probes.
local http = require("socket.http")
http.PROXY = "http://127.0.0.1:1"
assert(client:test_mock_connection(require("weread.lib.mock_environment").active()) == settings.mock_endpoint)
local shelf = client:get_shelf()
assert(#shelf.books == 26 and #shelf.archive == 3, "shelf contract")
assert(http.PROXY == "http://127.0.0.1:1", "mock changed the global HTTP proxy")
local book = client:get_book_info("900001")
Content.ensure_reader_state(client, book)
local chapters = Content.fetch_catalog(client, book)
assert(#chapters == 6, "catalog contract")
assert(Content.save_catalog_cache(client, settings, book, chapters))
local path = Content.fetch_chapter_epub(client, settings, book, chapters[1])
settings:set("books", { [book.bookId] = book })
settings:flush()
local ok, marks = client:get_chapter_underlines(book.bookId, 1)
assert(ok and #marks.underlines == 1, "underlines contract")
local reviews_ok, thoughts = client:get_chapter_reviews(book.bookId, 1, { marks.underlines[1].range })
assert(reviews_ok and #thoughts.reviews == 1, "thoughts contract")
local denied, code = client:request({ url = "https://example.invalid/never-contact-upstream" })
assert(code == 501 and denied:find("Unimplemented mock route", 1, true), "HTTP must fail closed")

local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local function pump_until(predicate)
    local socket=require('socket');local deadline=socket.gettime()+45
    while not predicate() do
        assert(socket.gettime()<deadline,'standalone async progress deadline')
        UIManager:setInputTimeout(0);UIManager:handleInput();socket.sleep(.01)
    end
end
local reader = require("apps/reader/readerui"):new{
    dimen = Screen:getSize(),
    document = require("document/documentregistry"):openDocument(path),
}
assert(reader.weread, "real plugin instance")
UIManager:show(reader)
fastforward_ui_events()
assert(reader.document:getPageCount() > 1, "real downloaded EPUB must paginate")
reader.rolling:onGotoPage(1)
fastforward_ui_events()
Screen:shot(home .. "/../evidence/mock-page-1.png")
reader.rolling:onGotoPage(2)
fastforward_ui_events()
assert(reader:getCurrentPage() == 2, "real page turn")
Screen:shot(home .. "/../evidence/mock-page-2.png")
-- Session races use the real ReaderUI document, native scheduling, Client and
-- on-disk reading state. Only link availability is fixed; traffic still goes
-- through the fail-closed local mock, never to a production account.
local plugin = reader.weread
local sync = plugin.progress_sync
local online, connected = plugin.isNetworkOnline, plugin.isNetworkConnected
plugin.isNetworkOnline, plugin.isNetworkConnected = function() return true end, function() return true end
local function request_count(route_path, api)
    local chunks = {}
    local _, status = http.request{
        url = settings.mock_endpoint .. "/__state", proxy = settings.mock_endpoint,
        sink = require("ltn12").sink.table(chunks),
    }
    assert(status == 200, "mock state unavailable")
    local state = client:json_decode(table.concat(chunks))
    local count = 0
    assert(type(state.totals)=="table", "mock lifetime counters unavailable")
    for _, request in ipairs(state.totals) do
        if request.path == route_path and (not api or request.api == api) then count = count + request.count end
    end
    return count
end
local writes_before = request_count("/web/book/read")
local fixture_dir = debug.getinfo(1, "S").source:match("^@(.*/)")
local source_probe = dofile(fixture_dir .. "position_source_smoke.lua")
source_probe.reader(reader, fastforward_ui_events, home .. "/../evidence")
dofile(fixture_dir .. "native_authorization_smoke.lua")(plugin, request_count, fastforward_ui_events, home)
do dofile(fixture_dir .. "web_renewal_smoke.lua")(plugin, request_count, fastforward_ui_events, home, function(predicate)
    local socket=require("socket");local deadline=socket.gettime()+35
    while not predicate() do assert(socket.gettime()<deadline,"Web renewal scene deadline");fastforward_ui_events();socket.sleep(.01) end
end) end
assert(not next(plugin.source_position.pauses),'an earlier fixture left source acquisition paused')
local pulls_before = request_count("/web/book/getProgress") + request_count("/api/agent/gateway", "/book/getprogress")
local position = assert(sync:capture_local())
assert(sync:_upload_snapshot(position, "manual_sync", false), "queued progress upload did not start")
assert(sync:sync_now(), "queued progress pull did not start")
local account = plugin.settings:get("account")
plugin.settings:set("account", { name = "Other mock", user_vid = "900099", login_method = "mock" })
plugin.settings:flush()
plugin:onWeReadAccountChanged()
fastforward_ui_events()
assert(request_count("/web/book/read") == writes_before, "old upload reached replacement account")
assert(request_count("/web/book/getProgress") + request_count("/api/agent/gateway", "/book/getprogress") == pulls_before,
    "old pull reached replacement account")
assert(not sync.verified and not sync.uploading and not sync.pulling, "account transition retained a verified or busy session")
plugin.settings:set("account", account)
plugin.settings:flush()
plugin:onWeReadAccountChanged()
position = assert(sync:capture_local())
assert(sync:_upload_snapshot(position, "manual_sync", false), "current-account upload did not start")
pump_until(function() return not sync.uploading end)
assert(request_count("/web/book/read") > writes_before, "valid upload never reached real Client/HTTP")
local saved = plugin.settings:get("books")[position.book_id]
assert(saved.last_uploaded_position and not saved.pending_upload_position, "successful upload not persisted")
local source=assert(plugin.source_position:current())
local uploaded=saved.last_uploaded_position
assert(uploaded.wire_basis=='filtered_xhtml_utf16' and uploaded.chapter_uid==source.chapter_uid
    and uploaded.chapter_offset==source.chapter_offset and uploaded.source_position.file_id==source.file_id,
    'acknowledgement differs from current original-text coordinates')
local readback=require('weread.lib.progress_readback')
local expected=assert(readback.expected(position.book_id,uploaded))
assert(readback.check(plugin.client:get_web_progress(position.book_id),expected).matches,'independent original-text readback differs')
local remote = plugin.client:get_progress(position.book_id)
assert(remote.book.progress == uploaded.percent, "mock cloud readback differs from uploaded position")
local sync_config = plugin.settings:get("sync")
local old_pull, old_upload = sync_config.pull_on_open, sync_config.upload_on_close
sync_config.pull_on_open, sync_config.upload_on_close = true, true
plugin.settings:set("sync", sync_config)
writes_before = request_count("/web/book/read")
pulls_before = request_count("/web/book/getProgress")
assert(sync:_upload_snapshot(position, "manual_sync", false), "pre-suspend upload did not queue")
plugin:onSuspend()
local SourceTask=require('weread.lib.source_position_worker');local capture=SourceTask.capture
SourceTask.capture=function(...) require('socket').sleep(.6);return capture(...) end
local gateway_before=request_count('/api/agent/gateway','/book/getprogress')
local observed_wait,cancelled_wait,stale_checked=false,false,false
local old_wait
plugin:onResume()
pump_until(function()
    local job=sync.pull_job
    if job and job.source_wait then
        assert(request_count('/web/book/getProgress')==pulls_before
            and request_count('/api/agent/gateway','/book/getprogress')==gateway_before,
            'cloud comparison started before local source was ready')
        assert(request_count('/web/book/read')==writes_before,'source wait replayed a pre-suspend write')
        local worker=plugin.source_position.worker and plugin.source_position.worker.job
        if not cancelled_wait and worker then
            local pid=assert(worker.pid);old_wait=job.source_wait
            plugin:onSuspend()
            assert(not sync.pulling and not sync.pull_job and not plugin.source_position.worker.job
                and require('ffi/util').isSubProcessDone(pid),'suspend retained source wait or local child')
            cancelled_wait=true;plugin:onResume()
        elseif cancelled_wait and not stale_checked then
            old_wait.wake();old_wait.expire()
            assert(sync.pull_job==job and job.source_wait and sync.pulling,'old wait cancelled its replacement')
            observed_wait,stale_checked=true,true
        end
    end
    return not sync.pulling and sync.verified
end)
SourceTask.capture=capture
assert(observed_wait and not sync.pull_job,'source readiness wait was not observed or retained a timer')
assert(request_count('/web/book/getProgress')==pulls_before+1
    and request_count('/api/agent/gateway','/book/getprogress')==gateway_before+1,'wake comparison was not exactly one read per source')
assert(request_count("/web/book/read") == writes_before, "wake replayed pre-suspend local upload")
assert(request_count("/web/book/getProgress") > pulls_before and sync.verified,
    "wake did not compare cloud progress before reopening reporting gate")
sync_config.pull_on_open, sync_config.upload_on_close = old_pull, old_upload
plugin.settings:set("sync", sync_config)
plugin.settings:flush()
plugin.isNetworkOnline, plugin.isNetworkConnected = online, connected
print("PASS: real ReaderUI account/suspend cancels queued HTTP; valid upload persists/readbacks; wake compares cloud first")
local progress_report={result='PASS',synthetic_only=true,real_account_requests=0,
    fixture_suspend_resume_pairs_restored=true,queued_old_account_upload_cancelled=true,queued_old_account_pull_cancelled=true,
    source_coordinates_confirmed=true,independent_web_coordinates_match=true,gateway_percentage_matches=true,
    local_pending_cleared_after_confirmation=true,source_wait_before_cloud_observed=true,source_wait_max_seconds=35,
    fresh_reads_after_source_ready=2,pre_suspend_upload_not_replayed=true,verified_after_resume=true,
    source_wait_job_retired=true,source_wait_cancel_reaped_local_worker=true,stale_source_wait_callbacks_ignored=true}

local verify_reopened_file
if test_offline_time then
    verify_reopened_file = dofile(fixture_dir .. "offline_time_smoke.lua")(reader, request_count, fastforward_ui_events)
    dofile(fixture_dir .. "readtime_coverage_smoke.lua")(reader, request_count)
end
-- Exercise the real event loop, subprocesses, resume workspace, and packaging.
local completed, full_path, download_error
local function deadline()
    download_error = "full download exceeded 45 seconds"
    UIManager:quit()
end
UIManager:scheduleIn(45, deadline)
reader.weread.downloader:start(book, chapters, "full", {
    offer_read = false,
    silent_completion = true,
    on_complete = function(success, value)
        completed = success
        if success then full_path = value else download_error = tostring(value) end
        UIManager:unschedule(deadline)
        UIManager:quit()
    end,
})
UIManager:run()
assert(completed and full_path, download_error or "Downloader did not complete")
local file = assert(io.open(full_path, "rb"))
assert(file:read(2) == "PK", "full download must produce an EPUB ZIP")
file:close()
source_probe.full(full_path, book.bookId or book.book_id, chapters, home .. "/../evidence", client)
reader:onClose()
if verify_reopened_file then verify_reopened_file() end
UIManager:quit()
progress_report.full_download_and_source_routes=true
local result_file=assert(io.open(home..'/../evidence/standalone-progress.json','wb'))
assert(result_file:write(client:json_encode(progress_report)));result_file:close()
print("PASS: mock HTTP -> real Client/Content/Downloader -> EPUB with image/footnote -> ReaderUI -> page 2")
print("EPUB: " .. path)
print("FULL EPUB: " .. full_path)
