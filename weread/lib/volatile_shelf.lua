-- A successfully read but unsaved shelf lives only in the current login.
local Source=require('weread.lib.shelf_source')
local Crypto=require('weread.lib.crypto')
local M={}

local function account(host)
    local db=host.library_db
    if not db or type(db.accountKey)~='function' then return nil end
    local ok,value=pcall(db.accountKey,db)
    return ok and type(value)=='string' and value~='' and value or nil
end

local function key_hash(settings)
    local value=settings:get('api_key','')
    return Crypto.sha256_hex(type(value)=='string' and value or '')
end

function M.clear(host) host._volatile_shelf=nil end

function M.remember(host,snapshot,result)
    M.clear(host)
    local owner=account(host);local settings=host.settings
    if not owner or type(snapshot)~='table' or type(snapshot.books)~='table'
        or type(snapshot.archives)~='table' or type(settings)~='table' then return false end
    local ok,scope=pcall(function()
        if not settings.get_auth_scope then return false end
        local value=settings:get_auth_scope()
        if not value or not settings:auth_scope_matches(value) then error('invalid scope') end
        return {vid=value.vid,epoch=value.epoch}
    end)
    if not ok then return false end
    result=type(result)=='table' and result or {}
    local valid,mode,api_hash=pcall(function()
        return Source.mode(settings),result._shelf_source=='gateway' and key_hash(settings) or false
    end)
    if not valid then return false end
    host._volatile_shelf={snapshot=snapshot,owner=owner,scope=scope,mode=mode,api_hash=api_hash,
        native_revision=result._native_revision,web_revision=result._web_revision}
    return true
end

function M.get(host)
    local saved=host._volatile_shelf
    if not saved then return nil end
    local ok,valid=pcall(function()
        local settings=host.settings
        if account(host)~=saved.owner or Source.mode(settings)~=saved.mode then return false end
        if saved.scope then
            if not settings.get_auth_scope or not settings:auth_scope_matches(saved.scope) then return false end
        elseif settings.get_auth_scope then return false end
        if saved.api_hash and key_hash(settings)~=saved.api_hash then return false end
        if saved.native_revision then
            local selected=Source.selection(settings)
            if not selected.credentials or selected.revision~=saved.native_revision then return false end
        end
        if saved.web_revision and Source.web_revision(settings)~=saved.web_revision then return false end
        return true
    end)
    if not ok or not valid then M.clear(host);return nil end
    return saved.snapshot
end

return M
