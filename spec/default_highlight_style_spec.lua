package.path='./?.lua;'..package.path
local queued={};local preferences={};local writes,flushes=0,0
local Popup={}
function Popup.redraw(_menu,callback) callback() end
function Popup.show(menu,dialog) menu._shelf_popup=dialog end
function Popup.close(menu) menu._shelf_popup=nil end
function Popup.current(menu,dialog) return menu._shelf_popup==dialog end
package.preload['weread.ui.shelf_popup']=function() return Popup end
package.preload['ui/uimanager']=function() return {
    scheduleIn=function(_self,_delay,callback) queued[#queued+1]=callback end,unschedule=function() end,close=function() end,
} end
package.preload['ui/widget/buttondialog']=function() return {new=function(_self,value) return value end} end
package.preload['weread.ui.thought_editor']=function() return {cancel=function() end} end
package.preload['weread.ui.mark_editor']=function() return {cancel=function() end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(value) return value end} end
package.preload['weread.lib.my_cloud_marks']=function() return {id=function(value) return value=='41' end} end
package.preload['weread.lib.source_context']=function() return {
    location=function(document) return document.location end,same_location=function(a,b) return a==b end,capture=function() return {} end,
} end
package.preload['weread.lib.selection_reference']=function() return {
    capture_native=function() return {markText='Synthetic quote'} end,valid=function() return true end,
} end
package.preload['weread.lib.memory_worker']=function() return {new=function() return {
    start=function(_self,job,done) done(job());return true end,cancel=function() end,
} end} end
local Style=require('weread.lib.mark_style');local Color=require('weread.lib.mark_color');local Selection=require('weread.ui.selection_thought')
local document={file='/synthetic.epub',location={page=1},getNormalizedXPointer=function() return '/text()' end}
local account='account-a';local scope=true
local host={ui={document=document,view={view_mode='page'}},_reader_session_gen=1,discovery_epoch=2,
    detectWeReadBook=function() return '41' end,
    library_db={accountKey=function() return account end,getChapters=function() return {} end},settings={
        get=function(_self,key,default) local value=preferences[key];if value==nil then return default end;return value end,
        set=function(_self,key,value) writes=writes+1;preferences[key]=value end,flush=function() flushes=flushes+1 end,
        get_auth_scope=function() return {} end,auth_scope_matches=function() return scope end,
    },
    showList=function(_self,_title,items) return {item_table=items,switchItemTable=function(self,_new_title,rows) self.item_table=rows end} end}
local function open()
    assert(Selection.open(host,{text='Synthetic quote',pos0='/first',pos1='/last'}))
    local work=queued;queued={};for _i,callback in ipairs(work) do callback() end
    return assert(host._selection_thought_owner)
end
local function chooser(owner,label)
    for _i,row in ipairs(owner.menu.item_table) do
        if row.text==(label or 'Default highlight style') then row.callback();return owner.menu._shelf_popup,row end
    end
    error('missing default style row')
end
local function button(dialog,style,prefix)
    for _i,row in ipairs(dialog.buttons) do if row[1].id==(prefix or 'default_highlight_style_')..style then return row[1] end end
    error('missing default style button')
end
local checks=0;local function expect(value,label) checks=checks+1;assert(value,label) end
for _i,style in ipairs({0,2,1}) do
    local owner=open();local dialog,row=chooser(owner)
    expect(row.mandatory==Style.labels[Style.default(host.settings)],'current default not displayed')
    expect(#dialog.buttons==3,'unexpected style choices')
    button(dialog,style).callback()
    expect(preferences.cloud_highlight_style==style and writes==_i and flushes==_i,'default not saved once')
    expect(not owner.menu._shelf_popup,'style popup not dismissed')
end
for index,color in ipairs(Color.values) do
    local owner=open();local dialog,row=chooser(owner,'Default highlight color')
    expect(row.mandatory==Color.labels[Color.default(host.settings)] and #dialog.buttons==6,'color palette/current value not displayed')
    button(dialog,color,'default_highlight_color_').callback()
    expect(preferences.cloud_highlight_color==color and writes==3+index and flushes==3+index,'color preference not saved once')
end
for _i,is_color in ipairs({false,true}) do
for _j,kind in ipairs({'account','session','scope','mode','location','document','closed','popup'}) do
    local owner=open()
    local dialog=chooser(owner,is_color and 'Default highlight color' or nil)
    local callback=button(dialog,2,is_color and 'default_highlight_color_' or nil).callback
    local before=writes
    if kind=='account' then account='account-b'
    elseif kind=='session' then host._reader_session_gen=2
    elseif kind=='scope' then scope=false
    elseif kind=='mode' then host.ui.view.view_mode='scroll'
    elseif kind=='location' then document.location={page=2}
    elseif kind=='document' then host.ui.document={file='/other.epub'}
    elseif kind=='closed' then Selection.cancel(host)
    else owner.menu._shelf_popup={} end
    callback();expect(writes==before,'stale chooser changed preference after '..kind)
    account='account-a';host._reader_session_gen=1;scope=true;host.ui.view.view_mode='page';document.location={page=1};host.ui.document=document
end
end
preferences.cloud_highlight_style='invalid'
local owner=open();local _dialog,row=chooser(owner)
expect(_dialog and row.mandatory==Style.labels[1],'invalid saved style was displayed')
for _i,value in ipairs({-1,6,'3',true,.5}) do
    preferences.cloud_highlight_color=value;expect(Color.default(host.settings)==0,'invalid color did not fall back')
end
expect(not Color.editable{type=1,style=99,colorStyle=1} and not Color.editable{type=0,style=0,colorStyle=0},'unknown style or point bookmark exposed color editing')
print('default_highlight_style_spec: '..checks..' checks')
