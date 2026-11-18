-- Account-local, bounded interrupted translation downloads. These are
-- provisional chapter captures, not proof of the current cloud version.
local Crypto=require('weread.lib.crypto')
local Source=require('weread.lib.position_source')
local M={MAX_BOOKS=4,MAX_TOTAL=32*1024*1024,MAX_MANIFEST=2*1024*1024};M.__index=M

local function query(db,sql,...)
    local stmt=db:prepare(sql);local args={...}
    local ok,result=pcall(function()
        if #args>0 then stmt:bind(unpack(args)) end
        local rows={};while true do local row=stmt:step();if not row then return rows end;rows[#rows+1]=row end
    end)
    stmt:close();if not ok then error(result,0) end;return result
end
local function same(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~='table' then return a==b end
    for k,v in pairs(a) do if not same(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
local function nonce()
    local f=assert(io.open('/dev/urandom','rb'));local raw=f:read(16);assert(f:close() and raw and #raw==16)
    return (raw:gsub('.',function(c) return string.format('%02x',c:byte()) end))
end
local function text(v,n) return type(v)=='string' and #v>0 and #v<=n and not v:find('[%z%c]') end
function M:new(library,codec,scope)
    return setmetatable({library=library,codec=codec,scope=scope,account=library:accountKey()},self)
end
function M:_open()
    if not self.account or self.library:accountKey()~=self.account or not self.scope
        or not self.library.settings:auth_scope_matches(self.scope) then return nil end
    local db=self.library:open();if not db then return nil end
    local ok=pcall(function()
        db:exec([[CREATE TABLE IF NOT EXISTS translation_pending (
            book_id TEXT PRIMARY KEY, source_id TEXT NOT NULL, generation TEXT NOT NULL,
            manifest TEXT NOT NULL, started INTEGER NOT NULL
        ) WITHOUT ROWID]])
        db:exec([[CREATE TABLE IF NOT EXISTS translation_pending_chapters (
            book_id TEXT NOT NULL, generation TEXT NOT NULL, uid TEXT NOT NULL,
            raw TEXT NOT NULL, digest TEXT NOT NULL,
            PRIMARY KEY(book_id,generation,uid)
        ) WITHOUT ROWID]])
    end)
    if not ok then pcall(db.close,db);return nil end
    return db
end
local function access(self,func)
    local db=self:_open();if not db then return nil end
    local ok,result=pcall(func,db)
    if not ok then pcall(db.exec,db,'ROLLBACK') end
    pcall(db.close,db);return ok and result or nil
end
function M:summary(book_id,source_id)
    if not text(book_id,256) or not text(source_id,64) then return nil end
    return access(self,function(db)
        local rows=query(db,[[SELECT p.started,COUNT(c.uid),p.generation FROM translation_pending p
            LEFT JOIN translation_pending_chapters c ON c.book_id=p.book_id AND c.generation=p.generation
            WHERE p.book_id=? AND p.source_id=? GROUP BY p.book_id]],book_id,source_id)
        local row=rows[1];local started=row and tonumber(row[1]);local count=row and tonumber(row[2])
        if started and started>0 and count and count>0 and type(row[3])=='string' and #row[3]==32
            and row[3]:match('^[a-f0-9]+$') then return {started=started,count=count,generation=row[3]} end
    end)
end
-- A cleanup preview retains this generation; it cannot delete a newer job.
function M:token(book_id)
    if not text(book_id,256) then return nil end
    return access(self,function(db)
        local row=query(db,'SELECT generation FROM translation_pending WHERE book_id=?',book_id)[1]
        if not row then return {book_id=book_id} end
        if type(row[1])~='string' or #row[1]~=32 or not row[1]:match('^[a-f0-9]+$') then error('translation_resume/invalid',0) end
        return {book_id=book_id,generation=row[1]}
    end)
end
function M:tokens()
    return access(self,function(db)
        local rows=query(db,'SELECT book_id,generation FROM translation_pending LIMIT ?',M.MAX_BOOKS+1)
        if #rows>M.MAX_BOOKS then error('translation_resume/invalid',0) end
        local result={}
        for _,row in ipairs(rows) do
            if not text(row[1],256) or type(row[2])~='string' or #row[2]~=32
                or not row[2]:match('^[a-f0-9]+$') or result[row[1]] then error('translation_resume/invalid',0) end
            result[row[1]]={book_id=row[1],generation=row[2]}
        end
        return result
    end)
end
function M:begin(book_id,source_id,chapters,version,resume)
    if not text(book_id,256) or not text(source_id,64) or type(chapters)~='table' or #chapters<1 or #chapters>2000 then return nil end
    local manifest=self.codec:json_encode({chapters=chapters,version=version})
    if type(manifest)~='string' or #manifest>M.MAX_MANIFEST then return nil end
    return access(self,function(db)
        db:exec('BEGIN IMMEDIATE')
        local rows=query(db,'SELECT source_id,generation,manifest FROM translation_pending WHERE book_id=?',book_id)
        local row=rows[1];local accepted=false
        if resume and row and row[1]==source_id and type(row[3])=='string' and #row[3]<=M.MAX_MANIFEST then
            local ok,old=pcall(self.codec.json_decode,self.codec,row[3])
            accepted=ok and type(old)=='table' and old.version==version and same(old.chapters,chapters)
        end
        local generation
        if accepted then generation=row[2]
        else
            query(db,'DELETE FROM translation_pending_chapters WHERE book_id=?',book_id)
            query(db,'DELETE FROM translation_pending WHERE book_id=?',book_id)
            local count=tonumber(query(db,'SELECT COUNT(*) FROM translation_pending')[1][1])
            if count>=M.MAX_BOOKS then db:exec('COMMIT');return nil end
            generation=nonce()
            query(db,'INSERT INTO translation_pending(book_id,source_id,generation,manifest,started) VALUES(?,?,?,?,?)',
                book_id,source_id,generation,manifest,os.time())
        end
        db:exec('COMMIT')
        return {book_id=book_id,generation=generation}
    end)
end
function M:get(token,uid)
    if type(token)~='table' or not text(token.book_id,256) or not text(token.generation,32) or not text(uid,256) then return nil end
    return access(self,function(db)
        local rows=query(db,[[SELECT c.raw,c.digest FROM translation_pending_chapters c
            JOIN translation_pending p ON p.book_id=c.book_id AND p.generation=c.generation
            WHERE c.book_id=? AND c.generation=? AND c.uid=?
            AND length(CAST(c.raw AS BLOB))<=?]],token.book_id,token.generation,uid,Source.MAX_BYTES)
        local row=rows[1]
        if row and type(row[1])=='string' and #row[1]>0 and Crypto.sha256_hex(row[1])==row[2] then return row[1] end
    end)
end
function M:put(token,uid,raw)
    if type(token)~='table' or not text(token.book_id,256) or not text(token.generation,32)
        or not text(uid,256) or type(raw)~='string' or #raw<1 or #raw>Source.MAX_BYTES then return false end
    return access(self,function(db)
        db:exec('BEGIN IMMEDIATE')
        local rows=query(db,'SELECT generation FROM translation_pending WHERE book_id=?',token.book_id)
        if not rows[1] or rows[1][1]~=token.generation then db:exec('COMMIT');return false end
        local total=tonumber(query(db,'SELECT COALESCE(SUM(length(CAST(raw AS BLOB))),0) FROM translation_pending_chapters')[1][1])
        local old=query(db,'SELECT length(CAST(raw AS BLOB)) FROM translation_pending_chapters WHERE book_id=? AND generation=? AND uid=?',
            token.book_id,token.generation,uid)
        if total-(old[1] and tonumber(old[1][1]) or 0)+#raw>M.MAX_TOTAL then db:exec('COMMIT');return false end
        query(db,'INSERT OR REPLACE INTO translation_pending_chapters(book_id,generation,uid,raw,digest) VALUES(?,?,?,?,?)',
            token.book_id,token.generation,uid,raw,Crypto.sha256_hex(raw))
        db:exec('COMMIT');return true
    end) or false
end
function M:clear(token)
    if type(token)~='table' or not text(token.book_id,256) or not text(token.generation,32) then return false end
    return access(self,function(db)
        db:exec('BEGIN IMMEDIATE')
        local row=query(db,'SELECT generation FROM translation_pending WHERE book_id=?',token.book_id)[1]
        if row and row[1]~=token.generation then db:exec('COMMIT');return false end
        query(db,'DELETE FROM translation_pending_chapters WHERE book_id=? AND generation=?',token.book_id,token.generation)
        query(db,'DELETE FROM translation_pending WHERE book_id=? AND generation=?',token.book_id,token.generation)
        db:exec('COMMIT');return true
    end) or false
end
return M
