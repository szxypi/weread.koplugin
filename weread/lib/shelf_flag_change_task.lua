-- One private/public request, verified first by Python and real readback.
-- Restoration is a separate operation. Never renew or resend a claimed write.
local Contract=require('weread.lib.shelf_flag_change_contract')
local Auth=require('weread.lib.native_authorization')
local Access=require('weread.lib.native_read_access')
local Source=require('weread.lib.shelf_source')
local BASE='https://i.weread.qq.com'
local M={}
local function current(settings,selected) return selected and not selected.renewal_pending and Access.matches(settings,selected) end
local function observe(client,settings,selected,id,inspect)
    assert(Contract.id(id) and current(settings,selected),'shelf_flag_change/login')
    local auth=Auth:new(client,{expected_vid=selected.scope.vid,is_current=function() return current(settings,selected) end})
    local ok,shelf,progress=pcall(function()
        local raw=auth:read_shelf(selected.credentials)
        local read,value=pcall(auth._request,auth,'shelf_flag_progress',BASE..'/book/getProgress?bookId='..id,nil,selected.credentials)
        if not read and not inspect then error(value,0) end
        return raw,read and value or nil
    end)
    auth:cancel();if not ok then error(shelf,0) end
    return {raw=shelf,progress=progress,snapshot=Source.normalize(shelf)}
end
function M.observe(client,settings,selected,id) return observe(client,settings,selected,id,false) end
function M.inspect(client,settings,selected,id) return observe(client,settings,selected,id,true) end
function M.preview(client,settings,selected,id,desired)
    local observed=M.observe(client,settings,selected,id)
    if desired==nil then
        local row=Contract.flags(observed.raw)[id]
        assert(row and type(row.private.value)=='boolean','shelf_flag_change/unknown');desired=not row.private.value
    end
    local plan=Contract.make(observed.raw,observed.progress,id,desired);plan.observed=observed
    return plan
end
function M.expired(reason) return reason=='native_auth/shelf/http_401' or reason=='native_auth/shelf_flag_progress/http_401' end
function M.run(client,settings,selected,input,record,store,options)
    options=options or {};local out={kind='unconfirmed',attempted=false,book_id=input.book_id}
    local function owns() return current(settings,selected) and store:owns(record) end
    if not owns() then out.kind='login';return out end
    local prepared,plan=pcall(M.preview,client,settings,selected,input.book_id,input.desired)
    if not prepared then out.kind=M.expired(plan) and 'login' or 'unavailable';return out end
    if not Contract.same(plan.metadata,record.metadata) then out.kind='changed';out.observed=plan.observed;return out end
    if plan.metadata.before_hash==plan.metadata.after_hash then out.kind='noop';out.observed=plan.observed;return out end
    local auth=Auth:new(client,{expected_vid=selected.scope.vid,is_current=owns})
    pcall(auth._request,auth,'shelf_flag_write',BASE..'/book/secret',plan.body,selected.credentials,nil,function()
        assert(owns() and store:claim(record),'shelf_flag_change/replaced');out.attempted=true
    end)
    auth:cancel();if not out.attempted then out.kind='unavailable';return out end
    local sleep=options.sleep or function(seconds) require('socket').sleep(seconds) end
    for attempt=1,3 do
        if not owns() then return out end
        if attempt>1 then sleep(.5*(attempt-1)) end
        local read,observed=pcall(M.observe,client,settings,selected,input.book_id)
        if read and owns() then
            out.observed=observed
            local checked,match=pcall(Contract.check,observed.raw,observed.progress,record.metadata)
            if checked and match then out.kind='confirmed';return out end
            local valid,unchanged=pcall(function()
                return Contract.state_hash(observed.raw)==record.metadata.before_hash
                    and Contract.position_hash(Contract.point(observed.progress,input.book_id))==record.metadata.position_hash
            end)
            if not valid or not unchanged then return out end
        end
    end
    return out
end
return M
