-- Keep each saved file selectable: its local reading position belongs to that
-- file, including when a later download has recovered previously missing images.
local Util=require('weread.lib.plugin_util')
local _,T=Util.tr,Util.T
local M={}
function M.labels(rows)
    local counts,ordinals,labels={},{},{}
    for _,entry in ipairs(rows) do counts[entry.chapter_uid]=(counts[entry.chapter_uid] or 0)+1 end
    for index,entry in ipairs(rows) do
        local label=entry.title~='' and entry.title or _('Untitled chapter')
        label=label..'  ·  v'..tostring(entry.book_version)
        if counts[entry.chapter_uid]>1 then
            ordinals[entry.chapter_uid]=(ordinals[entry.chapter_uid] or 0)+1
            label=label..'  ·  '..T(_('Copy %1'),tostring(ordinals[entry.chapter_uid]))
        end
        label=label..'  ·  '..(entry.missing_images>0
            and T(_('%1 images unavailable'),tostring(entry.missing_images)) or _('No missing images'))
        labels[index]=label
    end
    return labels
end
return M
