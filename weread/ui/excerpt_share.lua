-- A QR overlay owns the listener and its temporary firewall rules.
local ButtonDialog=require('ui/widget/buttondialog')
local CenterContainer=require('ui/widget/container/centercontainer')
local Device=require('device')
local Geom=require('ui/geometry')
local QRWidget=require('ui/widget/qrwidget')
local UI=require('ui/uimanager')
local Card=require('weread.lib.excerpt_card.init')
local Transfer=require('weread.lib.excerpt_transfer')
local _=require('weread.lib.plugin_util').tr
local M={}
local Dialog=ButtonDialog:extend{}
function Dialog:onCloseWidget()
    ButtonDialog.onCloseWidget(self)
    if self.share_close then self.share_close();self.share_close=nil end
end
function M.close(host)
    local state=host and host._excerpt_share
    if not state then return end
    host._excerpt_share=nil
    if state.task then UI:unschedule(state.task);state.task=nil end
    local clean=state.server:stop()
    if state.dialog then local dialog=state.dialog;state.dialog=nil;UI:close(dialog) end
    if not clean and host.showInfo then host:showInfo(_('Could not remove temporary network access. Restart KOReader to retry cleanup.')) end
end
function M.start(host,editor,options,is_current)
    if not is_current(host,editor) then return false end
    M.close(host)
    local ok,png,detail=pcall(Card.encode,options)
    if not ok or not png then host:showInfo(_('Could not prepare the excerpt card.'));return false end
    local firewall
    if Device:isKindle() then
        local root=host.settings and host.settings.data_dir
        firewall=function(port,tag) return require('weread.lib.excerpt_firewall').acquire(root,port,tag) end
    end
    local success,server,reason=pcall(Transfer.start,png,{firewall=firewall})
    if not success or not server then
        host:showInfo(reason=='no_wifi' and _('Connect the reader and phone to the same Wi-Fi network.')
            or _('Could not start temporary phone transfer.'));return false
    end
    if not is_current(host,editor) then server:stop();return false end
    local state={server=server};host._excerpt_share=state
    local title=_('Scan with a phone on the same Wi-Fi. The link closes after 3 minutes or when this window closes.')
    if detail and detail.truncated then title=title..'\n'.._('Only part of the selected text fits this template.') end
    local built,dialog=pcall(function()
        local window=Dialog:new{title=title,buttons={{{text=_('Close'),callback=function() M.close(host) end}}}}
        local size=math.floor(math.min(Device.screen:getWidth()*0.64,Device.screen:getHeight()*0.45))
        window:addWidget(CenterContainer:new{dimen=Geom:new{w=window:getAddedWidgetAvailableWidth(),h=size},
            QRWidget:new{text=server.url,width=size,height=size}})
        return window
    end)
    if not built or not dialog then M.close(host);host:showInfo(_('Could not start temporary phone transfer.'));return false end
    state.dialog=dialog;dialog.share_close=function() if host._excerpt_share==state then M.close(host) end end
    state.task=function()
        if host._excerpt_share~=state then return end
        if not is_current(host,editor) then M.close(host);return end
        local poll_ok,alive=pcall(server.poll,server)
        if not poll_ok or not alive then M.close(host);return end
        UI:scheduleIn(.05,state.task)
    end
    local shown=pcall(UI.show,UI,dialog)
    if not shown then M.close(host);host:showInfo(_('Could not start temporary phone transfer.'));return false end
    UI:scheduleIn(.05,state.task)
    return true
end
return M
