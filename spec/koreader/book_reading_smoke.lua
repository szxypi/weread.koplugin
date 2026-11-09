-- The plugin's normal selection -> Read -> native ReaderUI -> sync workflow.
-- All HTTP is fail-closed synthetic traffic; no production account is used.
require("setupkoenv")
io.stdout:setvbuf("no")
local home, evidence = assert(os.getenv("KO_HOME")), assert(os.getenv("WEREAD_EVIDENCE"))
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(home .. "/settings.reader.lua")
G_reader_settings:saveSetting("extra_plugin_paths", { home .. "/plugins" })
G_reader_settings:saveSetting("language", "zh_CN")
G_reader_settings:saveSetting("color_rendering", false)
require("gettext").changeLang("zh_CN")
package.path = home .. "/plugins/weread.koplugin/?.lua;" .. package.path
local Device = require("device")
require("document/canvascontext"):init(Device)
assert(require("weread.lib.mock_environment").save{
    enabled = true, host = "127.0.0.1", port = assert(tonumber(os.getenv("WEREAD_MOCK_PORT"))),
})
local Loader = require("pluginloader")
Loader.enabled_plugins, Loader.disabled_plugins, Loader.loaded_plugins = {}, {}, {}
for _, entry in ipairs(Loader:_discover()) do if entry.name == "weread" then Loader:_load{ entry } end end
assert(#Loader.enabled_plugins == 1, "candidate plugin not loaded")
package.path = home .. "/plugins/weread.koplugin/?.lua;" .. package.path
local UI = require("ui/uimanager")
UI:setRunForeverMode(); UI:setInputTimeout(0)
local Screen, socket, json = Device.screen, require("socket"), require("json")
local FM, Reader = require("apps/filemanager/filemanager"), require("apps/reader/readerui")
local function tick() UI:shiftScheduledTasksBy(-1e9); UI:setInputTimeout(0); UI:handleInput() end
local function pump(predicate)
    local deadline = socket.gettime() + 40
    while not predicate() do assert(socket.gettime() < deadline, "reading flow deadline"); tick(); socket.sleep(.01) end
end
local function shot(name) UI:forceRePaint(); Screen:shot(evidence .. "/" .. name .. ".png") end
local function press(view, label)
    for _, buttons in ipairs({ view._action_buttons or {}, view._footer_actions or {} }) do
        for _, button in ipairs(buttons) do
            if button.text == require("weread.lib.plugin_util").tr(label) then
                assert(button.enabled ~= false, "disabled reading action"); button.callback(); return
            end
        end
    end
    error("missing action: " .. label)
end
local function clean_popups(base)
    while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget() ~= base do UI:close(UI:getTopmostVisibleWidget()) end
end
FM:showFiles(home)
local fm = assert(FM.instance)
local plugin = assert(fm.weread)
local offline = os.getenv("WEREAD_READING_REOPEN") == "1"
plugin.isNetworkOnline = function() return not offline end
plugin.isNetworkConnected = function() return not offline end
if offline then
    local file = assert(io.open(evidence .. "/reading-checkpoint.json", "rb"))
    local expected = json.decode(file:read("*a")); file:close()
    plugin:showHome()
    local view = assert(plugin.shelf_view)
    local books = view.books
    local book
    for _, row in ipairs(books) do if tostring(row.bookId or row.book_id) == expected.book_id then book = row end end
    assert(book and book._cached and plugin.settings:get_book(expected.book_id).cached_chapters, "offline book/cache missing")
    view.on_select(book)
    pump(function() return Reader.instance and Reader.instance.document.file == expected.path end)
    local reader = Reader.instance
    assert(reader.document:isXPointerInCurrentPage(expected.xpointer), "offline reopen lost native position")
    assert(reader.weread.settings:get_book(expected.book_id).last_uploaded_position.chapter_uid == expected.chapter_uid,
        "fresh process lost acknowledged progress")
    shot("reading-offline-reopen")
    clean_popups(reader); reader:onClose(false)
    print("PASS: fresh process -> plugin Home cached selection -> native reader restored position; zero HTTP")
    os.exit(0)
end

plugin:showHome()
assert(plugin.shelf_view and plugin.shelf_view.on_refresh, "home is unavailable")
plugin.shelf_view.on_refresh()
pump(function() return #(plugin.library_db:getShelf() or {}) > 0 and not plugin.busy_message end)
plugin:closeWeReadUI(); plugin:showHome()
shot("reading-home")
local books = plugin.library_db:getShelf()
local selected
for _, book in ipairs(books) do if tostring(book.bookId or book.book_id) == "900001" then selected = book end end
assert(selected, "synthetic shelf book missing")
plugin.shelf_view.on_select(selected)
pump(function() return plugin._book_detail_view and not plugin.book_metadata_context end)
shot("reading-uncached-detail")
press(plugin._book_detail_view, "▤ Read")
assert(plugin.book_reading_context and not Reader.instance, "uncached Read skipped async preparation")
shot("reading-preparing")
plugin:cancelBookReading()
for _i = 1, 4 do tick() end
assert(not Reader.instance and not plugin.downloader._active_job, "cancelled preparation opened reader")

plugin:closeWeReadUI(); plugin:showBookshelf()
plugin.shelf_view.on_select(selected, "books")
pump(function() return plugin._book_detail_view and not plugin.book_metadata_context end)
press(plugin._book_detail_view, "▤ Read")
plugin:onSuspend()
for _i = 1, 4 do tick() end
assert(not plugin.book_reading_context and not Reader.instance, "suspended preparation opened reader")

press(plugin._book_detail_view, "▤ Read")
pump(function() return plugin.downloader._active_job ~= nil end)
shot("reading-download-cancel")
plugin:cancelBookReading()
pump(function() return not plugin.downloader._active_job end)
assert(not Reader.instance, "cancelled download opened reader")

press(plugin._book_detail_view, "▤ Read")
plugin._book_detail_view:onClose()
for _i = 1, 4 do tick() end
assert(not plugin.book_reading_context and not Reader.instance, "closed detail reopened reader")

plugin:closeWeReadUI(); plugin:showBookstore()
press(plugin.shelf_view, "For you")
pump(function() return not plugin.discovery_loading and plugin.discovery_state and #plugin.discovery_state.books > 0 end)
shot("reading-bookstore")
local store_book
for _, book in ipairs(plugin.discovery_state.books) do if tostring(book.bookId or book.book_id) == "900001" then store_book = book end end
assert(store_book, "bookstore did not return target")
plugin.shelf_view.on_select(store_book)
pump(function() return plugin._book_detail_view and not plugin.book_metadata_context end)
press(plugin._book_detail_view, "▤ Read")
pump(function() return Reader.instance and Reader.instance.weread and Reader.instance.document:getPageCount() > 1 end)
local reader = Reader.instance
assert(reader.document.file:match("%.epub$"), "Read did not open the native EPUB engine")
assert(not plugin.book_reading_context and not plugin._book_detail_view and not plugin.shelf_view,
    "plugin views survived native handoff")
shot("reading-native-reader")
reader.rolling:onGotoPage(2); tick()
assert(reader:getCurrentPage() == 2, "native page turn failed")
local current = reader.weread
current.isNetworkOnline, current.isNetworkConnected = function() return true end, function() return true end
assert(current:onWeReadSyncProgress(), "reader sync action failed")
pump(function() return not current.progress_sync.pulling end)
local choice = UI:getTopmostVisibleWidget()
if choice and choice.cancel_text == require("weread.lib.plugin_util").tr("Keep KOReader progress") then
    shot("reading-sync-choice"); choice.cancel_callback(); UI:close(choice)
end
pump(function() return not current.progress_sync.uploading end)
local book_id = assert(current:detectWeReadBook())
local saved = assert(current.settings:get_book(book_id))
assert(saved.last_uploaded_position and not saved.pending_upload_position, "sync action did not persist acknowledgement")
local remote = current.client:get_progress(book_id)
assert(remote.book.progress == saved.last_uploaded_position.percent, "synthetic cloud readback differs")
shot("reading-sync-result")
local checkpoint = { book_id = book_id, path = reader.document.file,
    xpointer = reader.document:getXPointer(), chapter_uid = saved.last_uploaded_position.chapter_uid,
    synthetic_only = true, native_reader = true, page = reader:getCurrentPage() }
clean_popups(reader); reader:onClose(false)
local output = assert(io.open(evidence .. "/reading-checkpoint.json", "wb"))
assert(output:write(json.encode(checkpoint))); output:close()
print("PASS: plugin Home/shelf/store -> uncached Read -> cancellable preparation -> download -> native ReaderUI -> page turn -> sync -> synthetic readback")
