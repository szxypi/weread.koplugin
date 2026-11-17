-- Browse account-local saved bookstore searches without a network request.
local Cache=require('weread.lib.discovery_cache')
local CacheUI=require('weread.ui.discovery_cache')
local Popup=require('weread.ui.shelf_popup')
local Scope=require('weread.ui.page_scope')
local UI=require('ui/uimanager')
local _=require('weread.lib.plugin_util').tr
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
    for _index,keyword in ipairs(items) do
        rows[#rows+1]={text=keyword,callback=function()
            if not current() then return end
            host._discovery_menu=nil;Popup.close(owner)
            if not CacheUI.open(host,{kind='search',keyword=keyword},0) then
                host:showInfo(_('This saved search is no longer available. Search again to refresh it.'))
            end
        end}
    end
    menu=host:showList(_('Saved searches'),rows)
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
        local searches=Cache:new(host.library_db,host.client):searches()
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
                local keyword=Cache.query{kind='search',keyword=value.items[index]}.keyword
                if seen[keyword] then error('invalid') end
                seen[keyword]=true;out[#out+1]=keyword
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
