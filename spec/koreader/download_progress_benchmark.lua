require('ffi').log=function() end
require('setupkoenv')
local home=assert(os.getenv('KO_HOME'))
package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
G_reader_settings:saveSetting('language','zh_CN')
require('gettext').changeLang('zh_CN')
local Device=require('device');require('document/canvascontext'):init(Device)
local UI=require('ui/uimanager')
local socket=require('socket')
local old=arg[1]=='baseline'
local Dialog=old and assert(loadfile(arg[2]))() or require('weread.ui.download_dialog')
local dialog=Dialog:new{title='Saving books: 0/100',progress_max=100,refresh_time_seconds=3}
dialog:show();UI:forceRePaint()
local original=UI.forceRePaint
local repaints=0
UI.forceRePaint=function(self,...)
    repaints=repaints+1
    return original(self,...)
end
local function update(i)
    local title=('Saving books: %d/100'):format(i)
    if old then dialog:reportProgress(i);dialog:setTitle(title)
    else dialog:reportProgress(i,title) end
end
local function flush()
    if dialog._progress_refresh then
        local deadline=socket.gettime()+5
        while dialog._progress_refresh do
            assert(socket.gettime()<deadline,'scheduled progress update did not run')
            UI:setInputTimeout(0);UI:handleInput();socket.sleep(0.01)
        end
    end
end
for i=1,30 do update(i) end
flush()
assert(dialog.title=='Saving books: 30/100' and dialog.progress_bar.percentage==0.3)
original(UI);Device.screen:shot(assert(os.getenv('WEREAD_PROGRESS_SHOTS'))..'/middle.png')
for i=31,100 do update(i) end
flush()
assert(dialog.title=='Saving books: 100/100' and dialog.progress_bar.percentage==1)
original(UI);Device.screen:shot(assert(os.getenv('WEREAD_PROGRESS_SHOTS'))..'/complete.png')
local stale
if not old then
    dialog:reportProgress(50,'Saving books: 50/100')
    stale=dialog._progress_refresh
    assert(stale,'pending update not scheduled')
end
dialog:close()
local closed_repaints=repaints
if stale then
    stale();dialog:reportProgress(100,'late');dialog:setTitle('late')
    assert(repaints==closed_repaints,'closed dialog repainted')
end
UI.forceRePaint=original
print('\nWEREAD_PROGRESS_BENCHMARK='..require('json').encode({result='PASS',repaints=repaints,
    cancel_safe=not old and stale~=nil or old})..'\n')
