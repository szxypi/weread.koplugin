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
    for _, request in ipairs(state.requests) do
        if request.path == route_path and (not api or request.api == api) then count = count + 1 end
    end
    return count
end
local writes_before = request_count("/web/book/read")
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
fastforward_ui_events()
assert(request_count("/web/book/read") > writes_before, "valid upload never reached real Client/HTTP")
local saved = plugin.settings:get("books")[position.book_id]
assert(saved.last_uploaded_position and not saved.pending_upload_position, "successful upload not persisted")
assert(saved.last_uploaded_position.chapter_uid == position.chapter_uid, "acknowledgement changed chapter identity")
local remote = plugin.client:get_progress(position.book_id)
assert(remote.book.progress == position.percent, "mock cloud readback differs from uploaded position")
local sync_config = plugin.settings:get("sync")
local old_pull, old_upload = sync_config.pull_on_open, sync_config.upload_on_close
sync_config.pull_on_open, sync_config.upload_on_close = true, true
plugin.settings:set("sync", sync_config)
writes_before = request_count("/web/book/read")
pulls_before = request_count("/web/book/getProgress")
assert(sync:_upload_snapshot(position, "manual_sync", false), "pre-suspend upload did not queue")
plugin:onSuspend()
plugin:onResume()
fastforward_ui_events()
assert(request_count("/web/book/read") == writes_before, "wake replayed pre-suspend local upload")
assert(request_count("/web/book/getProgress") > pulls_before and sync.verified,
    "wake did not compare cloud progress before reopening reporting gate")
sync_config.pull_on_open, sync_config.upload_on_close = old_pull, old_upload
plugin.settings:set("sync", sync_config)
plugin.settings:flush()
plugin.isNetworkOnline, plugin.isNetworkConnected = online, connected
print("PASS: real ReaderUI account/suspend cancels queued HTTP; valid upload persists/readbacks; wake compares cloud first")
local verify_reopened_file
if test_offline_time then
    local fixture_dir = debug.getinfo(1, "S").source:match("^@(.*/)")
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
reader:onClose()
if verify_reopened_file then verify_reopened_file() end
UIManager:quit()
print("PASS: mock HTTP -> real Client/Content/Downloader -> EPUB with image/footnote -> ReaderUI -> page 2")
print("EPUB: " .. path)
print("FULL EPUB: " .. full_path)
