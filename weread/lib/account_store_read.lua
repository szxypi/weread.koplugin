-- Read an already-initialized, account-scoped store without reinitializing WAL.
-- The caller falls back to its ordinary setup path only when a table is absent
-- or a read-only connection is unavailable, never on a damaged existing table.
local M={}
function M.try(library,tables,read)
    local account=library:accountKey();if not account then return nil,'account',true end
    if type(library.openRead)=='function' then
        local opened,db=pcall(library.openRead,library)
        if opened and db then
            local ok,value,missing=pcall(function()
                if db.set_busy_timeout then db:set_busy_timeout(50) end
                assert(library:accountKey()==account,'account_store_read/account')
                for _,name in ipairs(tables) do
                    local query=db:prepare("SELECT name FROM sqlite_master WHERE type='table' AND name=?")
                    local valid,row=pcall(function() return query:bind(name):step() end)
                    query:close();assert(valid,'account_store_read/schema')
                    if not row then return nil,true end
                end
                local result=read(db,account)
                assert(library:accountKey()==account,'account_store_read/account')
                return result,false
            end)
            pcall(db.close,db)
            if not ok then return nil,'storage',true end
            if not missing then return value,nil,true end
        end
    end
    if library:accountKey()~=account then return nil,'account',true end
    return nil,nil,false
end
return M
