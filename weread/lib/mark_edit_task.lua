-- Child-only source checking and one-shot highlight writes. Complete own
-- thoughts and marks are independently read together after the dispatch.
local Access=require('weread.lib.native_read_access')
local Marks=require('weread.lib.my_cloud_marks')
local Thoughts=require('weread.lib.my_cloud_thoughts')
local Contract=require('weread.lib.mark_edit_contract')
local Auth=require('weread.lib.native_authorization')
local M={}
local function current(settings,selected) return not selected.renewal_pending and Access.matches(settings,selected) end
function M.observe(client,settings,selected,book)
    if not current(settings,selected) then error('mark_edit/login',0) end
    local auth=Auth:new(client,{expected_vid=selected.scope.vid,is_current=function() return current(settings,selected) end})
    local ok,value=pcall(auth.read_my_cloud_marks,auth,selected.credentials,book);auth:cancel()
    if not ok then error(value,0) end
    if not current(settings,selected) then error('mark_edit/login',0) end
    return {book_id=book,marks=Marks.project(client,value,book,selected.scope.vid,os.time()),
        thoughts=Thoughts.fetch(client,book,{native=selected},{recover_auth=true})}
end
function M.preview(client,settings,selected,input)
    local snapshot=M.observe(client,settings,selected,input.book_id)
    local metadata
    if input.operation=='create' then
        local book=settings:get_book(input.book_id)
        if not book then error('mark_edit/source',0) end
        book.chapters=require('weread.lib.library_db'):new(settings):getChapters(input.book_id)
        local reference=require('weread.lib.selection_reference').verify(input.reference,book,input.source_file)
        if not reference then error('mark_edit/source',0) end
        local source=require('weread.lib.source_currentness');local access=source.capture(settings)
        if not access or not access.web or access.web.cookies.wr_vid~=selected.scope.vid then error('mark_edit/source_access',0) end
        source.fetch(client,reference.source,access)
        local auth=Auth:new(client,{expected_vid=selected.scope.vid,is_current=function() return current(settings,selected) end})
        local ok,value=pcall(auth.read_book_metadata,auth,selected.credentials,input.book_id);auth:cancel()
        if not ok then error(value,0) end;metadata=value
    end
    if not current(settings,selected) then error('mark_edit/login',0) end
    return Contract.make(client,snapshot,input.operation,input.reference,metadata,input.style)
end
function M.expired(reason) return reason==Thoughts.EXPIRED or reason=='native_auth/my_marks/http_401' or reason=='native_auth/metadata/http_401' end
function M.source_login(reason) return reason=='mark_edit/source_access' or reason=='source_currentness/web_expired' end
function M.same(a,b)
    if not Contract.validate_metadata(a) or not Contract.validate_metadata(b) then return false end
    for k,v in pairs(a) do if b[k]~=v then return false end end
    return true
end
function M.run(client,settings,selected,input,record,store,options)
    options=options or {};local attempted=false;local now=options.now or os.time
    local function owns()
        local clock=now()
        return (not options.started or clock>=options.started) and (not options.deadline or clock<=options.deadline)
            and current(settings,selected) and store:owns(record)
    end
    local out={kind='unconfirmed',attempted=false}
    if not owns() then out.kind='login';return out end
    local ok,plan=pcall(M.preview,client,settings,selected,input)
    if not ok then out.kind=M.expired(plan) and 'login' or M.source_login(plan) and 'source_login' or 'changed';return out end
    if not M.same(plan.metadata,record.metadata) or not Contract.validate_body(input.operation,plan.body)
        or Contract.body_hash(plan.body)~=record.metadata.request_hash then out.kind='changed';return out end
    local auth=Auth:new(client,{expected_vid=selected.scope.vid,is_current=owns})
    pcall(auth.write_my_highlight,auth,selected.credentials,input.operation,plan.body,function()
        if not owns() or not store:claim(record) then error('mark_edit/replaced',0) end
        attempted=true
    end)
    auth:cancel();out.attempted=attempted
    if not attempted then out.kind='unavailable';return out end
    local sleep=options.sleep or function(seconds) require('socket').sleep(seconds) end
    for attempt=1,3 do
        if not owns() then return out end
        if attempt>1 then sleep((attempt-1)*.5) end
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
