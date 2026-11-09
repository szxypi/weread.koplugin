-- Immutable, account-separated snapshots; never store this collection in settings.
local Crypto=require('weread.lib.crypto')
local Data=require('weread.lib.mp_record_data')
local M={MAX_RECORDS=128,MAX_TOTAL=32*1024*1024,MAX_BATCH=11};M.__index=M
local kinds={primary=true,backup=true,live=true,beside=true,beside_backup=true,folder=true,folder_backup=true,
    legacy_beside=true,history=true,history_backup=true,compatibility=true}
local function hex(value,n) return type(value)=='string' and #value==n and value:match('^[a-f0-9]+$') end
local function valid(raw) return type(raw)=='string' and #raw>0 and #raw<=Data.MAX_BYTES and not raw:find('%z') end
local function close(value) if value then pcall(value.close,value) end end
function M.id(kind,raw) return kinds[kind] and valid(raw) and Crypto.sha256_hex(kind..'\0'..raw) or nil end
function M.new(settings,account,connect)
    if not hex(account,20) or type(settings.data_dir)~='string' or settings.data_dir:find('[%z%c]') then return nil end
    return setmetatable({path=settings.data_dir..'/mp-reading-records-'..account..'.db',connect=connect},M)
end
function M:exists()
    local result={require('libs/libkoreader-lfs').symlinkattributes(self.path)}
    -- Only a definite ENOENT permits the ordinary read-only path. Permission
    -- errors, a replacement directory or an unreadable archive are not empty.
    return result[1]~=nil or result[3]~=2
end
function M:open()
    local db
    local ok=pcall(function()
        if self.connect then db=self.connect(self.path)
        else
            local lfs=require('libs/libkoreader-lfs')
            local parent=self.path:match('^(.*)/[^/]+$')
            if lfs.symlinkattributes(parent,'mode')~='directory' then error('unavailable') end
            for _i,suffix in ipairs({'','-journal','-wal','-shm'}) do
                local mode=lfs.symlinkattributes(self.path..suffix,'mode')
                if mode and mode~='file' then error('unavailable') end
            end
            db=require('lua-ljsqlite3/init').open(self.path)
        end
        if db.set_busy_timeout then db:set_busy_timeout(250) end
        db:exec('PRAGMA journal_mode=DELETE');db:exec('PRAGMA synchronous=FULL')
        db:exec([[CREATE TABLE IF NOT EXISTS snapshots (
            article_key TEXT NOT NULL, record_id TEXT NOT NULL, source_kind TEXT NOT NULL,
            raw TEXT NOT NULL, recorded_at INTEGER NOT NULL,
            PRIMARY KEY(article_key,record_id)) WITHOUT ROWID]])
    end)
    if not ok then close(db);return nil end
    return db
end
function M:save(key,rows)
    if not hex(key,64) or type(rows)~='table' or #rows>M.MAX_BATCH then return false end
    local length=0
    for index,row in pairs(rows) do
        length=length+1
        if type(index)~='number' or index%1~=0 or index<1 or index>#rows or type(row)~='table'
            or not kinds[row.kind] or not valid(row.raw) then return false end
    end
    if length~=#rows then return false end
    local db=self:open();if not db then return false end
    local statement,lookup,count,transaction
    local ok=pcall(function()
        db:exec('BEGIN IMMEDIATE');transaction=true
        count=db:prepare('SELECT COUNT(*),COALESCE(SUM(LENGTH(CAST(raw AS BLOB))),0) FROM snapshots WHERE article_key=?')
        local totals=count:reset():bind(key):step();local n,bytes=tonumber(totals[1]),tonumber(totals[2])
        if not n or not bytes or n>M.MAX_RECORDS or bytes>M.MAX_TOTAL then error('capacity') end
        lookup=db:prepare('SELECT source_kind,raw FROM snapshots WHERE article_key=? AND record_id=?')
        statement=db:prepare('INSERT INTO snapshots(article_key,record_id,source_kind,raw,recorded_at) VALUES(?,?,?,?,?)')
        for _i,row in ipairs(rows) do
            local id=assert(M.id(row.kind,row.raw));local old=lookup:reset():bind(key,id):step()
            if old then
                if old[1]~=row.kind or old[2]~=row.raw then error('changed') end
            else
                n=n+1;bytes=bytes+#row.raw;if n>M.MAX_RECORDS or bytes>M.MAX_TOTAL then error('capacity') end
                local now=os.time();if type(now)~='number' or now<0 or now>4102444800 or now%1~=0 then now=0 end
                statement:reset():bind(key,id,row.kind,row.raw,now):step()
                local saved=lookup:reset():bind(key,id):step()
                if not saved or saved[1]~=row.kind or saved[2]~=row.raw then error('readback') end
            end
        end
        close(statement);statement=nil;close(lookup);lookup=nil;close(count);count=nil
        db:exec('COMMIT');transaction=false
    end)
    close(statement);close(lookup);close(count)
    if transaction then pcall(db.exec,db,'ROLLBACK') end;close(db)
    return ok
end
function M:list(key)
    if not hex(key,64) then return nil end
    local db=self:open();if not db then return nil end
    local statement;local rows,total={},0
    local ok=pcall(function()
        statement=db:prepare('SELECT record_id,source_kind,raw,recorded_at FROM snapshots WHERE article_key=? ORDER BY recorded_at DESC,record_id LIMIT 129')
        statement:reset():bind(key)
        while true do
            local row=statement:step();if not row then break end
            total=total+#row[3]
            if #rows>=M.MAX_RECORDS or total>M.MAX_TOTAL or M.id(row[2],row[3])~=row[1] then error('invalid') end
            local value=Data.summary(row[3]);value.id=row[1];value.kind=row[2];value.saved_at=tonumber(row[4])
            if not value.saved_at or value.saved_at<0 or value.saved_at>4102444800 then error('invalid') end
            rows[#rows+1]=value
        end
    end)
    close(statement);close(db);return ok and rows or nil
end
function M:get(key,id)
    if not hex(key,64) or not hex(id,64) then return nil end
    local db=self:open();if not db then return nil end
    local statement,raw
    local ok=pcall(function()
        statement=db:prepare('SELECT source_kind,raw FROM snapshots WHERE article_key=? AND record_id=?')
        local row=statement:reset():bind(key,id):step()
        if row and M.id(row[1],row[2])==id then raw=row[2] end
    end)
    close(statement);close(db);return ok and raw or nil
end
return M
