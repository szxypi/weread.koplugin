-- Synthetic native picker: bounded current window, clear, paging and geometry.
require('ffi').log=function() end
require('setupkoenv')
assert(os.getenv('WEREAD_SYNTHETIC')=='1')
package.path=assert(arg[1])..'/?.lua;'..package.path
assert(dofile(arg[1]..'/spec/koreader/offline_network_guard.lua')())
G_reader_settings=require('luasettings'):wrap({})
G_reader_settings:saveSetting('language','zh_CN')
G_defaults=require('luadefaults'):open()
require('gettext').changeLang('zh_CN')
local Device=require('device');require('document/canvascontext'):init(Device)
local screen=Device.screen
local UI=require('ui/uimanager');UI:setRunForeverMode();UI:setInputTimeout(0)
local socket=require('socket')
local function until_true(check)
    local deadline=socket.gettime()+8
    while not check() do
        UI:setInputTimeout(0);UI:handleInput();socket.sleep(0.01)
        assert(socket.gettime()<deadline,'picker timeout')
    end
end
local chapters={}
for i=1,30 do chapters[i]={chapterUid=tostring(i),title='第'..i..'章 示例内容',level=1} end
local model=require('weread.lib.chapter_selection'):new(chapters,{},nil,9)
model:toggle(model.by_uid['1'])
local selected
local picker=require('weread.ui.annotation_chapter_picker').show{
    model=model,book_title='合成测试书籍',on_select=function(value) selected=value end}
UI:forceRePaint()
local size=picker[1]:getSize()
assert(size.w==screen:getWidth() and size.h==screen:getHeight(),
    string.format('picker bounds %dx%d for screen %dx%d; title=%d hint=%d body=%d action=%d quick=%d+%d',
        size.w,size.h,screen:getWidth(),screen:getHeight(),picker.title_bar:getSize().w,picker.hint:getSize().w,
        picker.body:getSize().w,picker.actions:getSize().w,picker.quick_add:getSize().w,picker.quick_clear:getSize().w))
assert(picker.quick_add.enabled and picker.quick_clear.enabled)
assert(picker.quick_add.dimen.x+picker.quick_add.dimen.w<=picker.quick_clear.dimen.x)
assert(picker.quick_add.dimen.y+picker.quick_add.dimen.h<=picker.action_button.dimen.y)
local footer=picker.layout[#picker.layout]
assert(picker.action_button.dimen.y+picker.action_button.dimen.h<=footer[1].dimen.y)
if arg[2] then screen:shot(arg[2]);local shot=assert(io.open(arg[2],'rb'));assert(shot:close()) end
picker.quick_add:onTapSelectButton()
until_true(function() return model.count==11 end)
assert(model.by_uid['1'].selected and model.by_uid['9'].selected and model.by_uid['18'].selected
    and not model.by_uid['19'].selected)
picker.quick_add:onTapSelectButton()
for _=1,10 do UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01) end
assert(model.count==11)
picker.quick_clear:onTapSelectButton()
until_true(function() return model.count==0 end)
assert(not picker.quick_clear.enabled)
picker.quick_add:onTapSelectButton()
until_true(function() return model.count==10 end)
picker:onNextPage();picker:onPrevPage()
UI:forceRePaint()
picker.action_button:onTapSelectButton()
until_true(function() return selected~=nil end)
assert(#selected==10 and selected[1]==chapters[9] and selected[10]==chapters[18])
print('PASS: quick chapter selection, preserved choices, clear and native layout')
UI:quit()
