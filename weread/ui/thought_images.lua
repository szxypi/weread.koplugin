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
function M.open(host,owner,row,index,viewer,current,generation,adapter)
    local function viewer_current()
        return adapter and adapter.viewer_current() or not adapter and Popup.current(owner.menu,viewer)
    end
    if not current(host,owner) or owner.generation~=generation or not viewer_current() then return false end
    local urls=require('weread.lib.thought_attachments').decode(row.attachment_urls)
    local url=urls and urls[index]
    if not url then return false end
    M.cancel(host,owner)
    local ctx={};owner.thought_image=ctx
    local function active()
        return owner.thought_image==ctx and current(host,owner) and owner.generation==generation
            and viewer_current()
    end
    local loading=adapter and adapter.loading or _('Loading thought image…')
    local failure=adapter and adapter.failure or _('Could not open this thought image.')
    local offline=adapter and adapter.offline or _('This image is not saved on this device. Connect to view it.')
    local function stopped() if adapter and adapter.stopped then adapter.stopped() end end
    local function report_failure(message) stopped();host:showInfo(message or failure) end
    host:showBusy(loading,function() M.cancel(host,owner);stopped() end);ctx.busy=host.busy_message
    local ok,worker=pcall(function() return require('weread.lib.memory_worker'):new{
        scheduler=UI,codec=host.client,max_bytes=8*1024*1024,timeout=60} end)
    if not ok or not worker then M.cancel(host,owner);report_failure();return false end
    ctx.worker=worker
    local started_ok,started=pcall(worker.start,worker,function()
        local result,why=require('weread.lib.thought_image').load(host.client,host.library_db,owner.account,
            owner.id,row.reviewId,url,function() return host:isNetworkOnline() end,function()
                return host.library_db:accountKey()==owner.account and (adapter and adapter.scope_current()
                    or not adapter and host.settings:auth_scope_matches(owner.scope))
            end)
        return result or {error=why}
    end,function(result)
        local show=active();M.cancel(host,owner)
        if not show then stopped();return end
        if type(result)~='table' or type(result.bytes)~='string' or type(result.sha256)~='string' then
            report_failure(type(result)=='table' and result.error=='offline' and offline or failure);return
        end
        local decoded,bytes=pcall(require('mime').unb64,result.bytes)
        if not decoded or type(bytes)~='string' or require('weread.lib.crypto').sha256_hex(bytes)~=result.sha256
            or not require('weread.lib.thought_image_data').dimensions(bytes) then
            report_failure();return
        end
        local rendered,image=pcall(function() return require('ui/renderimage'):renderImageData(bytes,#bytes,false) end)
        if not rendered or not image then report_failure();return end
        if not current(host,owner) or owner.generation~=generation or not viewer_current() then
            if image.free then image:free() end;stopped();return
        end
        local made,widget=pcall(function() return require('ui/widget/imageviewer'):new{
            image=image,image_disposable=true,title_text=adapter and adapter.title or _('Thought image'),buttons_visible=true} end)
        if not made or not widget then if image.free then image:free() end;report_failure();return end
        local shown,value
        if adapter then shown,value=pcall(adapter.show,widget)
        else shown,value=pcall(Popup.show,owner.menu,widget,function(display) UI:show(display) end) end
        if not shown or not value then
            if adapter then
                adapter.close_failed(widget,image)
            elseif owner.menu._shelf_popup==widget then
                pcall(Popup.close,owner.menu)
            elseif image.free then
                image:free()
            end
            report_failure()
        end
    end)
    if not started_ok or not started then M.cancel(host,owner);report_failure();return false end
    return true
end
return M
