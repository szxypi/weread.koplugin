-- A local download range. A new process must verify the current catalog and
-- obtain a fresh confirmation before using it.
local Contract=require('weread.lib.native_position_contract')
local Protocol=require('weread.lib.native_position_protocol')
local M={}
M.__index=M

local function hex(value,length)
    return type(value)=='string' and #value==length and value:match('^[a-f0-9]+$')~=nil
end

local function key(id)
    if type(id)=='string' and Protocol.id(id)==id then return 'eink_batch_v1:'..id end
end

local fields={schema=true,account=true,book_id=true,version=true,digest=true,count=true,first=true,last=true,revision=true}
local function valid(record,id,account)
    if type(record)~='table' or record.schema~=1 or record.book_id~=id or record.account~=account
        or not hex(record.revision,32) or not hex(record.digest,64)
        or not Protocol.integer(record.version,0,2147483647) or not Protocol.integer(record.count,1,20000)
        or not Protocol.integer(record.first,1,record.count)
        or not Protocol.integer(record.last,record.first,record.count) then return false end
    for field in pairs(record) do if not fields[field] then return false end end
    return true
end

local function revision()
    local file=io.open('/dev/urandom','rb')
    if not file then return end
    local bytes=file:read(16)
    if not file:close() or not bytes or #bytes~=16 then return end
    return (bytes:gsub('.',function(char) return string.format('%02x',char:byte()) end))
end

function M:new(library,scope)
    return setmetatable({library=library,account=Contract.account_key(scope.vid)},self)
end

function M:_current(guard)
    local ok,result=pcall(function()
        return self.account and guard()==true and self.library:accountKey()==self.account
    end)
    return ok and result==true
end

function M:verified(record,id)
    return key(id)~=nil and self.account~=nil and valid(record,id,self.account)
end

function M:read(id,guard)
    local name=key(id)
    if not name or not self:_current(guard) or type(self.library.getProfileState)~='function' then return end
    local ok,value=pcall(self.library.getProfileState,self.library,name)
    if ok and self:verified(value,id) and self:_current(guard) then return value end
end

function M:range(record,catalog)
    if self:verified(record,catalog.book_id) and record.version==catalog.version and record.digest==catalog.reading_digest
        and record.count==#catalog.chapters then return {first=record.first,last=record.last} end
end

function M:begin(catalog,range,expected,guard)
    local id=catalog.book_id
    if not key(id) or not self:_current(guard) or type(self.library.compareProfileState)~='function'
        or range~=nil and type(range)~='table'
        or expected~=nil and not self:verified(expected,id) then return end
    local first,last=1,#catalog.chapters
    if range then first,last=range.first,range.last end
    local record={schema=1,account=self.account,book_id=id,version=catalog.version,digest=catalog.reading_digest,
        count=#catalog.chapters,first=first,last=last,revision=revision()}
    if not self:verified(record,id) or expected and expected.revision==record.revision then return end
    local ok,saved=pcall(self.library.compareProfileState,self.library,key(id),expected,record)
    if ok and saved==true and self:_current(guard) then return record end
end

function M:remove(id,record,guard)
    if not self:verified(record,id) or not self:_current(guard)
        or type(self.library.deleteProfileStateIf)~='function' then return false end
    local ok,removed=pcall(self.library.deleteProfileStateIf,self.library,key(id),record)
    return ok and removed==true and self:_current(guard)
end
return M
