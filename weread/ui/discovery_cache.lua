-- Cache access has no authorization or network path. Restored batches never
-- carry source revisions or native recommendation session IDs into requests.
local Cache=require('weread.lib.discovery_cache')
local _=require('weread.lib.plugin_util').tr
local M={}
function M.read(host,query,cursor)
    if not host.library_db then return nil end
    local account=host.library_db:accountKey()
    local ok,value=pcall(function()
        if account then return Cache:new(host.library_db,host.client):read(query,cursor) end
        return require('weread.lib.public_discovery_cache'):new(host.settings,host.client):read(query,cursor)
    end)
    if ok and value and account==host.library_db:accountKey() then value.account=account;return value end
end
function M.open(host,query,cursor)
    local value=M.read(host,query,cursor)
    if not value then return false end
    host.discovery_state=value
    if host._book_detail_view then
        local detail=host._book_detail_view;host._book_detail_view=nil;require('ui/uimanager'):close(detail)
    end
    host:showBookstore();return true
end
function M.save(host,state,previous,continuation)
    local ok,generation=pcall(function()
        local account=host.library_db:accountKey()
        if state.account~=account then return nil end
        if account then return Cache:new(host.library_db,host.client):write(state,previous,continuation) end
        return require('weread.lib.public_discovery_cache'):new(host.settings,host.client):write(state,previous,continuation)
    end)
    if ok and generation then state._cache_generation=generation;return true end
    if host.showTransientInfo then host:showTransientInfo(_('Could not save books for offline use. The current list is still available.'),3) end
    return false
end
return M
