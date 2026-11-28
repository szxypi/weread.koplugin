-- One state change and independent readback; a claimed request is never retried.
local Contract=require('weread.lib.reading_state_change_contract')
local State=require('weread.lib.reading_state')
local Auth=require('weread.lib.native_authorization')
local Access=require('weread.lib.native_read_access')
local Source=require('weread.lib.shelf_source')
local BASE='https://i.weread.qq.com'
local M={}
local function current(settings,selected)
    return selected and not selected.renewal_pending and Access.matches(settings,selected)
end
local function observe(client,settings,selected,id,inspect)
    assert(Contract.id(id) and current(settings,selected),'reading_state_change/login')
    local auth=Auth:new(client,{expected_vid=selected.scope.vid,is_current=function() return current(settings,selected) end})
    local ok,shelf,progress=pcall(function()
        local raw=auth:read_shelf(selected.credentials)
        local read,value=pcall(auth._request,auth,'reading_change_progress',BASE..'/book/getProgress?bookId='..id,nil,selected.credentials)
        if not read and not inspect then error(value,0) end
        return raw,read and value or nil
    end)
    auth:cancel();if not ok then error(shelf,0) end
    local snapshot=Source.normalize(shelf)
    assert(type(snapshot.archive)=='table','reading_state_change/incomplete_groups')
    return {raw=shelf,progress=progress,snapshot=snapshot}
end
function M.observe(client,settings,selected,id) return observe(client,settings,selected,id,false) end
function M.inspect(client,settings,selected,id) return observe(client,settings,selected,id,true) end
function M.preview(client,settings,selected,id,desired)
    local observed=M.observe(client,settings,selected,id)
    if desired==nil then
        local value,reason=State.project(observed.progress,id,selected.scope.vid)
        assert(not reason and type(value)=='boolean','reading_state_change/unknown');desired=not value
    end
    local plan=Contract.make(observed.raw,observed.progress,id,selected.scope.vid,desired)
    plan.observed=observed;return plan
end
function M.read_error(reason)
    if reason=='native_auth/shelf/http_401' or reason=='native_auth/reading_change_progress/http_401' then return 'login' end
    if type(reason)~='string' then return 'unavailable' end
    local stage,kind=reason:match('^native_auth/([%w_]+)/([%w_]+)$')
    if stage~='shelf' and stage~='reading_change_progress' then return 'unavailable' end
    if kind=='http_429' then return 'rate_limited' end
    if ({transport=true,timeout=true,http_500=true,http_502=true,http_503=true,http_504=true})[kind] then return 'temporary' end
    return 'unavailable'
end
function M.run(client,settings,selected,input,record,store,options)
    options=options or {};local out={kind='unconfirmed',attempted=false,book_id=input.book_id}
    local storage_failure=false
    local function owns()
        if not current(settings,selected) then return false end
        local owned,reason=store:owns(record)
        if not owned and reason=='storage' then storage_failure=true end
        return owned
    end
    if not owns() then out.kind=storage_failure and 'temporary' or 'login';return out end
    local prepared,plan=pcall(M.preview,client,settings,selected,input.book_id,input.desired)
    if not prepared then out.kind=M.read_error(plan);return out end
    if not Contract.same(plan.metadata,record.metadata) then out.kind='changed';out.observed=plan.observed;return out end
    if plan.metadata.before==plan.metadata.desired then out.kind='noop';out.observed=plan.observed;return out end
    local auth=Auth:new(client,{expected_vid=selected.scope.vid,is_current=owns})
    pcall(auth._request,auth,'reading_change_write',BASE..'/book/markstatus',plan.body,selected.credentials,nil,function()
        local owned=owns();local claimed,reason
        if owned then claimed,reason=store:claim(record) end
        if not claimed and reason=='storage' then storage_failure=true end
        assert(owned and claimed,'reading_state_change/replaced');out.attempted=true
    end)
    auth:cancel();if not out.attempted then out.kind=storage_failure and 'temporary' or 'unavailable';return out end
    local sleep=options.sleep or function(seconds) require('socket').sleep(seconds) end
    for attempt=1,3 do
        if not owns() then return out end
        if attempt>1 then sleep(.5*(attempt-1)) end
        local read,observed=pcall(M.observe,client,settings,selected,input.book_id)
        if read and owns() then
            out.observed=observed
            local checked,match=pcall(Contract.check,observed.raw,observed.progress,record.metadata,selected.scope.vid)
            if checked and match then out.kind='confirmed';return out end
            local valid,unchanged=pcall(Contract.unchanged,observed.raw,observed.progress,record.metadata,selected.scope.vid)
            if not valid or not unchanged then return out end
        end
    end
    return out
end
return M
