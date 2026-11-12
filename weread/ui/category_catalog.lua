-- Public category requests share the bookstore lifecycle, not its auth flow.
local Catalog=require('weread.lib.category_catalog')
local UIManager=require('ui/uimanager')
local _=require('weread.lib.plugin_util').tr
local M={}
function M.cancel(host)
    local job=host.category_catalog_request;host.category_catalog_request=nil
    if not job then return end
    if not host.discovery_request_context then host.discovery_loading=nil end
    if host.category_catalog_worker then host.category_catalog_worker:cancel() end
    if job.busy and host.busy_message==job.busy then host:closeBusy() end
end
local function store(host)
    if host.category_catalog_store then return host.category_catalog_store end
    local ok,value=pcall(Catalog.new,Catalog,host.settings,host.client)
    if ok then host.category_catalog_store=value;return value end
end
local function cached(host)
    local valid,memory=pcall(Catalog.validate,host.discovery_categories)
    if valid then host.discovery_categories=memory;return memory end
    host.discovery_categories=nil
    local value;local db=store(host)
    if db then local ok,result=pcall(db.read,db);if ok then value=result end end
    local ok,result=pcall(Catalog.validate,value)
    if ok then host.discovery_categories=result;return result end
end
function M.open(host,refresh)
    if host.discovery_loading then return false end
    local previous=cached(host)
    if previous and not refresh then host:showDiscoveryCategoryPicker(previous);return true end
    if host.isNetworkOnline and not host:isNetworkOnline() then
        if previous then
            host:showDiscoveryCategoryPicker(previous)
            host:showTransientInfo(_('Offline. Showing saved rankings and categories.'),3)
        else host:showInfo(_('No saved categories. Connect to Wi-Fi to load them.')) end
        return false
    end
    local job={account=host.library_db:accountKey(),epoch=host.discovery_epoch or 0,session=host._reader_session_gen,started=os.time()}
    host.category_catalog_request=job;host.discovery_loading=true
    local function current()
        local age=os.time()-job.started
        return host.category_catalog_request==job and job.account==host.library_db:accountKey()
            and job.epoch==(host.discovery_epoch or 0) and job.session==host._reader_session_gen and age>=0 and age<=120
    end
    local function complete(result)
        if not current() then if host.category_catalog_request==job then M.cancel(host) end;return end
        local ok,value=pcall(function()
            if type(result)~='table' or result.ok~=true then return nil end
            return Catalog.validate(result.catalog)
        end)
        M.cancel(host)
        if not ok or not value then
            if previous then
                host.discovery_categories=previous;host:showDiscoveryCategoryPicker(previous)
                host:showTransientInfo(_('Could not refresh rankings and categories. Saved categories are still available.'),3)
            else host:showInfo(_('Could not load rankings and categories. Please try again later.')) end
            return
        end
        local db=store(host)
        local saved,written
        if db then saved,written=pcall(db.write,db,value) end
        host.discovery_categories=value
        host:showDiscoveryCategoryPicker(value)
        if not saved or written~=true then host:showTransientInfo(_('Could not save categories for offline use. The current list is still available.'),3) end
    end
    host:showBusy(_('Loading rankings and categories…\nTap or press a key to cancel.'),function()
        if host.category_catalog_request==job then M.cancel(host) end
    end)
    job.busy=host.busy_message
    local ok,started=pcall(host.runOnlineTask,host,_('Rankings and categories'),function()
        if not current() then if host.category_catalog_request==job then M.cancel(host) end;return end
        local ready,worker=pcall(function()
            return host.category_catalog_worker or require('weread.lib.memory_worker'):new{scheduler=UIManager,codec=host.client,max_bytes=Catalog.MAX_PAYLOAD}
        end)
        if not ready then complete(nil);return end
        host.category_catalog_worker=worker
        local launched,running=pcall(worker.start,worker,function()
            local catalog=Catalog.project(host.client:get_store_categories())
            return {ok=true,catalog=catalog}
        end,complete)
        if not launched or not running then complete(nil) end
    end)
    if not ok then complete(nil)
    elseif started==false and host.category_catalog_request==job then M.cancel(host) end
    return ok and started~=false
end
return M
