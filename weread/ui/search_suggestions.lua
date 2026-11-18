-- Explicit, cancellable bookstore suggestions owned by the search dialog.
local Model=require('weread.lib.search_suggestions')
local Access=require('weread.lib.native_gateway_access')
local Recovery=require('weread.lib.native_read_recovery')
local Popup=require('weread.ui.shelf_popup')
local Scope=require('weread.ui.page_scope')
local UI=require('ui/uimanager')
local _=require('weread.lib.plugin_util').tr
local M={}

function M.cancel(host)
    local job=host.search_suggestions_job;host.search_suggestions_job=nil
    if not job then return end
    if host.search_suggestions_worker then host.search_suggestions_worker:cancel() end
    Recovery.cancel(host,job)
    if job.busy and host.busy_message==job.busy then host:closeBusy() end
end

function M.open(host,input)
    M.cancel(host)
    local owner=host.shelf_view
    if not owner or owner._shelf_closed or not input or not Popup.current(owner,input) then return false end
    local keyword=Model.keyword(input:getInputText())
    if not keyword then host:showInfo(_('Enter a search term first.'));return false end
    if not host:isNetworkOnline() then host:showOffline(_('Search suggestions'));return false end
    local selected=Access.capture(host.settings)
    if not selected or not selected.native then
        host:showInfo(_('Search suggestions need E-Ink authorization.'));return false
    end
    local scope=Scope.capture(host,owner)
    local job={};host.search_suggestions_job=job
    local function current_view()
        return host.search_suggestions_job==job and scope() and Popup.current(owner,input)
            and Model.keyword(input:getInputText())==keyword
    end
    local function current()
        return current_view() and (job.renewing and Recovery.current(host.settings,selected,Access.capture)
            or Access.matches(host.settings,selected))
    end
    host:showBusy(_('Loading search suggestions…'),function() M.cancel(host) end);job.busy=host.busy_message
    local ok,worker=pcall(function()
        return host.search_suggestions_worker or require('weread.lib.memory_worker'):new{scheduler=UI,codec=host.client,max_bytes=64*1024}
    end)
    if not ok or not worker then M.cancel(host);host:showInfo(_('Could not load search suggestions.'));return false end
    host.search_suggestions_worker=worker
    local launch
    local function complete(value)
        if not current() then if host.search_suggestions_job==job then M.cancel(host) end;return end
        if type(value)=='table' and value.expired then
            local recovering=Recovery.start(host,job,selected,{capture=Access.capture,is_current=current_view,
                stale=function() if host.search_suggestions_job==job then M.cancel(host) end end,
                complete=function(success,renewed)
                    selected=renewed
                    if success then launch() else complete(nil) end
                end})
            if recovering then return end
        end
        M.cancel(host)
        local valid,words=pcall(function()
            if type(value)~='table' or value.ok~=true or type(value.words)~='table' then error('invalid') end
            local records={}
            for key in pairs(value.words) do
                if type(key)~='number' or key%1~=0 or key<1 or key>#value.words then error('invalid') end
            end
            for index,word in ipairs(value.words) do records[index]={word=word} end
            if #records~=#value.words or #records>Model.MAX_WORDS then error('invalid') end
            local projected=Model.project({records=records,list={},parts={}},keyword)
            if #projected~=#records then error('invalid') end
            return projected
        end)
        if not valid then host:showInfo(_('Could not load search suggestions.'));return end
        if #words==0 then host:showInfo(_('No search suggestions found.'));return end
        local menu
        local function active() return scope() and host._discovery_menu==menu and Popup.current(owner,menu) end
        local items={}
        for _,word in ipairs(words) do
            items[#items+1]={text=word,callback=function()
                if not active() then return end
                host._discovery_menu=nil;Popup.close(owner)
                host:loadDiscoveryBatch('search',word,0)
            end}
        end
        menu=host:showList(_('Search suggestions'),items)
        if not menu then return end
        host._discovery_menu=menu
        local closed=menu.onCloseWidget
        menu.onCloseWidget=function(widget,...)
            if host._discovery_menu==widget then host._discovery_menu=nil end
            if closed then return closed(widget,...) end
        end
        menu.close_callback=function() if host._discovery_menu==menu then host._discovery_menu=nil end end
        Popup.show(owner,menu,function() end)
    end
    launch=function()
        local called,started=pcall(worker.start,worker,function()
            local success,words=pcall(Model.fetch,host.client,selected,keyword)
            return success and {ok=true,words=words} or {ok=false,expired=words=='native_auth/suggest/http_401'}
        end,complete)
        if not called or not started then complete(nil) end
    end
    launch()
    return true
end
return M
