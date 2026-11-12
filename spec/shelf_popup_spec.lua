-- Actual sort/filter callbacks with deterministic deferred dispatch and popup ownership.
package.path='./?.lua;'..package.path
local queue,shown,closed={},nil,0
package.preload['ui/uimanager']=function() return {
    show=function(_self,dialog) shown=dialog end,
    close=function(_self,dialog) closed=closed+1;if dialog.onCloseWidget then dialog:onCloseWidget() end end,
    nextTick=function(_self,callback) queue[#queue+1]=callback end,
} end
for _module_index,name in ipairs({'ui/widget/buttondialog','ui/widget/confirmbox','ui/widget/pathchooser'}) do
    package.preload[name]=function() return {new=function(_self,options) return options end} end
end
for _module_index,name in ipairs({'weread.lib.content','weread.lib.scan','weread.lib.logger','weread.lib.protocol'}) do
    package.preload[name]=function() return {} end
end
package.preload['weread.lib.plugin_util']=function() return {tr=function(value) return value end,T=function(value) return value end} end
local Cache=require('weread.ui.cache')
local Popup=require('weread.ui.shelf_popup')
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local function flush() while #queue>0 do table.remove(queue,1)() end end
local function fixture()
    queue={};closed=0
    local shelf={sort_order='default'}
    local host={settings={},shelf_filters={},writes=0,flushes=0,changes=0}
    function host.settings:get() return shelf end
    function host.settings:set() host.writes=host.writes+1 end
    function host.settings:flush() host.flushes=host.flushes+1 end
    for key,value in pairs(Cache) do host[key]=value end
    local owner={};local current=true
    local origin={owner=owner,is_current=function() return current end}
    return host,owner,origin,function() current=false end
end
for _kind_index,kind in ipairs({'sort','filter'}) do
    for _event_index,event in ipairs({'dismissed','replaced','parent_closed','context_changed','current'}) do
        local host,owner,origin,revoke=fixture()
        local changed=function() host.changes=host.changes+1 end
        if kind=='sort' then host:showShelfSortOptions(changed,origin) else host:showShelfFilterOptions(changed,origin) end
        local dialog=shown;expect(Popup.current(owner,dialog),'popup not owned')
        local callback=dialog.buttons[2][1].callback
        callback();expect(host.writes==0,'callback mutated preferences before the UI turn')
        local replacement
        if event=='dismissed' then Popup.close(owner)
        elseif event=='replaced' then replacement={};Popup.show(owner,replacement)
        elseif event=='parent_closed' then owner._shelf_closed=true;Popup.close(owner)
        elseif event=='context_changed' then revoke() end
        flush()
        if event=='current' then
            expect(host.writes==1 and host.flushes==1 and host.changes==1 and not owner._shelf_popup,'valid choice did not save exactly once')
            callback();flush();expect(host.writes==1 and host.changes==1,'old choice was dispatched twice')
        else expect(host.writes==0 and host.flushes==0 and host.changes==0,'stale '..kind..' changed preferences: '..event) end
        if replacement then expect(Popup.current(owner,replacement),'old choice closed its replacement') end
    end
end
local _,owner=fixture();local calls=0
local dialog={onCloseWidget=function() calls=calls+1;return false end}
Popup.show(owner,dialog);Popup.close(owner);Popup.close(owner)
expect(calls==1 and not owner._shelf_popup,'owned cleanup lost or repeated the original close handler')
owner._shelf_closed=true
expect(not Popup.show(owner,{}) and not owner._shelf_popup,'closed parent acquired a popup')
local function deferred_fixture()
    local _,parent=fixture();Popup.show(parent,{})
    return parent
end
local parent=deferred_fixture();local rendered=0
Popup.redraw(parent,function() rendered=1 end);Popup.redraw(parent,function() rendered=2 end)
expect(rendered==0,'background redraw interrupted an open popup')
Popup.close(parent);expect(rendered==0,'redraw ran before the user choice completed');flush()
expect(rendered==2,'last background update was lost after dismissal')
parent=deferred_fixture();rendered=0
Popup.redraw(parent,function() rendered=rendered+1 end)
Popup.show(parent,{});flush()
expect(rendered==0 and parent._shelf_popup,'replacing one popup interrupted its successor')
Popup.close(parent);flush();expect(rendered==1,'replacement popup lost deferred redraw')
parent=deferred_fixture();rendered=0
Popup.redraw(parent,function() rendered=rendered+1 end)
Popup.close(parent);parent._shelf_closed=true;flush()
expect(rendered==0,'navigation was overwritten by the old background redraw')
parent=deferred_fixture();rendered=0
Popup.redraw(parent,function() rendered=rendered+1 end)
require('ui/uimanager'):close(parent._shelf_popup);flush()
expect(rendered==1 and not parent._shelf_popup,'native dismissal did not release deferred redraw')
print(('shelf_popup_spec: %d checks'):format(checks))
