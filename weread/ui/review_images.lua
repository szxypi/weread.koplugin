-- A review owns its pending image request and any image viewer above it.
local UI=require('ui/uimanager')
local Images=require('weread.ui.thought_images')
local _=require('weread.lib.plugin_util').tr
local M={}

function M.cancel(host,owner)
    local image_owner=owner and owner.review_image_owner
    if not image_owner then return end
    owner.review_image_owner=nil
    Images.cancel(host,image_owner)
    local widget=image_owner.widget;image_owner.widget=nil
    if widget then UI:close(widget) end
end

function M.open(host,owner,book,review,index,detail,current_view)
    if not current_view() or owner.detail~=detail or owner.review_image_owner then return false end
    local id=book.book_id or book.bookId
    if type(id)=='number' then id=string.format('%.0f',id) end
    local urls=require('weread.lib.thought_attachments').decode(review.attachment_urls)
    if not urls or not require('weread.lib.thought_image_store').key(id,review.review_id,urls[index]) then
        host:showInfo(_('Could not open this review image.'));return false
    end
    local image_owner={id=id,account=owner.account,generation=1}
    owner.review_image_owner=image_owner
    local function current()
        return owner.review_image_owner==image_owner and current_view() and owner.detail==detail
    end
    local adapter={
        loading=_('Loading review image…'),failure=_('Could not open this review image.'),
        offline=_('This image is not saved on this device. Connect to view it.'),title=_('Review image'),
        viewer_current=function() return current() and not image_owner.widget end,
        scope_current=current,
        stopped=function()
            if owner.review_image_owner==image_owner and not image_owner.widget then owner.review_image_owner=nil end
        end,
        show=function(widget)
            if not current() then return false end
            local old=widget.onCloseWidget
            widget.onCloseWidget=function(value,...)
                if image_owner.widget==value then image_owner.widget=nil end
                if owner.review_image_owner==image_owner then owner.review_image_owner=nil end
                if old then return old(value,...) end
            end
            image_owner.widget=widget;UI:show(widget);return true
        end,
        close_failed=function(widget,image)
            if image_owner.widget==widget then
                image_owner.widget=nil;pcall(UI.close,UI,widget)
            elseif image.free then image:free() end
        end,
    }
    local opened=Images.open(host,image_owner,{reviewId=review.review_id,attachment_urls=review.attachment_urls},
        index,detail,current,1,adapter)
    if not opened and owner.review_image_owner==image_owner then owner.review_image_owner=nil end
    return opened
end
return M
