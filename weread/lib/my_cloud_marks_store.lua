-- Account-local display snapshots. Payload quotas exclude SQLite/WAL overhead.
local Data=require('weread.lib.my_cloud_marks')
local M={MAX_BOOKS=64,MAX_PAYLOAD=4*1024*1024,MAX_TOTAL=32*1024*1024};M.__index=M
function M:new(library,codec) return setmetatable({library=library,codec=codec},self) end
local function statement(db,sql,...)
    local stmt=db:prepare(sql);local args={...}
    local ok,row=pcall(function() return stmt:bind(unpack(args)):step() end)
    stmt:close();if not ok then error('my_marks_store/statement',0) end;return row
end
local function run(self,task)
    if not self.library then return nil end
    local db=self.library:open();if not db then return nil end
    local transaction=false
    local ok,result=pcall(function()
        db:exec([[CREATE TABLE IF NOT EXISTS my_cloud_marks (
            book_id TEXT PRIMARY KEY,payload TEXT NOT NULL,serial INTEGER NOT NULL
        )]])
        return task(db,function() db:exec('BEGIN IMMEDIATE');transaction=true end,
            function() db:exec('COMMIT');transaction=false end)
    end)
    if transaction then pcall(db.exec,db,'ROLLBACK') end
    pcall(db.close,db);return ok and result or nil
end
function M:read(id)
    if not Data.id(id) then return nil end
    return run(self,function(db)
        local row=statement(db,[[SELECT CASE WHEN length(CAST(payload AS BLOB))<=? THEN payload ELSE NULL END
            FROM my_cloud_marks WHERE book_id=?]],M.MAX_PAYLOAD,id)
        if not row or type(row[1])~='string' then return nil end
        return Data.validate(self.codec,self.codec:json_decode(row[1]),id)
    end)
end
function M:write(value)
    local valid,projected=pcall(Data.validate,self.codec,value,type(value)=='table' and value.book_id)
    if not valid then return false end
    local encoded,payload=pcall(self.codec.json_encode,self.codec,projected)
    if not encoded or type(payload)~='string' or #payload>M.MAX_PAYLOAD then return false end
    return run(self,function(db,begin,commit)
        begin()
        statement(db,[[INSERT INTO my_cloud_marks(book_id,payload,serial)
            VALUES(?,?,(SELECT COALESCE(MAX(serial),0)+1 FROM my_cloud_marks))
            ON CONFLICT(book_id) DO UPDATE SET payload=excluded.payload,serial=excluded.serial]],projected.book_id,payload)
        local stmt=db:prepare('SELECT book_id,length(CAST(payload AS BLOB)) FROM my_cloud_marks ORDER BY serial DESC')
        local remove,count,bytes={},0,0
        local ok=pcall(function()
            local row=stmt:step()
            while row do
                count=count+1;if count>M.MAX_BOOKS+1 then error('my_marks_store/quota',0) end
                bytes=bytes+tonumber(row[2])
                if count>M.MAX_BOOKS or bytes>M.MAX_TOTAL then remove[#remove+1]=row[1] end
                row=stmt:step()
            end
        end)
        stmt:close();if not ok then error('my_marks_store/quota',0) end
        for _i,id in ipairs(remove) do statement(db,'DELETE FROM my_cloud_marks WHERE book_id=?',id) end
        commit();return true
    end)==true
end
return M
