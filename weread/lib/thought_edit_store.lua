-- Account-local bounded drafts and one crash-safe write intent. SQLite FULL
-- commits precede dispatch; claim is atomic across processes. No credentials,
-- original snapshots, quotes or request bodies enter the intent record.
local Contract=require('weread.lib.thought_edit_contract')
local Crypto=require('weread.lib.crypto')
local M={MAX_DRAFTS=16,MAX_DRAFT_BYTES=2*1024*1024,MAX_RECORD_BYTES=8192};M.__index=M
local function nonce()
    local file=io.open('/dev/urandom','rb');if not file then return nil end
    local raw=file:read(16);file:close();if not raw or #raw~=16 then return nil end
    return (raw:gsub('.',function(c) return string.format('%02x',c:byte()) end))
end
local function token(v) return type(v)=='string' and #v==32 and v:match('^[a-f0-9]+$')~=nil end
local function integer(v) return type(v)=='number' and v>=0 and v%1==0 and v<2^53-1 end
local function same_metadata(a,b)
    for k,v in pairs(a) do if b[k]~=v then return false end end
    for k,v in pairs(b) do if a[k]~=v then return false end end
    return true
end
local function statement(db,sql,...)
    local stmt=db:prepare(sql);local args={...};local ok,row=pcall(function() return stmt:bind(unpack(args)):step() end)
    stmt:close();if not ok then error('thought_store/statement',0) end;return row
end
function M:new(library,codec,options)
    options=options or {};return setmetatable({library=library,codec=codec,nonce=options.nonce or nonce},self)
end
function M.draft_key(book,operation,reference) return Crypto.sha256_hex(book..'\0'..operation..'\0'..reference) end
local function run(self,task,write)
    local account=self.library and self.library:accountKey();if not account then return nil,'account' end
    local opened,db=pcall(self.library.open,self.library);if not opened or not db then return nil,'storage' end
    local transaction=false
    local ok,value=pcall(function()
        db:exec('PRAGMA synchronous=FULL')
        db:exec([[CREATE TABLE IF NOT EXISTS thought_write_state (
            id INTEGER PRIMARY KEY CHECK(id=1),revision INTEGER NOT NULL,payload TEXT NOT NULL
            CHECK(length(CAST(payload AS BLOB))<=8192))]])
        db:exec([[CREATE TABLE IF NOT EXISTS thought_drafts (
            draft_key TEXT PRIMARY KEY,book_id TEXT NOT NULL,operation TEXT NOT NULL,reference_id TEXT NOT NULL,
            base_hash TEXT NOT NULL,content TEXT NOT NULL,token TEXT NOT NULL,serial INTEGER NOT NULL,
            CHECK(length(CAST(content AS BLOB))<=131072))]])
        if write then db:exec('BEGIN IMMEDIATE');transaction=true end
        if self.library:accountKey()~=account then error('thought_store/account',0) end
        local result=task(db,account)
        if transaction then db:exec('COMMIT');transaction=false end
        return result
    end)
    if transaction then pcall(db.exec,db,'ROLLBACK') end;pcall(db.close,db)
    if not ok then return nil,'storage' end
    return value
end
local function decode(self,row,account)
    if not row then return {schema=1,revision=0,phase='idle',account=account} end
    row[1]=tonumber(row[1]) -- KOReader SQLite returns integer columns as int64 cdata.
    if not integer(row[1]) or row[1]==0 or type(row[2])~='string' or #row[2]>M.MAX_RECORD_BYTES then error('thought_store/record',0) end
    local value=self.codec:json_decode(row[2])
    if type(value)~='table' or value.schema~=1 or value.account~=account or value.revision~=row[1]
        or value.phase~='idle' and value.phase~='prepared' and value.phase~='pending' then error('thought_store/record',0) end
    local allowed={schema=true,revision=true,phase=true,account=true}
    if value.phase~='idle' then
        allowed.id,allowed.epoch,allowed.metadata,allowed.draft_key,allowed.draft_token=true,true,true,true,true
        if not token(value.id) or not integer(value.epoch) or not Contract.validate_metadata(value.metadata)
            or not (value.draft_key=='' and value.draft_token=='' or Contract.hash(value.draft_key) and token(value.draft_token)) then error('thought_store/record',0) end
    end
    for key in pairs(value) do if not allowed[key] then error('thought_store/record',0) end end
    return value
end
local function read(self,db,account)
    return decode(self,statement(db,'SELECT revision,payload FROM thought_write_state WHERE id=1'),account)
end
local function save(self,db,previous,value)
    if previous.revision>=2^53-2 then error('thought_store/revision',0) end
    value.schema,value.account,value.revision=1,previous.account,previous.revision+1
    local raw=self.codec:json_encode(value)
    if type(raw)~='string' or #raw>M.MAX_RECORD_BYTES then error('thought_store/record',0) end
    statement(db,'INSERT INTO thought_write_state(id,revision,payload) VALUES(1,?,?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,payload=excluded.payload',value.revision,raw)
    local actual=read(self,db,previous.account)
    if actual.revision~=value.revision or actual.id~=value.id or actual.phase~=value.phase then error('thought_store/readback',0) end
    return actual
end
function M:read() return run(self,function(db,account) return read(self,db,account) end) end
local function matches(actual,record)
    return type(record)=='table' and actual.phase~='idle' and actual.account==record.account and actual.id==record.id
        and actual.epoch==record.epoch and same_metadata(actual.metadata,record.metadata)
        and actual.draft_key==record.draft_key and actual.draft_token==record.draft_token
end
function M:owns(record,phase)
    local value=self:read();return value~=nil and matches(value,record) and (phase==nil or value.phase==phase)
end
function M:begin(metadata,scope,revision,draft)
    if not Contract.validate_metadata(metadata) or not scope or not integer(scope.epoch) or not integer(revision) then return nil,'invalid' end
    local id=self.nonce();if not token(id) then return nil,'storage' end
    local value,reason=run(self,function(db,account)
        local previous=read(self,db,account)
        if previous.phase~='idle' or previous.revision~=revision then error('thought_store/replaced',0) end
        local copy={};for k,v in pairs(metadata) do copy[k]=v end
        local key,version='',''
        if draft then
            key,version=draft.draft_key,draft.token
            if not Contract.hash(key) or not token(version) then error('thought_store/draft',0) end
        end
        return save(self,db,previous,{phase='prepared',id=id,epoch=scope.epoch,metadata=copy,draft_key=key,draft_token=version})
    end,true)
    if not value then return nil,reason end
    local actual=self:read()
    if actual and actual.revision==value.revision and self:owns(value,'prepared') then return actual end
    return nil,'storage'
end
function M:claim(record)
    local value=run(self,function(db,account)
        local previous=read(self,db,account)
        if previous.phase~='prepared' or previous.revision~=record.revision or not matches(previous,record) then error('thought_store/replaced',0) end
        local changed={};for k,v in pairs(previous) do changed[k]=v end;changed.phase='pending'
        return save(self,db,previous,changed)
    end,true)
    return value and self:owns(value,'pending') and value or nil
end
function M:finish(record,phase,keep_draft)
    if phase~='prepared' and phase~='pending' then return false end
    return run(self,function(db,account)
        local previous=read(self,db,account)
        if previous.phase~=phase or not matches(previous,record) then error('thought_store/replaced',0) end
        save(self,db,previous,{phase='idle'})
        if phase=='pending' and not keep_draft and previous.draft_key~='' then
            statement(db,'DELETE FROM thought_drafts WHERE draft_key=? AND token=?',previous.draft_key,previous.draft_token)
        end
        return true
    end,true)==true
end
function M:save_draft(book,operation,reference,base_hash,content)
    if not require('weread.lib.my_cloud_marks').id(book) or operation~='create' and operation~='edit'
        or not Contract.key(reference) or not Contract.hash(base_hash) or not Contract.valid_content(content) then return nil,'invalid' end
    local version=self.nonce();if not token(version) then return nil,'storage' end
    local key=M.draft_key(book,operation,reference)
    return run(self,function(db)
        local count,bytes=db:rowexec('SELECT COUNT(*),COALESCE(SUM(length(CAST(content AS BLOB))),0) FROM thought_drafts')
        count,bytes=tonumber(count),tonumber(bytes)
        if count>M.MAX_DRAFTS or bytes>M.MAX_DRAFT_BYTES then error('thought_store/quota',0) end
        local previous=statement(db,'SELECT length(CAST(content AS BLOB)) FROM thought_drafts WHERE draft_key=?',key)
        if count+(previous and 0 or 1)>M.MAX_DRAFTS or bytes-(previous and previous[1] or 0)+#content>M.MAX_DRAFT_BYTES then error('thought_store/quota',0) end
        local serial=tonumber(db:rowexec('SELECT COALESCE(MAX(serial),0)+1 FROM thought_drafts'));if not integer(serial) then error('thought_store/serial',0) end
        statement(db,[[INSERT INTO thought_drafts(draft_key,book_id,operation,reference_id,base_hash,content,token,serial) VALUES(?,?,?,?,?,?,?,?)
            ON CONFLICT(draft_key) DO UPDATE SET base_hash=excluded.base_hash,content=excluded.content,token=excluded.token,serial=excluded.serial]],key,book,operation,reference,base_hash,content,version,serial)
        return {draft_key=key,book_id=book,operation=operation,reference_id=reference,base_hash=base_hash,content=content,token=version,serial=serial}
    end,true)
end
function M:drafts()
    return run(self,function(db)
        local stmt=db:prepare([[SELECT draft_key,book_id,operation,reference_id,base_hash,
            CASE WHEN length(CAST(content AS BLOB))<=131072 THEN content ELSE NULL END,token,serial FROM thought_drafts ORDER BY serial DESC]])
        local values={};local ok=pcall(function()
            local row=stmt:step()
            while row do
                row[8]=tonumber(row[8])
                if #values>=M.MAX_DRAFTS or not Contract.hash(row[1]) or not require('weread.lib.my_cloud_marks').id(row[2])
                    or row[3]~='create' and row[3]~='edit' or not Contract.key(row[4]) or not Contract.hash(row[5])
                    or row[1]~=M.draft_key(row[2],row[3],row[4]) or not Contract.valid_content(row[6])
                    or not token(row[7]) or not integer(row[8]) then error('thought_store/draft',0) end
                values[#values+1]={draft_key=row[1],book_id=row[2],operation=row[3],reference_id=row[4],base_hash=row[5],content=row[6],token=row[7],serial=row[8]}
                row=stmt:step()
            end
        end);stmt:close();if not ok then error('thought_store/draft',0) end
        return values
    end)
end
function M:draft(key)
    local values,why=self:drafts();if not values then return nil,why end
    for _i,v in ipairs(values) do if v.draft_key==key then return v end end
end
function M:delete_draft(draft)
    if type(draft)~='table' or not Contract.hash(draft.draft_key) or not token(draft.token) then return false end
    return run(self,function(db)
        local old=statement(db,'SELECT token FROM thought_drafts WHERE draft_key=?',draft.draft_key)
        if not old or old[1]~=draft.token then return false end
        statement(db,'DELETE FROM thought_drafts WHERE draft_key=? AND token=?',draft.draft_key,draft.token);return true
    end,true)==true
end
return M
