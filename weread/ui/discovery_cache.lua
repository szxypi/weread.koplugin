-- Cache access has no authorization or network path. Restored batches never
-- carry source revisions or native recommendation session IDs into requests.
local Cache=require('weread.lib.discovery_cache')
local _=require('weread.lib.plugin_util').tr
local M={}
local function store(host,account)
    if account then return Cache:new(host.library_db,host.client) end
    return require('weread.lib.public_discovery_cache'):new(host.settings,host.client)
end
function M.read(host,query,cursor)
    if not host.library_db then return nil end
    local account=host.library_db:accountKey()
    local ok,value=pcall(function()
        return store(host,account):read(query,cursor)
    end)
    if ok and value and account==host.library_db:accountKey()
        and (not query or not query.public_only or value.source_kind=='public') then value.account=account;return value end
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
    -- Guest search terms are not written to the shared public category cache.
    if state.kind=='search' and state.source_kind=='public' and not host.library_db:accountKey() then return false end
    local ok,generation,reference=pcall(function()
        local account=host.library_db:accountKey()
        if state.account~=account then return nil end
        return store(host,account):write(state,previous,continuation)
    end)
    if ok and generation then state._cache_generation=generation;state._cache_view=reference;return true end
    if host.showTransientInfo then host:showTransientInfo(_('Could not save books for offline use. The current list is still available.'),3) end
    return false
end
function M.remember(host,state,position)
    if not state._cache_view or state.account~=host.library_db:accountKey() then return false end
    local ok,saved=pcall(function() return store(host,state.account):remember(state,position) end)
    return ok and saved==true
end
return M
