-- Cache access has no authorization or network path. Restored batches never
-- carry source revisions or native recommendation session IDs into requests.
local Cache=require('weread.lib.discovery_cache')
local _=require('weread.lib.plugin_util').tr
local M={}
local function store(host,account)
    if account then return Cache:new(host.library_db,host.client) end
    return require('weread.lib.public_discovery_cache'):new(host.settings,host.client)
end
function M.read(host,query,cursor,continuation)
    if not host.library_db then return nil end
    local account=host.library_db:accountKey()
    if continuation and continuation.account~=account then return nil end
    local category=account and query and query.kind=='category'
    local shared=category and continuation and continuation._shared_public_category
    local ok,value,from_public=pcall(function()
        if not shared then
            local own=store(host,account):read(query,cursor)
            if own or not (category and cursor==0 and not continuation) then return own end
        end
        return store(host):read(query,cursor),true
    end)
    if not ok or not value or account~=host.library_db:accountKey()
        or query and query.public_only and value.source_kind~='public' then return nil end
    if from_public then
        -- Remain on the same public chain while paging, even if the account
        -- acquires its own cache or another process replaces the public batch.
        if shared then
            local prior, ref=continuation._cache_view,value._cache_view
            if not prior or not ref or prior.key~=ref.key or prior.generation~=ref.generation then return nil end
        end
        value._shared_public_category=true
    end
    value.account=account
    return value
end
function M.open(host,query,cursor,origin,continuation)
    local value=M.read(host,query,cursor,continuation)
    if not value then return false end
    require('weread.ui.bookstore_navigation').show(host,value,origin,continuation)
    return true
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
    if state._shared_public_category or not state._cache_view or state.account~=host.library_db:accountKey() then return false end
    local ok,saved=pcall(function() return store(host,state.account):remember(state,position) end)
    return ok and saved==true
end
return M
