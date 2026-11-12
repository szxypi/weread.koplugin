-- Guest category batches only, beside the anonymous category hierarchy.
-- Account-local search/recommendation/similar caches never enter this file.
local Cache=require('weread.lib.discovery_cache')
local M={};M.__index=M
local function public(value)
    return type(value)=='table' and value.kind=='category' and value.source_kind=='public'
end
function M:new(settings,codec)
    local directory=settings.data_dir
    local library={open=function()
        if type(directory)~='string' or directory=='' then return nil end
        local opened,db=pcall(function() return require('lua-ljsqlite3/init').open(directory..'/bookstore-public.db') end)
        if not opened or not db then return nil end
        local ok=pcall(function()
            db:exec('PRAGMA busy_timeout=1000')
            db:exec('PRAGMA journal_mode=WAL')
            db:exec('PRAGMA synchronous=NORMAL')
        end)
        if ok then return db end
        pcall(db.close,db);return nil
    end}
    return setmetatable({cache=Cache:new(library,codec)},self)
end
function M:read(query,cursor)
    if query and query.kind~='category' then return nil end
    local value=self.cache:read(query,cursor)
    if public(value) then return value end
end
function M:write(state,previous,continuation)
    if not public(state) or previous and not public(previous) then return nil end
    return self.cache:write(state,previous,continuation)
end
return M
