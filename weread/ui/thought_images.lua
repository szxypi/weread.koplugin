-- The personal-note menu owns the image request and viewer lifetime.
local UI=require('ui/uimanager')
local Popup=require('weread.ui.shelf_popup')
local _=require('weread.lib.plugin_util').tr
local M={}
function M.cancel(host,owner)
    local ctx=owner and owner.thought_image;if not ctx then return end
    owner.thought_image=nil
    if ctx.worker then ctx.worker:cancel() end
    if ctx.busy and host.busy_message==ctx.busy then host:closeBusy() end
end
function M.open(host,owner,row,index,viewer,current,generation)
    if not current(host,owner) or owner.generation~=generation or not Popup.current(owner.menu,viewer) then return false end
    local urls=require('weread.lib.thought_attachments').decode(row.attachment_urls)
    local url=urls and urls[index]
    if not url then return false end
    M.cancel(host,owner)
    local ctx={};owner.thought_image=ctx
    local function active()
        return owner.thought_image==ctx and current(host,owner) and owner.generation==generation
            and Popup.current(owner.menu,viewer)
    end
    local online=host:isNetworkOnline()
    host:showBusy(_('Loading thought image…'),function() M.cancel(host,owner) end);ctx.busy=host.busy_message
    local ok,worker=pcall(function() return require('weread.lib.memory_worker'):new{
        scheduler=UI,codec=host.client,max_bytes=8*1024*1024,timeout=60} end)
    if not ok or not worker then M.cancel(host,owner);host:showInfo(_('Could not open this thought image.'));return false end
    ctx.worker=worker
    local started_ok,started=pcall(worker.start,worker,function()
        local result,why=require('weread.lib.thought_image').load(host.client,host.library_db,owner.account,
            owner.id,row.reviewId,url,online,function()
                return host.library_db:accountKey()==owner.account and host.settings:auth_scope_matches(owner.scope)
            end)
        return result or {error=why}
    end,function(result)
        local show=active();M.cancel(host,owner)
        if not show then return end
        if type(result)~='table' or type(result.bytes)~='string' or type(result.sha256)~='string' then
            host:showInfo(_(type(result)=='table' and result.error=='offline'
                and 'This image is not saved on this device. Connect to view it.' or 'Could not open this thought image.'));return
        end
        local decoded,bytes=pcall(require('mime').unb64,result.bytes)
        if not decoded or type(bytes)~='string' or require('weread.lib.crypto').sha256_hex(bytes)~=result.sha256
            or not require('weread.lib.thought_image_data').dimensions(bytes) then
            host:showInfo(_('Could not open this thought image.'));return
        end
        local rendered,image=pcall(function() return require('ui/renderimage'):renderImageData(bytes,#bytes,false) end)
        if not rendered or not image then host:showInfo(_('Could not open this thought image.'));return end
        if not current(host,owner) or owner.generation~=generation or not Popup.current(owner.menu,viewer) then
            if image.free then image:free() end;return
        end
        local made,widget=pcall(function() return require('ui/widget/imageviewer'):new{
            image=image,image_disposable=true,title_text=_('Thought image'),buttons_visible=true} end)
        if not made or not widget then if image.free then image:free() end;host:showInfo(_('Could not open this thought image.'));return end
        local shown,value=pcall(Popup.show,owner.menu,widget,function(display) UI:show(display) end)
        if not shown or not value then
            if owner.menu._shelf_popup==widget then
                pcall(Popup.close,owner.menu)
            elseif image.free then
                image:free()
            end
            host:showInfo(_('Could not open this thought image.'))
        end
    end)
    if not started_ok or not started then M.cancel(host,owner);host:showInfo(_('Could not open this thought image.'));return false end
    return true
end
return M
