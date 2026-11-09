-- Bounded, primary-only JSON renewal intent/receipt. No backup resurrection.
local Auth=require('weread.lib.web_authorization')
local Output=require('weread.lib.notes_export_file')
local LuaSettings=require('luasettings')
local Cookie=require('weread.lib.cookie')
local Store={};Store.__index=Store
local function same_scope(a,b) return a and b and a.vid==b.vid and a.epoch==b.epoch end
local function hash(value) return type(value)=='string' and #value==64 and value:match('^[a-f0-9]+$') end
local function sync(path)
    local util=require('ffi/util');local file=io.open(path,'rb');if not file then return false end
    local ok,value=pcall(util.fsyncOpenedFile,file,true);file:close()
    return ok and value==true and util.fsyncDirectory(path)==true
end
function Store:new(settings,codec,dependencies)
    dependencies=dependencies or {}
    return setmetatable({settings=settings,codec=codec,path=settings.data_dir..'/web-renewal.json',
        sync=dependencies.sync or sync,create=dependencies.create or Output.create},self)
end
function Store:read()
    local lfs=require('libs/libkoreader-lfs')
    local mode=lfs.symlinkattributes(self.path,'mode')
    if not mode then return {revision=0,phase='idle'} end
    if mode~='file' then return nil,'unavailable' end
    local file=io.open(self.path,'rb');if not file then return nil,'unavailable' end
    local raw=file:read(65537);file:close()
    if not raw or #raw>65536 then return nil,'unavailable' end
    local ok,data=pcall(self.codec.json_decode,self.codec,raw)
    if not ok or type(data)~='table' or type(data.revision)~='number' or data.revision<1 or data.revision%1~=0
        or data.revision>9007199254740990 or not ({pending=true,candidate=true,verified=true,done=true})[data.phase]
        or type(data.scope)~='table' or type(data.scope.vid)~='string' or not data.scope.vid:match('^[1-9]%d*$')
        or #data.scope.vid>32 or type(data.scope.epoch)~='number' or data.scope.epoch<0 or data.scope.epoch%1~=0
        or data.scope.epoch>9007199254740990 or not hash(data.input_revision) then return nil,'unavailable' end
    if data.phase=='candidate' or data.phase=='verified' then
        local valid,candidate=pcall(Auth.snapshot,data.candidate,data.scope)
        if not valid or not hash(data.target_revision) or candidate.revision~=data.target_revision then return nil,'unavailable' end
        data.candidate=candidate
    elseif data.candidate~=nil then return nil,'unavailable' end
    return data
end
function Store:_write(input,previous,phase,candidate)
    if not self.settings:auth_scope_matches(input.scope) then return nil,'session_changed' end
    local current=self:read()
    if not current then return nil,'unavailable' end
    if current.revision~=previous.revision then
        if current.revision==previous.revision+1 and current.phase==phase and same_scope(current.scope,input.scope)
            and current.input_revision==input.revision and current.target_revision==(candidate and candidate.revision or nil) then
            if self.sync(self.path)==true then return current end
            return nil,'save_failed'
        end
        return nil,'replaced'
    end
    local record={revision=previous.revision+1,scope=input.scope,input_revision=input.revision,phase=phase,
        candidate=candidate,target_revision=candidate and candidate.revision or nil}
    local output
    local ok,result=pcall(function()
        local raw=self.codec:json_encode(record);if type(raw)~='string' or #raw>65536 then return false end
        output=self.create(self.settings.data_dir,'web-renewal','json');if not output then return false end
        if not output:write(raw) or not output:sync() or not output:accept(#raw) then return false end
        local latest=self:read()
        if not latest or latest.revision~=previous.revision or not self.settings:auth_scope_matches(input.scope) then return false end
        if not os.rename(output.path,self.path) then return false end
        return self.sync(self.path)==true
    end)
    if output then output:abort() end
    local actual=self:read()
    if not ok or not result or not actual or actual.revision~=record.revision or actual.phase~=phase
        or actual.input_revision~=input.revision or actual.target_revision~=record.target_revision
        or not same_scope(actual.scope,input.scope) or not self.settings:auth_scope_matches(input.scope) then return nil,'save_failed' end
    return actual
end
function Store:begin(input)
    local record,err=self:read();if not record then return nil,err end
    if same_scope(record.scope,input.scope) then
        if record.phase=='pending' then return nil,'renewal_unconfirmed' end
        if record.phase=='candidate' or record.phase=='verified' then
            if input.revision~=record.input_revision and input.revision~=record.target_revision then return nil,'session_changed' end
            return record,'resume'
        end
    end
    if not Auth.current(self.settings,input) then return nil,'session_changed' end
    return self:_write(input,record,'pending')
end
function Store:receipt(input,record,candidate,verified)
    local ok,value=pcall(Auth.snapshot,candidate,input.scope);if not ok then return nil,'invalid' end
    return self:_write(input,record,verified and 'verified' or 'candidate',value)
end
function Store:release(input,record)
    if not Auth.current(self.settings,input) then return nil,'session_changed' end
    return self:_write(input,record,'done')
end
function Store:align(record)
    local memory=Auth.memory(self.settings);local disk,data=Auth.primary(self.settings)
    if record.phase~='verified' or not same_scope(record.scope,memory.scope) or not same_scope(record.scope,disk.scope)
        or memory.revision~=record.input_revision and memory.revision~=record.target_revision
        or disk.revision~=record.input_revision and disk.revision~=record.target_revision then return false end
    if disk.revision==record.target_revision then self.settings.store.data=data end
    return true
end
function Store:apply(input,record)
    if record.phase~='verified' or not same_scope(record.scope,input.scope) then return false,'invalid' end
    local ok,result=pcall(function()
        local memory=Auth.memory(self.settings);local disk,data=Auth.primary(self.settings)
        local function allowed(value)
            return same_scope(value.scope,input.scope) and (value.revision==record.input_revision or value.revision==record.target_revision)
        end
        if not allowed(memory) or not allowed(disk) then return false end
        if disk.revision~=record.target_revision then
            -- Merge into the fresh primary settings, retaining preferences, API
            -- key and the latest book indexes. Never flush a worker's snapshot.
            data.cookies=Cookie.merge(data.cookies,{})
            for _i,key in ipairs(Auth.keys) do data.cookies[key]=record.candidate.cookies[key] end
            data.wr_ticket=record.candidate.wr_ticket;data.wr_wrpa=record.candidate.wr_wrpa
            local output=LuaSettings:open(self.settings.settings_file);output.data=data;output:flush()
        end
        if self.sync(self.settings.settings_file)~=true then return false end
        local actual,primary=Auth.primary(self.settings)
        if actual.revision~=record.target_revision or not self.settings:auth_scope_matches(input.scope) then return false end
        self.settings.store.data=primary
        return true
    end)
    if not ok or not result then return false,'save_failed' end
    local current=Auth.capture(self.settings)
    local done,err=self:_write(current,record,'done')
    if not done then return false,err end
    return true,current
end
return Store
