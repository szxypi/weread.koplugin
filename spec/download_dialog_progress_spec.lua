package.path='./?.lua;'..package.path
local now,scheduled,painted=100000000,{},{}
local UI={}
function UI:scheduleIn(seconds,callback) scheduled[#scheduled+1]={at=now+seconds*1000000,task=callback} end
function UI:unschedule(callback)
    for i=#scheduled,1,-1 do if scheduled[i].task==callback then table.remove(scheduled,i) end end
end
function UI:setDirty() end
function UI:forceRePaint()
    painted[#painted+1]={title=self.dialog.title,
        progress=self.dialog.progress_bar and self.dialog.progress_bar.percentage}
end
function UI:show() end
function UI:close(dialog) if dialog.onCloseWidget then dialog:onCloseWidget() end end
package.preload['ui/uimanager']=function() return UI end
package.preload['ui/time']=function() return {now=function() return now end,to_s=function(n) return n/1000000 end} end
package.preload['device']=function() return {screen={}} end
package.preload['ui/widget/container/inputcontainer']=function() return {extend=function(_,value) return value end} end
for _,name in ipairs({'ffi/blitbuffer','ui/widget/buttontable','ui/widget/container/centercontainer','ui/font',
    'ui/widget/container/framecontainer','ui/geometry','ui/widget/progresswidget','ui/size','ui/widget/textwidget',
    'ui/widget/textboxwidget','ui/widget/verticalgroup','ui/widget/verticalspan'}) do
    package.preload[name]=function() return {} end
end
local Dialog=require('weread.ui.download_dialog')
local function fixture()
    now=100000000;scheduled={};painted={}
    local bar={percentage=0};function bar:setPercentage(value) self.percentage=value end
    local label={};function label:setText(value) self.text=value end
    local dialog=setmetatable({title='Start',title_widget=label,progress_bar=bar,progress_max=100,
        refresh_time_seconds=3,last_redraw_time_ms=0,dimen={}}, {__index=Dialog})
    UI.dialog=dialog;dialog:show()
    return dialog
end
local function due()
    local task=assert(table.remove(scheduled,1));now=task.at;task.task()
end
local dialog=fixture()
dialog:reportProgress(1,'1/100')
assert(#painted==1 and painted[1].title=='1/100' and painted[1].progress==0.01)
for i=2,30 do now=now+10000;dialog:reportProgress(i,i..'/100') end
assert(#painted==1 and #scheduled==1 and dialog.title=='30/100' and dialog.progress_bar.percentage==0.3)
due()
assert(#painted==2 and painted[2].title=='30/100' and painted[2].progress==0.3 and #scheduled==0,
    'coalesced progress did not flush the latest state')
dialog:reportProgress(31,'31/100');local stale=assert(scheduled[1]).task
dialog:reportProgress(100,'100/100')
assert(#painted==3 and painted[3].title=='100/100' and painted[3].progress==1 and #scheduled==0)
stale();dialog:reportProgress(100,'100/100')
assert(#painted==3,'completion repainted an unchanged state')
dialog=fixture();dialog:reportProgress(1,'1/100');dialog:reportProgress(2,'2/100')
assert(#scheduled==1);dialog:setTitle('Renewing')
assert(#painted==2 and painted[2].title=='Renewing' and painted[2].progress==0.02 and #scheduled==0)
dialog:reportProgress(3,'3/100');stale=assert(scheduled[1]).task;dialog:close()
assert(#scheduled==0);stale();dialog:reportProgress(100,'late');dialog:setTitle('late')
assert(#painted==2,'closed dialog repainted')
dialog:show();dialog:reportProgress(4,'4/100');assert(#scheduled==1)
stale=scheduled[1].task;dialog:onCloseWidget();stale();assert(#scheduled==0 and #painted==2)
dialog=fixture();dialog:reportProgress(1);assert(#painted==1)
now=now+10000;dialog:reportProgress(2);assert(#painted==1 and #scheduled==0)
now=now+3000000;dialog:reportProgress(3);assert(#painted==2,'legacy progress timing changed')
dialog=fixture();dialog.progress_bar=nil;dialog:reportProgress(1,'Title only')
assert(#painted==1 and painted[1].title=='Title only','title without progress bar disappeared')
print('download_dialog_progress_spec: coalescing, final flush, cancellation and legacy progress passed')
