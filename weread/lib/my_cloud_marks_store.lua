-- Account-local display snapshots. Payload quotas exclude SQLite/WAL overhead.
local Data=require('weread.lib.my_cloud_marks')
-- Match the notebook catalog's bounded 5,000 entries. The independent byte
-- limit still bounds disk usage even when many books contain very few notes.
local M={MAX_BOOKS=5000,MAX_PAYLOAD=4*1024*1024,MAX_TOTAL=32*1024*1024};M.__index=M
function M:new(library,codec,variant)
    assert(variant==nil or variant=='thoughts','invalid personal note store')
    return setmetatable({library=library,codec=codec,table_name=variant=='thoughts' and 'my_cloud_thoughts' or 'my_cloud_marks',
        data=variant=='thoughts' and require('weread.lib.my_cloud_thoughts') or Data},self)
end
local function statement(db,sql,...)
    local stmt=db:prepare(sql);local args={...}
    local ok,row=pcall(function() return stmt:bind(unpack(args)):step() end)
    stmt:close();if not ok then error('my_marks_store/statement',0) end;return row
end
local function run(self,task,read_only,empty)
    if not self.library or self.table_name~='my_cloud_marks' and self.table_name~='my_cloud_thoughts' then return nil end
    local db
    if read_only and type(self.library.openRead)=='function' then
        db=self.library:openRead()
        if not db then
            -- A missing account database is an empty cache, but an unreadable
            -- or locked existing database must remain an error, not an empty list.
            local path=type(self.library.databasePath)=='function' and self.library:databasePath()
            local ok,lfs=pcall(require,'libs/libkoreader-lfs')
            if empty and path and ok then
                local attributes,_,code=lfs.attributes(path)
                if not attributes and code==2 then return empty end
            end
            return nil
        end
    else
        db=self.library:open()
        if not db then return nil end
    end
    local transaction=false
    local ok,result=pcall(function()
        if read_only then
            local schema=statement(db,'SELECT type FROM sqlite_master WHERE name=? COLLATE NOCASE',self.table_name)
            if not schema then return empty end
            if schema[1]~='table' then error('my_marks_store/schema',0) end
        else
            db:exec([[CREATE TABLE IF NOT EXISTS ]]..self.table_name..[[ (
                book_id TEXT PRIMARY KEY,payload TEXT NOT NULL,serial INTEGER NOT NULL
            )]])
        end
        return task(db,function() db:exec('BEGIN IMMEDIATE');transaction=true end,
            function() db:exec('COMMIT');transaction=false end)
    end)
    if transaction then pcall(db.exec,db,'ROLLBACK') end
    pcall(db.close,db);return ok and result or nil
end
function M:read(id)
    if not Data.display_id(id) then return nil end
    return run(self,function(db)
        local row=statement(db,[[SELECT CASE WHEN length(CAST(payload AS BLOB))<=? THEN payload ELSE NULL END
            FROM ]]..self.table_name..[[ WHERE book_id=?]],M.MAX_PAYLOAD,id)
        if not row or type(row[1])~='string' then return nil end
        return self.data.validate(self.codec,self.codec:json_decode(row[1]),id)
    end,true)
end
-- Enumerate only bounded account-local snapshot identities; payloads are
-- validated separately by read() and never returned by this query.
function M:list_ids()
    return run(self,function(db)
        local stmt=db:prepare('SELECT book_id FROM '..self.table_name..' ORDER BY serial DESC, book_id LIMIT ?')
        local ids,seen={},{}
        local ok=pcall(function()
            local row=stmt:bind(M.MAX_BOOKS+1):step()
            while row do
                local id=row[1]
                if not Data.display_id(id) or seen[id] or #ids>=M.MAX_BOOKS then error('my_marks_store/identities',0) end
                seen[id]=true;ids[#ids+1]=id;row=stmt:step()
            end
        end)
        stmt:close();if not ok then error('my_marks_store/identities',0) end
        return ids
    end,true,{})
end
-- Return only snapshots that can actually be decoded and validated. A corrupt
-- or inaccessible existing row is an error, not proof that it is missing.
function M:valid_ids(ids)
    if type(ids)~='table' or #ids>M.MAX_BOOKS then return nil end
    local seen,count={},0
    for key in pairs(ids) do
        if type(key)~='number' or key%1~=0 or key<1 or key>#ids then return nil end
        count=count+1
    end
    if count~=#ids then return nil end
    for _,id in ipairs(ids) do
        if not Data.display_id(id) or seen[id] then return nil end
        seen[id]=true
    end
    return run(self,function(db)
        local stmt=db:prepare('SELECT CASE WHEN length(CAST(payload AS BLOB))<=? THEN payload ELSE NULL END FROM '
            ..self.table_name..' WHERE book_id=?')
        local result={}
        local ok=pcall(function()
            for _,id in ipairs(ids) do
                local row=stmt:reset():bind(M.MAX_PAYLOAD,id):step()
                if row then
                    if type(row[1])~='string' then error('my_marks_store/invalid_snapshot',0) end
                    self.data.validate(self.codec,self.codec:json_decode(row[1]),id)
                    result[id]=true
                end
            end
        end)
        stmt:close();if not ok then error('my_marks_store/invalid_snapshot',0) end
        return result
    end,true,{})
end
local function save(self,value,options)
    local valid,projected=pcall(self.data.validate,self.codec,value,type(value)=='table' and value.book_id)
    if not valid then return nil end
    local encoded,payload=pcall(self.codec.json_encode,self.codec,projected)
    if not encoded or type(payload)~='string' or #payload>M.MAX_PAYLOAD then return nil,projected end
    local result=run(self,function(db,begin,commit)
        begin()
        if options and options.only_if_absent then
            local existing=statement(db,'SELECT CASE WHEN length(CAST(payload AS BLOB))<=? THEN payload ELSE NULL END FROM '
                ..self.table_name..' WHERE book_id=?',M.MAX_PAYLOAD,projected.book_id)
            if existing then
                if type(existing[1])~='string' then error('my_marks_store/invalid_snapshot',0) end
                self.data.validate(self.codec,self.codec:json_decode(existing[1]),projected.book_id)
                commit();return 'exists'
            end
        end
        statement(db,[[INSERT INTO ]]..self.table_name..[[(book_id,payload,serial)
            VALUES(?,?,(SELECT COALESCE(MAX(serial),0)+1 FROM ]]..self.table_name..[[))
            ON CONFLICT(book_id) DO UPDATE SET payload=excluded.payload,serial=excluded.serial]],projected.book_id,payload)
        -- Most libraries fit comfortably inside both quotas. Let SQLite
        -- check that common case without transferring and sorting every row
        -- in Lua. The existing ordered eviction path handles all overflow.
        local totals=statement(db,'SELECT COUNT(*),COALESCE(SUM(length(CAST(payload AS BLOB))),0) FROM '..self.table_name)
        local total_count,total_bytes=totals and tonumber(totals[1]),totals and tonumber(totals[2])
        if total_count and total_bytes and total_count<=M.MAX_BOOKS and total_bytes<=M.MAX_TOTAL then
            commit();return true
        end
        local stmt=db:prepare('SELECT book_id,length(CAST(payload AS BLOB)) FROM '..self.table_name..' ORDER BY serial DESC')
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
        -- A bulk refresh must never evict unrelated saved notes to make room.
        -- Roll back the insertion or replacement together with its new serial.
        if options and #remove>0 then error('my_marks_store/preserve_quota',0) end
        for _i,id in ipairs(remove) do statement(db,'DELETE FROM '..self.table_name..' WHERE book_id=?',id) end
        commit();return true
    end)
    return result,projected
end
function M:write(value,options)
    if options~=nil and (type(options)~='table' or options.preserve_existing~=true) then return false end
    return save(self,value,options)==true
end
-- Atomically preserve a row that another task saved after the missing scan.
function M:writeIfMissing(value)
    local result=save(self,value,{preserve_existing=true,only_if_absent=true})
    return result
end
-- Validate once against the caller's book, then return the exact sanitized
-- snapshot used for persistence. A valid snapshot and failed write remain
-- distinguishable so the reader can fall back to its previous cache.
function M:writeProjected(value,book_id)
    if not Data.display_id(book_id) or type(value)~='table' or value.book_id~=book_id then return nil,false end
    local saved,projected=save(self,value)
    return projected,saved==true
end
return M
