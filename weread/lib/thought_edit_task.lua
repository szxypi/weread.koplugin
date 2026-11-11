-- Background-only preflight, single dispatch and independent readback. A
-- receipt never substitutes for observing the exact expected personal set.
local Access=require('weread.lib.native_read_access')
local Thoughts=require('weread.lib.my_cloud_thoughts')
local Contract=require('weread.lib.thought_edit_contract')
local Auth=require('weread.lib.native_authorization')
local M={}
local function current(settings,selected)
    return not selected.renewal_pending and Access.matches(settings,selected)
end
function M.observe(client,settings,selected,book)
    if not current(settings,selected) then error('thought_edit/login',0) end
    return Thoughts.fetch(client,book,{native=selected},{recover_auth=true})
end
function M.preview(client,settings,selected,input)
    local snapshot=M.observe(client,settings,selected,input.book_id)
    local marks,metadata
    if input.operation=='create' then
        local auth=Auth:new(client,{expected_vid=selected.scope.vid,is_current=function() return current(settings,selected) end})
        local ok,result=pcall(function()
            marks=auth:read_my_cloud_marks(selected.credentials,input.book_id)
            metadata=auth:read_book_metadata(selected.credentials,input.book_id)
        end)
        auth:cancel();if not ok then error(result,0) end
    end
    return Contract.make(client,snapshot,input.operation,input.reference,input.content,marks,metadata,selected.scope.vid)
end
function M.expired(reason)
    return reason==Thoughts.EXPIRED or reason=='native_auth/my_marks/http_401' or reason=='native_auth/metadata/http_401'
end
function M.same(a,b)
    if not Contract.validate_metadata(a) or not Contract.validate_metadata(b) then return false end
    for k,v in pairs(a) do if b[k]~=v then return false end end
    return true
end
function M.run(client,settings,selected,input,record,store,options)
    options=options or {};local attempted=false
    local function owns() return current(settings,selected) and store:owns(record) end
    local out={kind='unconfirmed',attempted=false}
    if not owns() then out.kind='login';return out end
    local ok,plan=pcall(M.preview,client,settings,selected,input)
    if not ok then out.kind=M.expired(plan) and 'login' or 'changed';return out end
    if not M.same(plan.metadata,record.metadata) or not Contract.validate_body(input.operation,plan.body)
        or Contract.body_hash(plan.body)~=record.metadata.request_hash then out.kind='changed';return out end
    if plan.metadata.before_hash==plan.metadata.after_hash then out.kind='noop';out.snapshot=plan.snapshot;return out end
    local auth=Auth:new(client,{expected_vid=selected.scope.vid,is_current=owns})
    -- Claim commits with SQLite synchronous=FULL before a possible network
    -- write. No caller, worker restart, cancellation or retry can claim twice.
    pcall(auth.write_my_thought,auth,selected.credentials,input.operation,plan.body,function()
        if not owns() or not store:claim(record) then error('thought_edit/replaced',0) end
        attempted=true
    end)
    auth:cancel();out.attempted=attempted
    if not attempted then out.kind='unavailable';return out end
    local sleep=options.sleep or function(seconds) require('socket').sleep(seconds) end
    for attempt=1,3 do
        if not owns() then return out end
        if attempt>1 then sleep((attempt-1)*0.5) end
        local observed,snapshot=pcall(M.observe,client,settings,selected,input.book_id)
        if observed and owns() then
            out.snapshot=snapshot
            local checked,confirmed=pcall(Contract.check,snapshot,record.metadata)
            if checked and confirmed then out.kind='confirmed';return out end
        end
    end
    return out
end
return M
