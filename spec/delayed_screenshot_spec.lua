-- Native screenshot ownership, timer replacement and cancellation.
package.path='./?.lua;'..package.path
local shown,scheduled,unscheduled=nil,{},{}
package.preload['ui/uimanager']=function() return {
    show=function(_,dialog) shown=dialog end,
    close=function(_,dialog) if dialog.onCloseWidget then dialog:onCloseWidget() end end,
    scheduleIn=function(_,seconds,callback) scheduled[#scheduled+1]={seconds=seconds,callback=callback} end,
    unschedule=function(_,callback) unscheduled[callback]=true end,
} end
package.preload['ui/widget/buttondialog']=function() return {new=function(_,options) return options end} end
package.preload['weread.lib.plugin_util']=function() return {
    tr=function(text) return text end,
    T=function(text,value) return (text:gsub('%%1',tostring(value))) end,
} end
local reader,manager={},{}
package.preload['apps/reader/readerui']=function() return reader end
package.preload['apps/filemanager/filemanager']=function() return manager end
require('apps/reader/readerui');require('apps/filemanager/filemanager')
local host={messages={}}
function host:showInfo(text) self.messages[#self.messages+1]=text end
function host:showTransientInfo(text) self.messages[#self.messages+1]=text end
local Screenshot=require('weread.ui.delayed_screenshot')
local function button(id)
    for _,row in ipairs(shown.buttons) do for _,item in ipairs(row) do if item.id==id then return item end end end
    error('missing button '..id)
end
local first,second=0,0
local old={onScreenshot=function() first=first+1;return true end}
local current={onScreenshot=function() second=second+1;return true end}
manager.instance={screenshot=old}
Screenshot.show(host);local stale=button('screenshot_delay_5').callback
stale();assert(Screenshot.is_armed() and scheduled[1].seconds==5)
manager.instance={screenshot=current}
scheduled[1].callback();assert(first==0 and second==1 and not Screenshot.is_armed(),'capture did not use current screen')
Screenshot.show(host);button('screenshot_delay_10').callback()
local replaced=scheduled[2].callback
Screenshot.show(host);button('screenshot_delay_15').callback()
assert(unscheduled[replaced] and scheduled[3].seconds==15)
replaced();assert(Screenshot.is_armed() and second==1,'replaced timer still fired')
Screenshot.show(host);button('cancel_screenshot').callback()
assert(not Screenshot.is_armed() and unscheduled[scheduled[3].callback])
scheduled[3].callback();assert(second==1,'canceled screenshot fired')
Screenshot.show(host);local stale_popup=button('screenshot_delay_5').callback
Screenshot.show(host);stale_popup();assert(not Screenshot.is_armed(),'old menu scheduled a screenshot')
button('screenshot_delay_5').callback();assert(Screenshot.cancel())
scheduled[4].callback();assert(second==1,'suspend cancellation did not invalidate timer')
assert(not Screenshot.arm(host,6))
manager.instance=nil;Screenshot.arm(host,5);scheduled[5].callback()
assert(host.messages[#host.messages]=='Screenshot is unavailable on this device.')
reader.instance={screenshot={onScreenshot=function() error('synthetic failure') end}}
Screenshot.arm(host,5);scheduled[6].callback()
assert(host.messages[#host.messages]=='Could not take the screenshot.')
reader.instance={screenshot=current};manager.instance={screenshot=old}
Screenshot.arm(host,5);scheduled[7].callback()
assert(second==2 and first==0,'reader screenshot did not take priority')
Screenshot.show(host);assert(not Screenshot.cancel() and not Screenshot.is_armed())
print('delayed_screenshot_spec: native owner, stale callbacks, timer and cancellation passed')
