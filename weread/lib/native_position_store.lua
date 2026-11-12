-- One bounded account-local SQLite intent. FULL commits precede dispatch.
-- Claimed writes are never replayed; explicit ACK is saved before readback.
local C=require('weread.lib.native_position_contract')
local P=require('weread.lib.native_position_protocol')
local M={};M.__index=M
local active={prepared=true,pending=true,acknowledged=true,verified=true}
local function nonce()
    local file=io.open('/dev/urandom','rb');if not file then return end
    local raw=file:read(16);file:close();if not raw or #raw~=16 then return end
    return (raw:gsub('.',function(char) return string.format('%02x',char:byte()) end))
end
local function token(v) return type(v)=='string' and #v==32 and v:match('^[a-f0-9]+$') end
local function statement(db,sql,...)
    local query=db:prepare(sql);local args={...};local ok,row=pcall(function() return query:bind(unpack(args)):step() end)
    query:close();assert(ok,'native_position_store/statement');return row
end
function M:new(library,codec,options) return setmetatable({library=library,codec=codec,nonce=options and options.nonce or nonce},self) end
local function run(self,callback,write)
    local account=self.library:accountKey();if not account then return nil,'account' end
    local opened,db=pcall(self.library.open,self.library);if not opened or not db then return nil,'storage' end
    local transaction=false
    local ok,result=pcall(function()
        db:exec('PRAGMA synchronous=FULL')
        db:exec([[CREATE TABLE IF NOT EXISTS native_position_write_state (
            id INTEGER PRIMARY KEY CHECK(id=1),revision INTEGER NOT NULL,payload TEXT NOT NULL
            CHECK(length(CAST(payload AS BLOB))<=16384))]])
        if write then db:exec('BEGIN IMMEDIATE');transaction=true end
        assert(account==self.library:accountKey(),'native_position_store/account')
        local value=callback(db,account)
        assert(account==self.library:accountKey(),'native_position_store/account')
        if transaction then db:exec('COMMIT');transaction=false end
        return value
    end)
    if transaction then pcall(db.exec,db,'ROLLBACK') end;pcall(db.close,db)
    if not ok then return nil,'storage' end;return result
end
local function read(self,db,account)
    local row=statement(db,'SELECT revision,payload FROM native_position_write_state WHERE id=1')
    if not row then return {schema=1,revision=0,phase='idle',account=account} end
    local revision=tonumber(row[1]);assert(P.integer(revision,1,9007199254740990) and type(row[2])=='string' and #row[2]<=16384,'native_position_store/record')
    local value=self.codec:json_decode(row[2]);assert(type(value)=='table' and value.schema==1 and value.account==account
        and value.revision==revision and (value.phase=='idle' or active[value.phase]),'native_position_store/record')
    local allowed={schema=true,revision=true,phase=true,account=true}
    if value.phase~='idle' then
        allowed.id,allowed.epoch,allowed.metadata=true,true,true
        assert(token(value.id) and P.integer(value.epoch,0,9007199254740990) and C.valid(value.metadata),'native_position_store/record')
    end
    for key in pairs(value) do assert(allowed[key],'native_position_store/record') end;return value
end
local function save(self,db,previous,value)
    assert(previous.revision<9007199254740990,'native_position_store/overflow')
    value.schema,value.account,value.revision=1,previous.account,previous.revision+1
    local raw=self.codec:json_encode(value);assert(type(raw)=='string' and #raw<=16384,'native_position_store/record')
    statement(db,'INSERT INTO native_position_write_state(id,revision,payload) VALUES(1,?,?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,payload=excluded.payload',value.revision,raw)
    local actual=read(self,db,previous.account)
    assert(actual.revision==value.revision and actual.phase==value.phase and actual.id==value.id
        and (value.phase=='idle' or C.same(actual.metadata,value.metadata)),'native_position_store/readback')
    return actual
end
local function matches(value,record)
    return type(record)=='table' and active[value.phase] and value.account==record.account and value.id==record.id
        and value.epoch==record.epoch and C.same(value.metadata,record.metadata)
end
function M:read() return run(self,function(db,account) return read(self,db,account) end) end
function M:owns(record,phase)
    local value=self:read();return value~=nil and matches(value,record) and (phase==nil or value.phase==phase)
end
function M:begin(metadata,scope,revision)
    if not C.valid(metadata) or not scope or type(scope.vid)~='string' or not P.id(scope.vid)
        or not P.integer(scope.epoch,0,9007199254740990) or not P.integer(revision,0,9007199254740990) then return nil end
    local id=self.nonce();if not token(id) then return nil end
    return run(self,function(db,account)
        local previous=read(self,db,account);assert(account==C.account_key(scope.vid)
            and previous.phase=='idle' and previous.revision==revision,'native_position_store/replaced')
        local frozen=self.codec:json_decode(self.codec:json_encode(metadata))
        return save(self,db,previous,{phase='prepared',id=id,epoch=scope.epoch,metadata=frozen})
    end,true)
end
function M:advance(record,before,after)
    if not ((before=='prepared' and after=='pending') or (before=='pending' and after=='acknowledged') or (before=='acknowledged' and after=='verified')) then return nil end
    return run(self,function(db,account)
        local previous=read(self,db,account)
        assert(matches(previous,record) and previous.phase==before and previous.revision==record.revision,'native_position_store/replaced')
        previous.phase=after;return save(self,db,previous,previous)
    end,true)
end
function M:finish(record,phase)
    if phase~='prepared' and phase~='verified' then return false end
    return run(self,function(db,account)
        local previous=read(self,db,account)
        assert(matches(previous,record) and previous.phase==phase and previous.revision==record.revision,'native_position_store/replaced')
        return save(self,db,previous,{phase='idle'})
    end,true)~=nil
end
return M
