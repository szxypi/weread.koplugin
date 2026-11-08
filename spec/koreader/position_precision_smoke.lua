-- Real engine and ReaderUI: reproduce integer-percent drift on a long EPUB.
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
local chapters = {
    { chapterUid = 1, chapterIdx = 1, title = "第一章", wordCount = 150000 },
    { chapterUid = 2, chapterIdx = 2, title = "第二章", wordCount = 150000 },
}
local body = {}
for i = 1, 2000 do
    body[#body + 1] = "<p>段落" .. i .. "：阅读位置应随实际页面变化，页脚缓存不会改变当前页面。"
        .. "这是合成的长篇阅读测试，用于检查本地跳转精度。</p>"
end
local book = { book_id = "900001", bookId = "900001", title = "本机进度精度测试", author = "本地合成数据", chapters = chapters }
local path = Content.save_book_epub(settings, book, chapters,
    { ["1"] = table.concat(body), ["2"] = table.concat(body) }, "full")
book.cached_file, book.cached_chapters = path, { ["1"] = path, ["2"] = path }
assert(Content.save_catalog_cache(require("weread.lib.client"):new(settings), settings, book, chapters))
settings:set("books", { ["900001"] = book })
settings:flush()
local UIManager = require("ui/uimanager")
local reader = require("apps/reader/readerui"):new{
    dimen = Device.screen:getSize(), document = require("document/documentregistry"):openDocument(path),
}
UIManager:show(reader)
local function flush()
    UIManager:shiftScheduledTasksBy(-1e9)
    UIManager:setInputTimeout(0)
    UIManager:handleInput()
end
flush()
local document, plugin = reader.document, assert(reader.weread)
local pages = document:getPageCount()
assert(pages > 200, "long EPUB did not create enough pages")
local chosen, fraction, old_page
for page = math.floor(pages * 0.2), math.floor(pages * 0.8) do
    local candidate = (page + 0.25) / pages
    local old_percent = math.floor(candidate * 100 + 0.5)
    reader.rolling:onGotoPercent(old_percent)
    local actual = document:getCurrentPage()
    if math.abs(actual - page) >= 2 then chosen, fraction, old_page = page, candidate, actual; break end
end
assert(chosen, "fixture did not reproduce multiple-page rounding loss")
local ReaderPosition = require("weread.lib.reader_position")
assert(not ReaderPosition.goto_fraction(require("ui/widget/container/widgetcontainer"):new{}, fraction),
    "unhandled native event was accepted")
assert(ReaderPosition.goto_fraction({ handleEvent = function(_self, event) return reader:handleEvent(event) end },
    (chosen + 1.25) / pages), "native event fallback failed")
assert(document:getCurrentPage() == chosen + 1, "native event fallback rounded the target")
assert(plugin.progress_sync.goto_fraction(fraction), "fractional native jump failed")
assert(document:getCurrentPage() == chosen, "fractional target landed on wrong page")
reader.view.footer.percent_finished = 0.99
local local_position = assert(plugin.progress_sync:capture_local())
assert(math.abs(local_position.fraction - chosen / pages) < 1e-9, "capture reused stale footer")
UIManager:forceRePaint()
Device.screen:shot(evidence .. "/position-page.png")
local page_result = { total_pages = pages, requested_fraction = fraction,
    old_rounded_page = old_page, actual_page = chosen, captured_fraction = local_position.fraction }
reader:handleEvent(require("ui/event"):new("SetViewMode", "scroll"))
flush()
assert(reader.view.view_mode == "scroll", "native scroll mode not set")
local scroll_target = 0.503125
assert(plugin.progress_sync.goto_fraction(scroll_target), "scroll jump failed")
local height, at = document.info.doc_height, document:getCurrentPos()
assert(math.abs(at - height * scroll_target) <= 1, "scroll target was rounded to integer percent")
reader.view.footer.percent_finished = 0.01
local_position = assert(plugin.progress_sync:capture_local())
assert(math.abs(local_position.fraction - at / height) < 1e-9, "scroll capture used stale footer/page position")
UIManager:forceRePaint()
Device.screen:shot(evidence .. "/position-scroll.png")
local file = assert(io.open(evidence .. "/navigation.json", "w"))
file:write(plugin.client:json_encode({ page = page_result, scroll = {
    requested_fraction = scroll_target, document_height = height, actual_position = at,
    captured_fraction = local_position.fraction }, public_network_used = false }))
file:close()
print("PASS: native " .. pages .. "-page EPUB; integer rounding landed on " .. old_page
    .. ", fractional target landed on " .. chosen .. "; stale footer ignored in page/scroll modes")
reader:onClose()
UIManager:quit()
