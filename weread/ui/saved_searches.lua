-- Browse account-local saved bookstore searches without a network request.
local Cache=require('weread.lib.discovery_cache')
local CacheUI=require('weread.ui.discovery_cache')
local Popup=require('weread.ui.shelf_popup')
local Scope=require('weread.ui.page_scope')
local UI=require('ui/uimanager')
local Util=require('weread.lib.plugin_util')
local _,T=Util.tr,Util.T
local M={}

function M.cancel(host)
    local job=host.saved_searches_job;host.saved_searches_job=nil
    if not job then return end
    if host.saved_searches_worker then host.saved_searches_worker:cancel() end
    if job.busy and host.busy_message==job.busy then host:closeBusy() end
end

local function show(host,owner,scope,items)
    if not scope() then return end
    if #items==0 then host:showInfo(_('No saved searches yet. Search online to save results.'));return end
    local menu
    local function current() return host._discovery_menu==menu and scope() and Popup.current(owner,menu) end
    local rows={}
    for _index,entry in ipairs(items) do
        local keyword=entry.keyword
        local text=entry.source_kind=='public' and T(_('Public search: %1'),keyword) or keyword
        rows[#rows+1]={text=text,saved_entry=entry,callback=function()
            if not current() then return end
            host._discovery_menu=nil;Popup.close(owner)
            if not CacheUI.open(host,{kind='search',keyword=keyword,source_kind=entry.source_kind},0) then
                host:showInfo(_('This saved search is no longer available. Search again to refresh it.'))
            end
        end}
    end
    menu=host:showList(_('Saved searches'),rows,nil,{subtitle=_('Hold a search to remove its saved results')})
    if not menu then return end
    host._discovery_menu=menu
    local confirmation
    function menu:onMenuHold(item)
        if not current() or type(item)~='table' or not item.saved_entry or host.saved_searches_job or confirmation then return true end
        local entry=item.saved_entry
        local dialog
        dialog=require('ui/widget/confirmbox'):new{
            text=_('Remove this saved search and its offline results from this device?'),
            ok_text=_('Remove'),cancel_text=_('Cancel'),keep_dialog_open=true,
            ok_callback=function()
                if confirmation~=dialog then return end
                confirmation=nil
                UI:close(dialog)
                if not current() or host.saved_searches_job then return end
                local account=host.library_db:accountKey()
                if not account then return end
                local job={menu=menu};host.saved_searches_job=job
                local function live() return host.saved_searches_job==job and current() and account==host.library_db:accountKey() end
                host:showBusy(_('Removing saved search…'),function() M.cancel(host) end);job.busy=host.busy_message
                local started,running=pcall(host.saved_searches_worker.start,host.saved_searches_worker,function()
                    if account~=host.library_db:accountKey() then return {status='changed'} end
                    return {status=Cache:new(host.library_db,host.client):remove_search(entry.keyword,entry.generation,entry.source_kind)}
                end,function(result)
                    if not live() then if host.saved_searches_job==job then M.cancel(host) end;return end
                    M.cancel(host)
                    if type(result)~='table' or result.status~='deleted' and result.status~='changed' then
                        host:showInfo(_('Could not remove this saved search.'));return
                    end
                    local changed=result.status=='changed'
                    Popup.close(owner)
                    if changed then host:showInfo(_('This saved search changed. The updated results were kept.')) end
                    M.open(host)
                end)
                if not started or not running then M.cancel(host);host:showInfo(_('Could not remove this saved search.')) end
            end,
            cancel_callback=function() if confirmation==dialog then confirmation=nil;UI:close(dialog) end end,
        }
        confirmation=dialog
        local dialog_close=dialog.onCloseWidget
        dialog.onCloseWidget=function(widget,...)
            if confirmation==widget then confirmation=nil end
            if dialog_close then return dialog_close(widget,...) end
        end
        UI:show(dialog)
        return true
    end
    local closed=menu.onCloseWidget
    menu.onCloseWidget=function(widget,...)
        if confirmation then UI:close(confirmation);confirmation=nil end
        if host._discovery_menu==widget then host._discovery_menu=nil end
        if host.saved_searches_job and host.saved_searches_job.menu==widget then M.cancel(host) end
        if closed then return closed(widget,...) end
    end
    menu.close_callback=function() if host._discovery_menu==menu then host._discovery_menu=nil end end
    Popup.show(owner,menu,function() end)
end

function M.open(host,input)
    M.cancel(host)
    local owner=host.shelf_view
    if not owner or owner._shelf_closed or input and not Popup.current(owner,input) then return false end
    local scope=Scope.capture(host,owner)
    local account=host.library_db and host.library_db:accountKey()
    if not account then host:showInfo(_('No saved searches yet. Search online to save results.'));return false end
    local job={};host.saved_searches_job=job
    local function current()
        return host.saved_searches_job==job and scope() and (not input or Popup.current(owner,input))
            and account==host.library_db:accountKey()
    end
    host:showBusy(_('Loading saved searches…'),function() M.cancel(host) end);job.busy=host.busy_message
    local ok,worker=pcall(function()
        return host.saved_searches_worker or require('weread.lib.memory_worker'):new{scheduler=UI,codec=host.client,max_bytes=256*1024}
    end)
    if not ok or not worker then M.cancel(host);host:showInfo(_('Could not load saved searches.'));return false end
    host.saved_searches_worker=worker
    local started,running=pcall(worker.start,worker,function()
        local searches=Cache:new(host.library_db,host.client):search_entries()
        return {ok=type(searches)=='table',items=searches}
    end,function(value)
        if not current() then if host.saved_searches_job==job then M.cancel(host) end;return end
        M.cancel(host)
        local valid,items=pcall(function()
            if type(value)~='table' or value.ok~=true or type(value.items)~='table' or #value.items>Cache.MAX_QUERIES then error('invalid') end
            for key in pairs(value.items) do
                if type(key)~='number' or key%1~=0 or key<1 or key>#value.items then error('invalid') end
            end
            local out,seen={},{}
            for index=1,#value.items do
                local entry=value.items[index]
                if type(entry)~='table' or type(entry.generation)~='string' or #entry.generation~=32
                    or not entry.generation:match('^[a-f0-9]+$')
                    or entry.source_kind~='native' and entry.source_kind~='gateway' and entry.source_kind~='public' then error('invalid') end
                local keyword=Cache.query{kind='search',keyword=entry.keyword}.keyword
                local key=Cache.key({kind='search',keyword=keyword},entry.source_kind=='public')
                if seen[key] then error('invalid') end
                seen[key]=true;out[#out+1]={keyword=keyword,generation=entry.generation,source_kind=entry.source_kind}
            end
            return out
        end)
        if not valid then host:showInfo(_('Could not load saved searches.'));return end
        show(host,owner,scope,items)
    end)
    if not started or not running then M.cancel(host);host:showInfo(_('Could not load saved searches.'));return false end
    return true
end
return M
