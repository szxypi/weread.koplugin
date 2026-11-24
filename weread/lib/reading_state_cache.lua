-- An account-local, timestamped observation; never a source of cloud writes.
local State=require('weread.lib.reading_state')
local Crypto=require('weread.lib.crypto')
local M={};M.__index=M
local function integer(value)
    return type(value)=='number' and value>=1 and value<=4102444800 and value%1==0
end
local function token(value)
    return type(value)=='string' and #value==32 and value:match('^[a-f0-9]+$')~=nil
end
local function nonce()
    local file=io.open('/dev/urandom','rb');if not file then return end
    local raw=file:read(16);file:close();if not raw or #raw~=16 then return end
    return (raw:gsub('.',function(char) return string.format('%02x',char:byte()) end))
end
local function key(id)
    if not State.id(id) then return nil end
    return 'started_reading_cache_v1:'..Crypto.sha256_hex(id)
end
local function valid(value,id,account)
    if type(value)~='table' or value.schema~=1 or value.account~=account or value.book_id~=id
        or type(value.started)~='boolean' and value.started~='missing'
        or not integer(value.checked_at) or not token(value.revision) then return false end
    local fields={schema=true,account=true,book_id=true,started=true,checked_at=true,revision=true}
    for name in pairs(value) do if not fields[name] then return false end end
    return true
end
function M:new(library,account,options)
    options=options or {}
    return setmetatable({library=library,account=account,now=options.now or os.time,nonce=options.nonce or nonce},self)
end
function M:current()
    return type(self.account)=='string' and self.account~='' and self.library
        and type(self.library.accountKey)=='function' and self.library:accountKey()==self.account
end
function M:read(id)
    local name=key(id)
    if not name or not self:current() or type(self.library.getProfileState)~='function' then return nil end
    local ok,value=pcall(self.library.getProfileState,self.library,name)
    if not ok or not self:current() or not valid(value,id,self.account) then return nil end
    return value
end
-- The caller passes the exact observation seen before starting its request.
-- A concurrent result, account change, or corrupt existing row cannot be lost.
function M:write(id,started,expected)
    local name=key(id)
    if not name or not self:current() or type(started)~='boolean' and started~='missing'
        or type(self.library.compareProfileState)~='function'
        or expected~=nil and not valid(expected,id,self.account) then return false end
    local stamp,revision=self.now(),self.nonce()
    if not integer(stamp) or not token(revision) or expected and expected.revision==revision then return false end
    local value={schema=1,account=self.account,book_id=id,started=started,checked_at=stamp,revision=revision}
    local ok,saved=pcall(self.library.compareProfileState,self.library,name,expected,value)
    return ok and saved==true and self:current() and true or false
end
return M
