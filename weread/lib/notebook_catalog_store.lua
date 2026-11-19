-- Per-account SQLite snapshot with a strict payload bound.
local Data=require('weread.lib.notebook_catalog')
local M={MAX_PAYLOAD=2*1024*1024};M.__index=M
function M:new(library,codec,account) return setmetatable({library=library,codec=codec,account=account},self) end
local function current(self) return self.account~=nil and self.library:accountKey()==self.account end
function M:read()
    if not current(self) then return nil end
    local db
    if self.library.openRead then db=self.library:openRead() else db=self.library:open() end
    if not db then return nil end
    local stmt
    local ok,result=pcall(function()
        if not current(self) then return nil end
        stmt=db:prepare([[SELECT CASE WHEN length(CAST(payload AS BLOB))<=? THEN payload ELSE NULL END
            FROM profile_state WHERE name='notebook_catalog']])
        local value=stmt:bind(M.MAX_PAYLOAD):step();stmt:close();stmt=nil
        if not value or type(value[1])~='string' or not current(self) then return nil end
        return Data.validate(self.codec,self.codec:json_decode(value[1]))
    end)
    if stmt then pcall(stmt.close,stmt) end;pcall(db.close,db)
    return ok and result or nil
end
function M:write(value)
    if not current(self) then return false end
    local valid,normalized=pcall(Data.validate,self.codec,value);if not valid then return false end
    local encoded,payload=pcall(self.codec.json_encode,self.codec,normalized)
    if not encoded or type(payload)~='string' or #payload>M.MAX_PAYLOAD then return false end
    local db=self.library:open();if not db then return false end
    local stmt,transaction
    local ok=pcall(function()
        if not current(self) then error('stale',0) end
        db:exec('BEGIN IMMEDIATE');transaction=true
        stmt=db:prepare([[INSERT INTO profile_state(name,payload) VALUES('notebook_catalog',?)
            ON CONFLICT(name) DO UPDATE SET payload=excluded.payload]])
        stmt:bind(payload):step();stmt:close();stmt=nil
        if not current(self) then error('stale',0) end
        db:exec('COMMIT');transaction=false
    end)
    if stmt then pcall(stmt.close,stmt) end
    if transaction then pcall(db.exec,db,'ROLLBACK') end
    pcall(db.close,db)
    return ok and current(self)
end
return M
