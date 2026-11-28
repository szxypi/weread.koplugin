local UIManager = require('ui/uimanager')
local PluginUtil = require('weread.lib.plugin_util')
local _,T = PluginUtil.tr,PluginUtil.T
local M = {}
-- Internal entry for file-bound positions. Cloud payloads require a separately
-- validated adapter; they must not be passed here as catalog-word offsets.
function M:openSourcePosition(position, callback)
    local cloud=self.cloud_source_request
    if cloud and not cloud.dispatching then self:cancelCloudSourcePosition() end
    if not self.source_navigation then return false,'target_unavailable' end
    return self.source_navigation:jump(position,callback)
end
function M:showCloudSourcePosition(sync_choice)
    return require('weread.ui.cloud_source').start(self,nil,{sync_choice=sync_choice==true})
end
function M:cancelCloudSourcePosition()
    return require('weread.ui.cloud_source').cancel(self)
end
function M:onCloudSourceViewChanged()
    return require('weread.ui.cloud_source').on_view_changed(self)
end
local function message(reason)
    if reason=='no_visible_text' then return _('This page has no text position to check.') end
    if reason=='source_unavailable' then return _('This file has no original position data. Download the chapter again to check its position.') end
    if reason=='source_changed' then return _('The position data could not be verified. Download the chapter again.') end
    if reason=='resources_unavailable' or reason=='worker_unavailable' or reason=='paused' then
        return _('Reading position is temporarily unavailable. Please try again shortly.')
    end
    return _('This page could not be matched to the original text.')
end
function M:closeReadingPositionMessage()
    if self._source_position_message then UIManager:close(self._source_position_message);self._source_position_message=nil end
end
function M:showReadingPosition()
    if self._read_resume_token then require('weread.ui.read_resume').cancel(self) end
    self:closeReadingPositionMessage()
    if not self.source_position then return end
    self:showTransientInfo(_('Checking the current reading position...'),1)
    self.source_position:check(function(position,reason)
        local text
        if position then
            local title=position.chapter_title or _('Current chapter')
            text=T(_('The current page has been located.\nChapter: %1\n\nPrecision cloud sync is still being validated.'),title)
        else text=message(reason) end
        self._source_position_message=require('ui/widget/infomessage'):new{text=text}
        UIManager:show(self._source_position_message)
    end)
end
return M
