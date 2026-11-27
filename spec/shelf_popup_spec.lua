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
for index,key in ipairs({'author_asc','author_desc'}) do
    local host,owner,origin=fixture()
    host:showShelfSortOptions(function() host.changes=host.changes+1 end,origin)
    shown.buttons[index+5][1].callback();flush()
    expect(host.settings:get().sort_order==key and host.writes==1 and host.changes==1,
        'author sort did not save the selected direction')
    expect(not owner._shelf_popup,'author sort left its popup open')
end
for index,key in ipairs({'progress_desc','progress_asc'}) do
    local host,owner,origin=fixture()
    host:showShelfSortOptions(function() host.changes=host.changes+1 end,origin)
    shown.buttons[index+7][1].callback();flush()
    expect(host.settings:get().sort_order==key and host.writes==1 and host.changes==1,
        'progress sort did not save the selected direction')
    expect(not owner._shelf_popup,'progress sort left its popup open')
end
for _,kind in ipairs({'sort','filter'}) do
for _,event in ipairs({'current','closed','account_changed'}) do
    local host,owner,origin,revoke=fixture();host.shelf_regular={{bookId='900001'}}
    local starts,cancels=0,0
    host.cancelShelfProgress=function() cancels=cancels+1 end
    package.loaded['weread.ui.shelf_progress_all']={start=function(target,scope,callback)
        expect(target==host and scope==origin and type(callback)=='function','bulk action lost its owner')
        starts=starts+1;return true
    end}
    if kind=='sort' then host:showShelfSortOptions(function() end,origin)
    else host:showShelfFilterOptions(function() end,origin) end
    local callback=shown.buttons[kind=='sort' and 10 or 8][1].callback;callback()
    if event=='closed' then Popup.close(owner) elseif event=='account_changed' then revoke() end
    flush()
    expect(starts==(event=='current' and 1 or 0) and cancels==(event=='current' and 1 or 0),
        'bulk action ran after its shelf or account changed')
end
end
for index,key in ipairs({'progress_zero','progress_active'}) do
    local host,owner,origin=fixture();local notices=0
    host.showTransientInfo=function() notices=notices+1 end
    host:showShelfFilterOptions(function() host.changes=host.changes+1 end,origin)
    shown.buttons[index+3][1].callback();flush()
    expect(host.shelf_filters.reading==key and host.writes==1 and host.changes==1 and notices==1,
        'progress filter did not save and explain its cache behavior')
    expect(not owner._shelf_popup,'progress filter left its popup open')
end
package.loaded['weread.ui.shelf_progress_all']=nil
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
do
    local host={};local view={};host.shelf_view=view;host.book_metadata_context={}
    local context=host.book_metadata_context;local value=0
    Popup.redrawForMetadata(host,view,function() value=1 end)
    Popup.redrawForMetadata(host,view,function() value=2 end)
    expect(value==0,'metadata loading did not defer shelf redraw')
    host.book_metadata_context=nil;Popup.resumeMetadata(host,context);flush()
    expect(value==2,'metadata cancellation did not restore the latest redraw')
    host.book_metadata_context={};context=host.book_metadata_context
    Popup.redrawForMetadata(host,view,function() value=3 end)
    host.book_metadata_context=nil;host._book_detail_view={};Popup.resumeMetadata(host,context);flush()
    expect(value==2,'metadata completion redrew beneath book details')
    host._book_detail_view=nil;host.book_metadata_context={};context=host.book_metadata_context
    Popup.redrawForMetadata(host,view,function() value=4 end)
    host.book_metadata_context=nil;Popup.resumeMetadata(host,context)
    host.book_metadata_context={};local next_context=host.book_metadata_context
    Popup.redrawForMetadata(host,view,function() value=5 end)
    flush();host.book_metadata_context=nil;Popup.resumeMetadata(host,next_context);flush()
    expect(value==5,'old metadata completion replaced a newer redraw')
    host.book_metadata_context={};context=host.book_metadata_context
    Popup.redrawForMetadata(host,view,function() value=6 end)
    host.book_metadata_context=nil;Popup.resumeMetadata(host,context);host.shelf_view={};flush()
    expect(value==5,'metadata redraw crossed into another shelf page')
    host.shelf_view=view;host.book_metadata_context=nil
    Popup.show(view,{})
    Popup.redrawForMetadata(host,view,function() value=7 end)
    Popup.close(view)
    host.book_metadata_context={};context=host.book_metadata_context
    flush()
    expect(value==5 and context.pending_shelf_redraw,'popup close interrupted newly started metadata')
    host.book_metadata_context=nil;Popup.resumeMetadata(host,context);flush()
    expect(value==7,'metadata cancellation lost popup-deferred redraw')
end
for _,key in ipairs({'book_reading_context','_native_home_resume','_native_direct_reading'}) do
    local view={}
    local context={shelf_owner=view}
    local host={shelf_view=view,[key]=context}
    local redraws=0
    local function redraw() redraws=redraws+1 end
    Popup.redrawForMetadata(host,view,redraw)
    expect(redraws==0 and context.pending_shelf_redraw,'shelf changed during selected book preparation')
    host[key]=nil;Popup.resumeMetadata(host,context);flush()
    expect(redraws==1,'cancelling shelf reading did not restore the deferred redraw')
    host[key]=context;host.shelf_view={}
    Popup.redrawForMetadata(host,host.shelf_view,redraw)
    expect(redraws==2 and not context.pending_shelf_redraw,'reading blocked an unrelated shelf redraw')
end
print(('shelf_popup_spec: %d checks'):format(checks))
