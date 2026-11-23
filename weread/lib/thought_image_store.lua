-- Bounded per-account image bytes. Binary strings are bound with explicit
-- lengths; every read checks the content hash and image dimensions again.
local Crypto=require('weread.lib.crypto')
local Marks=require('weread.lib.my_cloud_marks')
local Attachments=require('weread.lib.thought_attachments')
local Images=require('weread.lib.thought_image_data')
local M={MAX_ENTRIES=128,MAX_TOTAL=32*1024*1024};M.__index=M
function M:new(library) return setmetatable({library=library},self) end
function M.key(book,review,url)
    if not Marks.display_id(book) or not require('weread.lib.thought_edit_contract').key(review)
        or not Attachments.allowed(url) then return nil end
    return Crypto.sha256_hex('thought-image-v1\0'..book..'\0'..review..'\0'..url)
end
local function statement(db,sql,...)
    local stmt=db:prepare(sql);local args={...}
    local ok,row=pcall(function() return stmt:bind(unpack(args)):step() end)
    stmt:close();if not ok then error('thought_image_store/statement',0) end;return row
end
local function run(self,owner,write,task)
    if not self.library or type(owner)~='string' or self.library:accountKey()~=owner then return nil end
    local db=write and self.library:open() or self.library.openRead and self.library:openRead()
    if not db then return nil end
    local transaction=false
    local ok,result=pcall(function()
        if write then
            db:exec([[CREATE TABLE IF NOT EXISTS thought_image_cache (
                cache_key TEXT PRIMARY KEY,body TEXT NOT NULL,digest TEXT NOT NULL,serial INTEGER NOT NULL)]])
            db:exec('BEGIN IMMEDIATE');transaction=true
        else
            local schema=statement(db,'SELECT type FROM sqlite_master WHERE name=? COLLATE NOCASE','thought_image_cache')
            if not schema or schema[1]~='table' then return nil end
        end
        if self.library:accountKey()~=owner then error('thought_image_store/account',0) end
        local value=task(db)
        if self.library:accountKey()~=owner then error('thought_image_store/account',0) end
        if transaction then db:exec('COMMIT');transaction=false end
        return value
    end)
    if transaction then pcall(db.exec,db,'ROLLBACK') end
    pcall(db.close,db);return ok and result or nil
end
function M:read(owner,key)
    if type(key)~='string' or #key~=64 or not key:match('^[a-f0-9]+$') then return nil end
    return run(self,owner,false,function(db)
        local row=statement(db,[[SELECT CASE WHEN length(CAST(body AS BLOB))<=? THEN body ELSE NULL END,digest
            FROM thought_image_cache WHERE cache_key=?]],Images.MAX_BYTES,key)
        if not row or type(row[1])~='string' or type(row[2])~='string' or #row[2]~=64
            or Crypto.sha256_hex(row[1])~=row[2] or not Images.dimensions(row[1]) then return nil end
        return row[1]
    end)
end
function M:write(owner,key,data)
    if type(key)~='string' or #key~=64 or not key:match('^[a-f0-9]+$') or not Images.dimensions(data) then return false end
    return run(self,owner,true,function(db)
        statement(db,[[INSERT INTO thought_image_cache(cache_key,body,digest,serial)
            VALUES(?,?,?,(SELECT COALESCE(MAX(serial),0)+1 FROM thought_image_cache))
            ON CONFLICT(cache_key) DO UPDATE SET body=excluded.body,digest=excluded.digest,serial=excluded.serial]],
            key,data,Crypto.sha256_hex(data))
        local stmt=db:prepare('SELECT cache_key,length(CAST(body AS BLOB)) FROM thought_image_cache ORDER BY serial DESC')
        local remove,count,total={},0,0
        local ok=pcall(function()
            local row=stmt:step()
            while row do
                count=count+1;if count>M.MAX_ENTRIES+1 then error('thought_image_store/quota',0) end
                local size=tonumber(row[2]);if not size or size<1 or size>Images.MAX_BYTES then error('thought_image_store/quota',0) end
                total=total+size
                if count>M.MAX_ENTRIES or total>M.MAX_TOTAL then remove[#remove+1]=row[1] end
                row=stmt:step()
            end
        end)
        stmt:close();if not ok then error('thought_image_store/quota',0) end
        for _,old in ipairs(remove) do statement(db,'DELETE FROM thought_image_cache WHERE cache_key=?',old) end
        return true
    end)==true
end
return M
