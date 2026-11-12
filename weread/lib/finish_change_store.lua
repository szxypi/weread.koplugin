-- One account-local completion intent. No shelf list, position or credentials.
-- Atomic FULL claims precede possible dispatch; pending never replays.
local Contract=require('weread.lib.finish_change_contract')
local M={};M.__index=M
local function integer(value) return type(value)=='number' and value>=0 and value%1==0 and value<=9007199254740990 end
local function token(value) return type(value)=='string' and #value==32 and value:match('^[a-f0-9]+$') end
local function nonce()
    local file=io.open('/dev/urandom','rb');if not file then return end
    local raw=file:read(16);file:close();if not raw or #raw~=16 then return end
    return (raw:gsub('.',function(char) return string.format('%02x',char:byte()) end))
end
local function statement(db,sql,...)
    local query=db:prepare(sql);local args={...};local ok,row=pcall(function() return query:bind(unpack(args)):step() end)
    query:close();assert(ok,'finish_store/statement');return row
end
function M:new(library,codec,options) return setmetatable({library=library,codec=codec,nonce=options and options.nonce or nonce},self) end
local function run(self,task,write)
    local account=self.library:accountKey();if not account then return nil,'account' end
    local opened,db=pcall(self.library.open,self.library);if not opened or not db then return nil,'storage' end
    local transaction=false
    local ok,value=pcall(function()
        db:exec('PRAGMA synchronous=FULL')
        db:exec([[CREATE TABLE IF NOT EXISTS finish_write_state (
            id INTEGER PRIMARY KEY CHECK(id=1),revision INTEGER NOT NULL,payload TEXT NOT NULL
            CHECK(length(CAST(payload AS BLOB))<=2048))]])
        if write then db:exec('BEGIN IMMEDIATE');transaction=true end
        assert(self.library:accountKey()==account,'finish_store/account')
        local result=task(db,account)
        assert(self.library:accountKey()==account,'finish_store/account')
        if transaction then db:exec('COMMIT');transaction=false end
        return result
    end)
    if transaction then pcall(db.exec,db,'ROLLBACK') end;pcall(db.close,db)
    if not ok then return nil,'storage' end;return value
end
local function read(self,db,account)
    local row=statement(db,'SELECT revision,payload FROM finish_write_state WHERE id=1')
    if not row then return {schema=1,revision=0,phase='idle',account=account} end
    local revision=tonumber(row[1]);assert(integer(revision) and revision>0 and type(row[2])=='string' and #row[2]<=2048,'finish_store/invalid')
    local value=self.codec:json_decode(row[2]);assert(type(value)=='table' and value.schema==1 and value.account==account
        and value.revision==revision and (value.phase=='idle' or value.phase=='prepared' or value.phase=='pending'),'finish_store/invalid')
    local allowed={schema=true,revision=true,phase=true,account=true}
    if value.phase~='idle' then
        allowed.id,allowed.epoch,allowed.metadata=true,true,true
        assert(token(value.id) and integer(value.epoch) and Contract.valid_metadata(value.metadata),'finish_store/invalid')
    end
    for key in pairs(value) do assert(allowed[key],'finish_store/invalid') end
    return value
end
local function save(self,db,previous,value)
    assert(previous.revision<9007199254740990,'finish_store/overflow')
    value.schema,value.account,value.revision=1,previous.account,previous.revision+1
    local raw=self.codec:json_encode(value);assert(type(raw)=='string' and #raw<=2048,'finish_store/invalid')
    statement(db,'INSERT INTO finish_write_state(id,revision,payload) VALUES(1,?,?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,payload=excluded.payload',value.revision,raw)
    local actual=read(self,db,previous.account);assert(actual.revision==value.revision and actual.phase==value.phase and actual.id==value.id,'finish_store/readback')
    return actual
end
local function matches(value,record)
    return type(record)=='table' and value.phase~='idle' and value.account==record.account and value.id==record.id
        and value.epoch==record.epoch and Contract.same(value.metadata,record.metadata)
end
function M:read() return run(self,function(db,account) return read(self,db,account) end) end
function M:owns(record,phase)
    local value=self:read();return value~=nil and matches(value,record) and (phase==nil or value.phase==phase)
end
function M:begin(metadata,scope,revision)
    if not Contract.valid_metadata(metadata) or not scope or not integer(scope.epoch) or not integer(revision) then return nil end
    local id=self.nonce();if not token(id) then return nil end
    return run(self,function(db,account)
        local previous=read(self,db,account);assert(previous.phase=='idle' and previous.revision==revision,'finish_store/replaced')
        local copy={};for k,v in pairs(metadata) do copy[k]=v end
        return save(self,db,previous,{phase='prepared',id=id,epoch=scope.epoch,metadata=copy})
    end,true)
end
function M:claim(record)
    return run(self,function(db,account)
        local previous=read(self,db,account);assert(matches(previous,record) and previous.phase=='prepared','finish_store/replaced')
        previous.phase='pending';return save(self,db,previous,previous)
    end,true)
end
function M:finish(record,phase)
    if phase~='prepared' and phase~='pending' then return false end
    return run(self,function(db,account)
        local previous=read(self,db,account);assert(matches(previous,record) and previous.phase==phase,'finish_store/replaced')
        return save(self,db,previous,{phase='idle'})
    end,true)~=nil
end
return M
