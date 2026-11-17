-- Durable account-scoped upload intent; never stores content or credentials.
local Crypto=require('weread.lib.crypto')
local Output=require('weread.lib.notes_export_file')
local MAX_BYTES=require('weread.lib.cos_sign').MAX_SINGLE_BYTES
local M={};M.__index=M
local function hash(value,length) return type(value)=='string' and #value==length and value:match('^[a-f0-9]+$') end
local function nonce()
    local file=io.open('/dev/urandom','rb');if not file then return nil end
    local bytes=file:read(16);file:close();if not bytes or #bytes~=16 then return nil end
    return (bytes:gsub('.',function(char) return string.format('%02x',char:byte()) end))
end
local function sync(path)
    local util=require('ffi/util');local file=io.open(path,'rb');if not file then return false end
    local ok,value=pcall(util.fsyncOpenedFile,file,true);file:close()
    return ok and value==true and util.fsyncDirectory(path)==true
end
function M:new(settings,codec,dependencies)
    dependencies=dependencies or {}
    return setmetatable({settings=settings,codec=codec,sync=dependencies.sync or sync,
        create=dependencies.create or Output.create,nonce=dependencies.nonce or nonce,
        lease=dependencies.lease or require('weread.lib.file_lease').open},self)
end
function M:account(scope) return Crypto.sha256_hex('weread-personal-upload:'..scope.vid):sub(1,20) end
function M:path(scope) return self.settings.data_dir..'/personal-upload-'..self:account(scope)..'.json' end
function M:read(scope)
    if not scope or not self.settings:auth_scope_matches(scope) then return nil,'session_changed' end
    local path=self:path(scope);local mode=require('libs/libkoreader-lfs').symlinkattributes(path,'mode')
    if not mode then return {schema=1,revision=0,phase='idle',account=self:account(scope)} end
    if mode~='file' then return nil,'storage' end
    local file=io.open(path,'rb');if not file then return nil,'storage' end
    local raw=file:read(2049);file:close();if not raw or #raw>2048 then return nil,'storage' end
    local ok,value=pcall(self.codec.json_decode,self.codec,raw)
    if not ok or type(value)~='table' or value.schema~=1 or value.account~=self:account(scope)
        or type(value.revision)~='number' or value.revision<1 or value.revision%1~=0 or value.revision>9007199254740990
        or value.phase~='idle' and value.phase~='pending' then return nil,'storage' end
    local allowed={schema=true,revision=true,phase=true,account=true}
    if value.phase=='pending' then
        allowed.id,allowed.path_hash,allowed.size,allowed.epoch=true,true,true,true
        if not hash(value.id,32) or not hash(value.path_hash,64) or type(value.size)~='number' or value.size%1~=0
            or value.size<1 or value.size>MAX_BYTES or type(value.epoch)~='number' or value.epoch<0
            or value.epoch%1~=0 or value.epoch>9007199254740990 then return nil,'storage' end
    end
    for key in pairs(value) do if not allowed[key] then return nil,'storage' end end
    return value
end
function M:_write(scope,previous,value)
    local lease=self.lease(self:path(scope)..'.lock',{create=true,empty=true})
    if not lease then return nil end
    local output
    local ok=pcall(function()
        assert(lease:owns())
        local actual=assert(self:read(scope));assert(actual.revision==previous.revision)
        value.schema,value.account,value.revision=1,self:account(scope),previous.revision+1
        local raw=self.codec:json_encode(value);assert(type(raw)=='string' and #raw<=2048)
        output=assert(self.create(self.settings.data_dir,'personal-upload','json'))
        assert(output:write(raw) and output:sync() and output:accept(#raw))
        assert(lease:owns() and assert(self:read(scope)).revision==previous.revision)
        assert(os.rename(output.path,self:path(scope)));assert(self.sync(self:path(scope))==true)
        local saved=assert(self:read(scope));assert(saved.revision==value.revision and saved.phase==value.phase and saved.id==value.id)
    end)
    if output then output:abort() end
    pcall(lease.release,lease)
    return ok and value or nil
end
function M:begin(scope,path,size)
    local previous=self:read(scope)
    if not previous or previous.phase=='pending' or type(path)~='string' or path=='' or #path>4096
        or type(size)~='number' or size%1~=0 or size<1 or size>MAX_BYTES then return nil end
    local id=self.nonce();if not hash(id,32) then return nil end
    return self:_write(scope,previous,{phase='pending',id=id,path_hash=Crypto.sha256_hex(path),size=size,epoch=scope.epoch})
end
function M:owns(scope,record)
    local actual=self:read(scope)
    return actual and record and actual.phase=='pending' and actual.revision==record.revision and actual.id==record.id
        and actual.path_hash==record.path_hash and actual.size==record.size and actual.epoch==record.epoch or false
end
function M:finish(scope,record)
    if not self:owns(scope,record) then return false end
    return self:_write(scope,record,{phase='idle'})~=nil
end
return M
