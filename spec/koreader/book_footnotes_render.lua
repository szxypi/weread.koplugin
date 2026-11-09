-- Run from a built KOReader runtime with a fresh, isolated KO_HOME:
-- Install/link the candidate at $KO_HOME/plugins/weread.koplugin and create /evidence.
-- EMULATE_READER=1 ./luajit /repo/spec/koreader/book_footnotes_render.lua /repo /evidence
-- Uses the real SDL window, ReaderUI, CREngine, link gestures and MuPDF popup.
local repo, evidence = assert(arg[1]), assert(arg[2])
local home = assert(os.getenv("KO_HOME"))
require("setupkoenv")
io.stdout:setvbuf("no")
package.path = repo .. "/?.lua;" .. package.path
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(home .. "/settings.reader.lua")
G_reader_settings:saveSetting("language", "zh_CN")
G_reader_settings:saveSetting("color_rendering", false)
G_reader_settings:saveSetting("extra_plugin_paths", { home .. "/plugins" })
G_reader_settings:saveSetting("footnote_link_in_popup", false)
G_reader_settings:saveSetting("tap_to_follow_links", true)
G_reader_settings:saveSetting("copt_font_size", 24)
require("gettext").changeLang("zh_CN")
require("ui/bidi").setup("zh_CN")
local Device = require("device")
require("document/canvascontext"):init(Device)
assert(require("weread.lib.mock_environment").save{
    enabled = true, host = "127.0.0.1", port = assert(tonumber(os.getenv("WEREAD_MOCK_PORT"))),
})
local Loader = require("pluginloader")
Loader.enabled_plugins, Loader.disabled_plugins, Loader.loaded_plugins = {}, {}, {}
for _, entry in ipairs(Loader:_discover()) do if entry.name == "weread" then Loader:_load{ entry } end end
assert(#Loader.enabled_plugins == 1)
package.path = repo .. "/?.lua;" .. package.path
local Screen = Device.screen
local UIManager = require("ui/uimanager")
local Geom = require("ui/geometry")
local Content = require("weread.lib.content")
local Footnotes = require("weread.lib.footnotes")
local ReaderUI = require("apps/reader/readerui")
local Registry = require("document/documentregistry")
local tr = require("weread.lib.i18n").tr
local legacy_settings = require("luasettings"):open(home .. "/settings/weread-mock.lua")
legacy_settings:saveSetting("cache", { book_footnotes_in_popup = true })
legacy_settings:flush()

local chapter = { chapterUid = 178, chapterIdx = 1, title = "脚注行为验证" }
local note = "甲脚注：标准脚注应能点击弹框，也能跳转到章末。"
local shared_note = "丁脚注：两次引用应共享一份内容，并保留两个返回链接。"
local source = '<p>正文中的三个脚注：<img class="qqreader-footnote" alt="' .. note .. '"/>'
    .. '<a epub:type="noteref" href="#note-b">[乙]</a>'
    .. '<img class="qqreader-footnote" alt="丙脚注：第三条说明。"/>'
    .. '<a id="shared-a" epub:type="noteref" href="#shared-note">[丁]</a>'
    .. '<a id="shared-b" epub:type="noteref" href="#shared-note">[丁]</a>'
    .. '<a href="#shared-note">原始注释链接</a></p>'
for index = 1, 18 do
    source = source .. '<p>正文第' .. index .. '段。'
        .. string.rep("这段正文用于观察页下注是否挤占阅读空间，以及关闭页下注后正文能否恢复。", 4) .. '</p>'
end
source = source .. '<p class="note" id="note-b">乙脚注：'
    .. string.rep("较长的说明用于检查脚注分页和弹框边界。", 8) .. '</p>'
    .. '<aside id="shared-note" epub:type="footnote"><p>' .. shared_note .. '</p></aside>'
local scan = Footnotes.scan_chapter(source, chapter)
local body, stats = Footnotes.transform_chapter(source, scan,
    Footnotes.build_book_index({ ["178"] = scan }, { chapter }))
assert(stats.image_notes == 2 and stats.converted == 3 and stats.removed_note_blocks == 2 and Footnotes.validate(body))
local function occurrences(text, value)
    local count, pos = 0, 1
    while true do local first = text:find(value, pos, true); if not first then return count end; count = count + 1; pos = first + #value end
end
assert(occurrences(body, shared_note) == 1 and occurrences(body, "乙脚注：") == 1, "generated EPUB duplicated source definitions")
local path = Content.save_chapter_epub({}, {
    bookId = "footnotes-standard", title = "standard", cache_dir = evidence,
}, chapter, body, {}, Footnotes.FOOTNOTES_CSS)

local reader, popup, normal_height, hide_item
local function open()
    if reader then reader:onClose() end
    reader = ReaderUI:new{ dimen = Screen:getSize(), document = Registry:openDocument(path) }
    assert(reader.weread, "candidate plugin must be loaded")
    assert(reader.weread.settings:get("cache").book_footnotes_in_popup == nil,
        "obsolete footnote setting was not removed")
    UIManager:show(reader)
    reader.rolling:onGotoPage(1)
end
local function inpage(enabled)
    reader.styletweak:onToggleStyleTweak({ "footnote-inpage_epub", enabled }, nil, true)
    reader.rolling:onGotoPage(1)
end
local function popup_enabled(enabled)
    local item = reader.link:getFootnoteSettingsMenuTable()[1]
    if item.checked_func() ~= enabled then item.callback() end
    assert(item.checked_func() == enabled)
end
local function note_gesture(index)
    local link = assert(reader.document:getPageLinks()[index or 1], "missing footnote reference")
    local rect = assert(link.segments[1])
    return { pos = Geom:new{
        x = math.floor((rect.x0 + rect.x1) / 2), y = math.floor((rect.y0 + rect.y1) / 2),
    } }
end
local function tap_note(index)
    reader.link:onTap(nil, note_gesture(index))
end
local function check_popup(expected)
    expected = expected or note
    popup = nil
    for widget in UIManager:topdown_widgets_iter() do
        if widget.html and widget.htmlwidget then popup = widget; break end
    end
    assert(popup and occurrences(popup.html, expected) == 1, "missing or duplicated native footnote popup")
    assert(not popup.html:find("乙脚注", 1, true) and not popup.html:find("丙脚注", 1, true),
        "popup included another footnote")
    assert(reader:getCurrentPage() == 1, "popup moved the reading position")
end
local function shot(name)
    UIManager:forceRePaint()
    Screen:shot(evidence .. "/" .. name .. ".png")
end
local function page_height()
    return reader.document._document:getPageHeight(1)
end
local function menu_select(menu, text)
    for _, item in ipairs(menu.item_table) do
        if item.text == tr(text) then menu:onMenuSelect(item); return end
    end
    error("missing menu item: " .. text)
end

local steps = {
    function() open() end,
    function()
        reader.menu:onShowMenu(4)
        local menu = reader.menu.menu_container[1]
        menu_select(menu, "WeRead [MOCK]")
        menu_select(menu, "Settings")
        menu_select(menu, "Download settings")
        for _, item in ipairs(menu.item_table) do
            assert(item.text ~= "隐藏脚注文本" and item.text ~= "Hide footnote text",
                "obsolete footnote menu item is still visible")
        end
        shot("00-download-settings")
        reader.menu:onCloseReaderMenu()
    end,
    function() inpage(false) end,
    function()
        normal_height = page_height()
        assert(#(reader.document:findAllText(shared_note, false, 0, 10, false, 0) or {}) == 1,
            "native DOM contains duplicate note text")
        shot("01-standard-inpage-off")
        popup_enabled(true)
        tap_note()
    end,
    function()
        check_popup()
        shot("02-standard-popup")
        popup:onClose()
        tap_note(4); check_popup(shared_note); shot("02-shared-popup-first"); popup:onClose()
        tap_note(5); check_popup(shared_note); shot("02-shared-popup-second"); popup:onClose()
        local first = assert(reader.link:getLinkFromGes(note_gesture(4))).xpointer
        local second = assert(reader.link:getLinkFromGes(note_gesture(5))).xpointer
        assert(type(first) == "string" and first ~= "" and first == second and reader.document:isXPointerInDocument(first),
            "two references did not share a valid native target")
        popup_enabled(false)
        local old_target = assert(reader.link:getLinkFromGes(note_gesture(6))).xpointer
        tap_note(6)
        assert(reader:getCurrentPage() > 1 and reader.document:isXPointerInCurrentPage(old_target),
            "ordinary original-anchor link did not reach the relocated note")
        reader.link:onGoBackLink()
        assert(reader:getCurrentPage() == 1, "ordinary original-anchor link did not return to its source")
        tap_note()
    end,
    function()
        assert(reader:getCurrentPage() > 1, "disabling popup must follow the chapter-end link")
        shot("03-standard-chapter-end")
        reader.link:onGoBackLink()
    end,
    function()
        assert(reader:getCurrentPage() == 1, "back must restore the reference page")
        inpage(true)
    end,
    function()
        assert(page_height() < normal_height, "native in-page tweak did not add page-bottom notes")
        shot("04-standard-inpage-on")
        popup_enabled(true)
        tap_note()
    end,
    function()
        check_popup()
        shot("05-standard-inpage-and-popup")
        popup:onClose()
        inpage(false)
    end,
    function()
        assert(page_height() == normal_height, "disabling native in-page notes did not restore layout")
        inpage(true)
        reader.styletweak:onToggleStyleTweak({ "inpage_footnote_combine_non_linear", true }, nil, true)
        open()
    end,
    function()
        assert(reader.document:hasNonLinearFlows(), "native tweak did not mark the chapter-end notes")
        local items = {}
        reader.rolling:addToMainMenu(items)
        hide_item = assert(items.hide_nonlinear_flows, "missing native hide menu item")
        assert(hide_item.enabled_func() and not hide_item.checked_func())
        hide_item.callback()
        assert(hide_item.checked_func() and reader.document:hasHiddenFlows())
        reader.menu:onShowMenu(1)
        shot("06-native-hide-menu")
        reader.menu:onCloseReaderMenu()
    end,
    function()
        local document = reader.document
        local last_linear = document:getLastLinearPage()
        assert(last_linear < document:getPageCount(), "chapter-end notes were not separated from normal pages")
        reader.rolling:onGotoPage(1)
        for _ = 1, document:getPageCount() do
            local page = reader:getCurrentPage()
            assert(document:getPageFlow(page) == 0, "normal page turning entered hidden notes")
            if document:getNextPage(page) == 0 then break end
            reader.rolling:onGotoViewRel(1)
        end
        assert(reader:getCurrentPage() == last_linear, "normal page turning did not stop before the notes")
        shot("07-native-hidden-chapter-end")
        reader.rolling:onGotoPage(1)
        popup_enabled(true)
        tap_note()
    end,
    function()
        check_popup()
        shot("08-native-hidden-popup")
        popup:onClose()
        popup_enabled(false)
        tap_note()
    end,
    function()
        assert(reader.document:getPageFlow(reader:getCurrentPage()) > 0,
            "hidden footnotes must remain accessible through their links")
        shot("09-native-hidden-link-target")
        reader.link:onGoBackLink()
        assert(reader:getCurrentPage() == 1)
        hide_item.callback()
        assert(not hide_item.checked_func() and not reader.document:hasHiddenFlows())
        reader.rolling:onGotoPage(reader.document:getPageCount())
    end,
    function()
        shot("10-native-restored-chapter-end")
        reader:onClose()
        reader = nil
    end,
}
local failure, index = nil, 0
local function advance()
    index = index + 1
    if not steps[index] then UIManager:quit(); return end
    local ok, err = xpcall(steps[index], debug.traceback)
    if not ok then
        failure = err
        shot("failure")
        UIManager:quit()
        return
    end
    UIManager:scheduleIn(index == 1 and 3 or 0.6, advance)
end
advance()
UIManager:run()
assert(not failure, failure)
assert(index >= #steps, "simulator stopped before finishing the behavior checks")
local result = assert(io.open(evidence .. "/footnotes-result.json", "wb"))
assert(result:write(require("json").encode{ result = "PASS", synthetic_only = true,
    note_text_once = true, shared_references = 2, generated_definitions = 4, native_dom_matches = 1,
    native_taps = true, popup_once = true, both_shared_popups = true, jump_and_return = true,
    legacy_alias_native_jump = true,
    native_inpage_toggle = true, native_hidden_flows = true, restore_display = true })); result:close()
print("PASS: menu removal, legacy setting cleanup, native in-page/popup toggles, native chapter-end hiding, link access and restoration")
