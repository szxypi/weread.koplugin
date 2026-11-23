-- Account-local source cache for native-chapter personal mark placement.
-- A stored chapter is only useful with its independently verified cache entry;
-- the complete original bytes are checked again on every read.
local Crypto=require('weread.lib.crypto')
local Cache=require('weread.lib.native_direct_cache')
local Coordinates=require('weread.lib.source_coordinates')
local M={MAX_SOURCE=Coordinates.MAX_BYTES,MAX_TOTAL=32*1024*1024,MAX_ENTRIES=128};M.__index=M
function M:new(library) return setmetatable({library=library},self) end
local function statement(db,sql,...)
    local stmt=db:prepare(sql);local args={...}
    local ok,row=pcall(function() return stmt:bind(unpack(args)):step() end)
    stmt:close();if not ok then error('direct_mark_source/statement',0) end;return row
end
local function valid(entry)
    return type(entry)=='table' and Cache.valid_entry(entry,entry.book_id)
        and type(entry.file_id)=='string' and #entry.file_id==64 and entry.file_id:match('^[a-f0-9]+$')~=nil
end
local function run(self,write,task)
    if not self.library then return nil end
    local db=write and self.library:open() or self.library.openRead and self.library:openRead()
    if not db then return nil end
    local transaction=false
    local ok,value=pcall(function()
        if write then
            db:exec([[CREATE TABLE IF NOT EXISTS native_direct_mark_source (
                cache_key TEXT PRIMARY KEY,book_id TEXT NOT NULL,chapter_uid TEXT NOT NULL,file_id TEXT NOT NULL,
                source_hash TEXT NOT NULL,body TEXT NOT NULL,serial INTEGER NOT NULL)]])
        else
            local schema=statement(db,'SELECT type FROM sqlite_master WHERE name=? COLLATE NOCASE','native_direct_mark_source')
            if not schema or schema[1]~='table' then return nil end
        end
        return task(db,function() db:exec('BEGIN IMMEDIATE');transaction=true end,
            function() db:exec('COMMIT');transaction=false end)
    end)
    if transaction then pcall(db.exec,db,'ROLLBACK') end
    pcall(db.close,db);return ok and value or nil
end
function M:read(entry)
    if not valid(entry) then return nil end
    return run(self,false,function(db)
        local row=statement(db,[[SELECT book_id,chapter_uid,file_id,source_hash,
            CASE WHEN length(CAST(body AS BLOB))<=? THEN body ELSE NULL END
            FROM native_direct_mark_source WHERE cache_key=?]],M.MAX_SOURCE,entry.key)
        if not row or row[1]~=entry.book_id or row[2]~=entry.chapter_uid or row[3]~=entry.file_id
            or row[4]~=entry.source_sha256 or type(row[5])~='string' or #row[5]==0
            or Crypto.sha256_hex(row[5])~=entry.source_sha256 then return nil end
        return row[5]
    end)
end
function M:write(entry,raw)
    if not valid(entry) or type(raw)~='string' or #raw==0 or #raw>M.MAX_SOURCE
        or Crypto.sha256_hex(raw)~=entry.source_sha256 then return false end
    local value=run(self,true,function(db,begin,commit)
        begin()
        statement(db,[[INSERT INTO native_direct_mark_source(cache_key,book_id,chapter_uid,file_id,source_hash,body,serial)
            VALUES(?,?,?,?,?,?,(SELECT COALESCE(MAX(serial),0)+1 FROM native_direct_mark_source))
            ON CONFLICT(cache_key) DO UPDATE SET book_id=excluded.book_id,chapter_uid=excluded.chapter_uid,
            file_id=excluded.file_id,source_hash=excluded.source_hash,body=excluded.body,serial=excluded.serial]],
            entry.key,entry.book_id,entry.chapter_uid,entry.file_id,entry.source_sha256,raw)
        local stmt=db:prepare('SELECT cache_key,length(CAST(body AS BLOB)) FROM native_direct_mark_source ORDER BY serial DESC')
        local remove,count,total={},0,0
        local ok=pcall(function()
            local row=stmt:step()
            while row do
                count=count+1;if count>M.MAX_ENTRIES+1 then error('direct_mark_source/quota',0) end
                local size=tonumber(row[2]);if not size or size<1 or size>M.MAX_SOURCE then error('direct_mark_source/quota',0) end
                total=total+size
                if count>M.MAX_ENTRIES or total>M.MAX_TOTAL then remove[#remove+1]=row[1] end
                row=stmt:step()
            end
        end)
        stmt:close();if not ok then error('direct_mark_source/quota',0) end
        for _,key in ipairs(remove) do statement(db,'DELETE FROM native_direct_mark_source WHERE cache_key=?',key) end
        commit();return true
    end)
    return value==true
end
return M
