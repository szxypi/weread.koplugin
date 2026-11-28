require('ffi').log=function() end
require('setupkoenv')
local home=assert(os.getenv('KO_HOME'))
package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
G_reader_settings:saveSetting('language','zh_CN');require('gettext').changeLang('zh_CN')
local Device=require('device');require('document/canvascontext'):init(Device)
local UI=require('ui/uimanager')
local old=arg[1]=='baseline'
local Dialog=old and assert(loadfile(arg[2]))() or require('weread.ui.download_dialog')
local clicked=0
local dialog=Dialog:new{title='正在同步 0/100',description='合成进度测试，可随时取消。',progress_max=100,
    refresh_time_seconds=0,buttons={{{text='取消',callback=function() clicked=clicked+1 end}}}}
dialog:show();UI:forceRePaint()
local shots=assert(os.getenv('WEREAD_PROGRESS_SHOTS'))
Device.screen:shot(shots..'/0.png')
local regions={}
local original=UI._refresh
UI._refresh=function(self,mode,region,...)
    if mode=='fast' then
        local rect=region or Device.screen:getSize()
        regions[#regions+1]={x=rect.x,y=rect.y,w=rect.w,h=rect.h}
    end
    return original(self,mode,region,...)
end
local actions={
    function() dialog:reportProgress(10,'正在同步 10/100') end,
    function() dialog:setTitle('正在处理非常长的合成标题：1234567890 进度更新') end,
    function() dialog:reportProgress(70,'正在同步 70/100') end,
    function() dialog:reportProgress(5,'正在重试 5/100') end,
    function() dialog:reportProgress(100,'已完成 100/100') end,
}
for i,action in ipairs(actions) do
    local before=#regions;action()
    assert(#regions==before+1,'expected one fast refresh')
    Device.screen:shot(shots..'/'..i..'.png')
end
local rotation_fallback=false
if not old then
    local rotation=Device.screen:getRotationMode()
    Device.screen:setRotationMode((rotation+1)%4)
    local screen=Device.screen:getSize()
    assert(screen.w~=dialog.dimen.w or screen.h~=dialog.dimen.h,'screen did not rotate')
    local region=dialog:_progressRegion()
    rotation_fallback=region.x==screen.x and region.y==screen.y and region.w==screen.w and region.h==screen.h
    assert(rotation_fallback,'rotated dialog did not request a full screen refresh')
    Device.screen:setRotationMode(rotation)
end
dialog.buttons[1][1].callback();assert(clicked==1,'cancel callback lost')
dialog:close();UI:forceRePaint();Device.screen:shot(shots..'/closed.png')
if not old then
    local count=#regions
    local probe=Dialog:new{title='旋转前',progress_max=100,refresh_time_seconds=0}
    probe:show();UI:forceRePaint()
    local rotation=Device.screen:getRotationMode()
    Device.screen:setRotationMode((rotation+1)%4)
    local screen=Device.screen:getSize()
    probe:reportProgress(50,'旋转后')
    local refreshed=assert(regions[#regions])
    assert(refreshed.x==screen.x and refreshed.y==screen.y and refreshed.w==screen.w and refreshed.h==screen.h,
        'rotated progress did not request a full screen refresh')
    Device.screen:setRotationMode(rotation)
    probe:close();UI:forceRePaint()
    while #regions>count do regions[#regions]=nil end
end
UI._refresh=original
print('\nWEREAD_PROGRESS_REGION='..require('json').encode({result='PASS',regions=regions,
    callback_ok=clicked==1,rotation_fallback=rotation_fallback})..'\n')
