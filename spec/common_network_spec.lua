-- Unit tests for shared network task behavior.

package.path = "./?.lua;" .. package.path

local checks = 0

local function eq(got, want, label)
    checks = checks + 1
    if got ~= want then
        error(string.format("%s: got %s, want %s",
            label, tostring(got), tostring(want)))
    end
end

package.preload["ui/bidi"] = function() return {} end
package.preload["ui/widget/confirmbox"] = function() return {} end
package.preload["ui/widget/infomessage"] = function() return {} end
package.preload["ui/widget/menu"] = function() return {} end
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_self, _delay, callback) callback() end,
    }
end
package.preload["ui/network/manager"] = function()
    return {
        isOnline = function() return false end,
    }
end
package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text) return text end,
        log_error = tostring,
        display_error = tostring,
        unpack_args = function(args) return unpack(args) end,
    }
end

local Common = require("weread.ui.common")
local offline_notices = 0
local host = setmetatable({
    showOffline = function()
        offline_notices = offline_notices + 1
    end,
}, { __index = Common })

eq(host:runOnlineTask("automatic", function() end, nil, {
    silent_offline = true,
}), false, "silent offline task does not start")
eq(offline_notices, 0, "silent offline task does not show a notice")

eq(host:runOnlineTask("manual", function() end), false,
    "regular offline task does not start")
eq(offline_notices, 1, "regular offline task still shows a notice")

local notices,qr_starts,login_continuation=0,0,nil
local cookie,key,valid=true,false,true
local scope={vid="900000",epoch=1}
local login_host=setmetatable({settings={
    is_cookie_configured=function() return cookie end,
    is_api_configured=function() return key end,
    get_auth_scope=function() return scope end,
    auth_scope_matches=function() return valid end,
},qr_login={start=function(_self,value) qr_starts=qr_starts+1;login_continuation=value end},
    showInfo=function(_self,text) assert(text:find("Skill",1,true));notices=notices+1 end,
    showTransientInfo=function() end,
},{__index=Common})
eq(login_host:requireLogin(false,true),false,"key-only feature unavailable")
eq(notices,1,"missing key explanation")
eq(qr_starts,0,"verified Web login must not enter another QR loop")
eq(login_host:requireLogin(true,false),true,"keyless reading remains available")
valid=false
eq(login_host:requireLogin(false,true),false,"invalid scope cannot explain login as valid")
eq(qr_starts,1,"invalid scope needs login")
cookie=false
eq(login_host:requireLogin(true,false),false,"cookie-free reading needs login")
eq(qr_starts,2,"missing cookie invokes login")
local intent={current=function() return false end,resume=function() end}
eq(login_host:requireLogin(true,false,intent),false,'stale login intent did not return')
eq(qr_starts,2,'stale login intent opened the QR')
intent.current=function() return true end
eq(login_host:requireLogin(true,false,intent),false,'current login intent did not return')
eq(qr_starts,3,'current login intent did not open the QR')
eq(login_continuation,intent,'login lost the authorized continuation')

-- KOReader notifies children before removing their parent from its stack.
-- Closing an owned busy dialog in that callback must not repaint freed text.
local manager = require("ui/uimanager")
local closing_parent, pending_paint, paints, invalid_paints, closes = false, false, 0, 0, 0
manager.forceRePaint = function()
    paints = paints + 1
    if closing_parent then invalid_paints = invalid_paints + 1;error("parent text already freed") end
    pending_paint = false
end
local busy_host = setmetatable({}, { __index = Common })
local dialog = {}
busy_host.busy_message = dialog
manager.close = function(_self, widget)
    eq(widget, dialog, "close the owned dialog")
    eq(busy_host.busy_message, nil, "clear ownership before CloseWidget callbacks")
    closes = closes + 1
    pending_paint = true
end
closing_parent = true
busy_host:closeBusy()
eq(invalid_paints, 0, "parent close does not repaint freed children")
eq(paints, 0, "nested cancellation leaves painting to the event loop")
eq(pending_paint, true, "dialog close still queues the next frame")
closing_parent = false
manager:forceRePaint()
eq(paints, 1, "completed close can draw the uncovered page")
eq(pending_paint, false, "next frame drains the repaint")
busy_host:closeBusy()
eq(closes, 1, "repeated cancellation does not close another widget")
local native_menu=require('ui/widget/menu')
native_menu.new=function(_self,options) options.native=true;return options end
local shown
manager.show=function(_self,widget) shown=widget end
package.loaded['weread.ui.thought_text']={menu=function(options) options.thought=true;return options end}
local list_host=setmetatable({}, {__index=Common})
local plain=list_host:showList('Plain',{{text='A'}})
eq(plain.native,true,'ordinary list changed menu class')
local scoped=list_host:showList('Notes',{{text='😀'}},nil,{thought_text=true,items_per_page=3})
eq(scoped.thought,true,'note list missed scoped font menu')
eq(scoped.items_per_page,3,'note list lost pagination options')
eq(shown,scoped,'note list was not shown')
print(string.format("common_network_spec: %d checks", checks))
