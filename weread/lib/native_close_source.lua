-- SourceUpload's primitive-only source view after ReaderUI closes. The archive
-- is independently reopened in a worker; no live document handle is consulted.
local Candidate=require('weread.lib.native_source_candidate')
local Same=require('weread.lib.source_upload_candidate').same
local Currentness=require('weread.lib.source_currentness')
local Task=require('weread.lib.source_position_worker')
local M={};M.__index=M
local fields={'book_id','chapter_uid','chapter_offset','file_id','book_version','raw_sha256','render_path','basis','upload_verified'}
local function copy(value)
    if type(value)~='table' then return value end
    local out={};for key,item in pairs(value) do out[key]=copy(item) end;return out
end
local function same(a,b)
    if type(a)~='table' or type(b)~='table' then return false end
    for _i,key in ipairs(fields) do if a[key]~=b[key] then return false end end;return true
end
function M:new(options)
    return setmetatable({client=assert(options.source.client),is_online=options.source.is_online,
        make_worker=options.source.make_worker,recovery=options.source.recovery,input=copy(options.input),
        expected=copy(options.expected),access=options.access,account_scope=options.account_scope,
        owned=assert(options.is_current),get_catalog=assert(options.get_catalog),now=options.now or os.time,
        deadline=assert(options.deadline),scope={},sequence=0},self)
end
function M:valid(transition)
    if not self.owned() or not self.is_online() or self.now()>self.deadline then return false end
    local settings=self.client.settings
    if self.account_scope and not settings:auth_scope_matches(self.account_scope) then return false end
    if not transition and not self.recovering and not Currentness.matches(settings,self.access) then return false end
    if self.started then local age=self.now()-self.started;if age<0 or age>30 then return false end end
    return not self.packet or Same(Candidate.project(self.packet,self.get_catalog(self.input.book_id),self.input.percent),self.candidate)
end
function M:_live() return self:valid() and self.scope or nil end
function M:_current(scope) return scope==self.scope and self:valid() end
function M:current() return self:valid() and copy(self.input.target) or nil end
function M:cancel_upload_preview()
    self.preview_token,self.packet,self.candidate,self.receipt=nil,nil,nil,nil
    if self.worker then self.worker:cancel() end
    if self.recovery_handle and self.recovery then self.recovery:cancel(self.recovery_handle) end
    self.recovery_handle,self.recovering=nil,nil
end
function M:is_current_native_preview(receipt,candidate)
    return receipt~=nil and receipt==self.receipt and Same(candidate,self.candidate) and self:valid() or false
end
function M:native_preview_deadline(receipt,candidate)
    if self:is_current_native_preview(receipt,candidate) then return math.min(self.started+30,self.deadline) end
end
function M:prepare_current_native_preview(callback)
    self:cancel_upload_preview();self.preview_token={};self.started=nil
    if not self:valid() then callback(nil,'source_position_changed');return false end
    self.worker=self.worker or self.make_worker()
    return self:_launch(callback,self.preview_token)
end
function M:_launch(callback,token)
    self.sequence=self.sequence+1;self.started=self.now()
    local input,expected,access,client=copy(self.input),copy(self.expected),self.access,self.client
    input.request_id=self.sequence
    local started=self.worker:start(function()
        local result=Task.prepare_native_excerpt(input)
        if type(result)=='table' and result.excerpt and same(result.position,input.target) then
            local proof=Currentness.run_txt(client,expected,access);result.check,result.error=proof.check,proof.error
        end
        return result
    end,function(result)
        if self.preview_token~=token or self.sequence~=input.request_id then return end
        if not self:valid() then callback(nil,'source_currentness_unavailable');return end
        local packet={position=copy(input.target),excerpt=type(result)=='table' and result.excerpt}
        local candidate=Candidate.project(packet,self.get_catalog(input.book_id),input.percent)
        if type(result)~='table' or result.request_id~=input.request_id or not same(result.position,input.target) or not candidate then
            callback(nil,'source_currentness_unavailable');return
        end
        if result.error=='source_web_expired' and not result.check then
            if self.recovery_attempted or not self.recovery then callback(nil,'source_authentication_unavailable');return end
            self.recovery_attempted,self.recovering=true,true
            local renewing,handle=self.recovery:start(input.book_id,access,function()
                return self.preview_token==token and self.sequence==input.request_id and self:valid(true)
            end,function(fresh,why)
                if self.preview_token~=token or self.sequence~=input.request_id then return end
                self.recovering,self.recovery_handle=nil,nil
                if fresh then self.access=fresh;self:_launch(callback,token)
                else callback(nil,why or 'source_authentication_unavailable') end
            end)
            if self.preview_token==token and self.sequence==input.request_id then
                if renewing then self.recovery_handle=handle
                else self.recovering=nil;callback(nil,'source_authentication_unavailable') end
            end
            return
        end
        if not Currentness.packet_txt(result.check,expected) then callback(nil,'source_currentness_unavailable');return end
        self.packet,self.candidate,self.receipt=packet,copy(candidate),{}
        callback(copy(candidate),nil,self.receipt)
    end)
    if not started and self.preview_token==token then callback(nil,'source_worker_unavailable') end
    return started==true
end
return M
