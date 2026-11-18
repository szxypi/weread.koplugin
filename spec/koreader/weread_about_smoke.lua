-- Native about dialog, attribution and dismissal; no network or accounts.
local repo, evidence = assert(arg[1]), assert(arg[2])
require("setupkoenv")
package.path = repo .. "/?.lua;" .. package.path
local home = assert(os.getenv("KO_HOME"))
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(home .. "/settings.reader.lua")
G_reader_settings:saveSetting("language", "zh_CN")
require("gettext").changeLang("zh_CN")
local UIManager = require("ui/uimanager")
local Device = require("device")
require("document/canvascontext"):init(Device)
local Screen = Device.screen
local BB = require("ffi/blitbuffer")
local Menu = require("weread.ui.menu")
UIManager:setRunForeverMode()
UIManager:setInputTimeout(0)

for _, size in ipairs({ { 600, 800 }, { 800, 600 }, { 1264, 1680 } }) do
    local width, height = size[1], size[2]
    Screen.bb:free()
    Screen.bb = BB.new(width, height)
    Menu.showAbout({ version = "1.7.0" })
    UIManager:forceRePaint()
    local viewer = UIManager._window_stack[#UIManager._window_stack].widget
    assert(viewer.text:find("项目地址：https://github.com/szxypi/weread.koplugin", 1, true))
    assert(viewer.text:find("原项目：https://github.com/finlater/weread.koplugin", 1, true))
    assert(viewer.text:find("许可证：AGPL-3.0", 1, true))
    assert(not viewer.text:find("闭源版", 1, true))
    local frame = viewer.movable:getSize()
    assert(frame.w <= width and frame.h <= height, "about dialog extends beyond the screen")
    Screen:shot(evidence .. "/about-" .. width .. "x" .. height .. ".png")
    UIManager:close(viewer)
    UIManager:handleInput()
    assert(#UIManager._window_stack == 0, "about dialog did not close")
end
UIManager:quit()
print("PASS: repository, attribution and license at three screen sizes")
