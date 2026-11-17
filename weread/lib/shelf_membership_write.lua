-- Native membership protocol: fresh full preflight, one POST, bounded GETs.
-- Python-first owner proof: docs/validation-assets/2026-11-10/shelf-owner-roundtrip.json.
local Crypto=require('weread.lib.crypto')
local Access=require('weread.lib.native_read_access')
local Auth=require('weread.lib.native_authorization')
local Source=require('weread.lib.shelf_source')
local Snapshot=require('weread.lib.shelf_snapshot')
local M={}
function M.book_id(value)
    return type(value)=='string' and ((#value<=20 and value:match('^[1-9]%d*$'))
        or (#value<=27 and value:match('^MP_WXS_[1-9]%d*$'))) and value or nil
end
function M.is_account(value) return M.book_id(value)~=nil and value:match('^MP_WXS_')~=nil end
local function array(value)
    if type(value)~='table' then return false end
    local count=0
    for key in pairs(value) do
        if type(key)~='number' or key%1~=0 or key<1 or key>#value then return false end
        count=count+1
    end
    return count==#value
end
function M.members(snapshot)
    if type(snapshot)~='table' or not Snapshot.metadata(snapshot.books,0) then return nil end
    local members={};for _i,book in ipairs(snapshot.books) do members[#members+1]=Snapshot.id(book) end
    table.sort(members);return members
end
function M.digest(members)
    local parts={};for _i,id in ipairs(members) do parts[#parts+1]=#id..':'..id end
    return Crypto.sha256_hex(table.concat(parts))
end
function M.contains(snapshot,id)
    local members=M.members(snapshot);if not members then return nil end
    for _i,value in ipairs(members) do if value==id then return true end end
    return false
end
function M.expected(plan)
    local members={}
    for _i,id in ipairs(plan.members) do if id~=plan.book_id then members[#members+1]=id end end
    if plan.operation=='add' then members[#members+1]=plan.book_id end
    table.sort(members);return M.digest(members)
end
-- Account writes additionally protect visible flags and groups of other items.
function M.protected(snapshot,id)
    if type(snapshot)~='table' or not array(snapshot.books) or not array(snapshot.archive) then return nil end
    local clean={books={},archive={}}
    for _i,book in ipairs(snapshot.books) do if Snapshot.id(book)~=id then clean.books[#clean.books+1]=book end end
    for _i,group in ipairs(snapshot.archive) do
        if type(group)~='table' then return nil end
        local row={};for key,value in pairs(group) do row[key]=value end
        for _j,field in ipairs({'bookIds','albumIds'}) do
            if row[field]~=nil then
                if not array(row[field]) then return nil end
                local values={};for _k,value in ipairs(row[field]) do if tostring(value)~=id then values[#values+1]=value end end
                row[field]=values
            end
        end
        clean.archive[#clean.archive+1]=row
    end
    local ok,value=pcall(require('weread.lib.shelf_flag_change_contract').state_hash,clean)
    return ok and value or nil
end
function M.fetch(client,settings,selected)
    assert(selected and not selected.renewal_pending and Access.matches(settings,selected),'shelf_membership/access_changed')
    local auth=Auth:new(client,{expected_vid=selected.scope.vid,is_current=function()
        return not selected.renewal_pending and Access.matches(settings,selected)
    end})
    return Source.normalize(auth:read_shelf(selected.credentials))
end
function M.preview(client,settings,selected)
    local ok,value=pcall(M.fetch,client,settings,selected)
    if ok then return {snapshot=value} end
    -- Only this bounded native transport's exact status marker requests
    -- recovery. Network exception text and business errors stay unavailable.
    return {native_expired=value=='native_auth/shelf/http_401'}
end
function M.run(client,settings,selected,plan,owns)
    local attempted=false
    local result={book_id=plan.book_id,operation=plan.operation,attempted=false,confirmed=false}
    local ok=pcall(function()
        local first=M.preview(client,settings,selected)
        if first.native_expired then result.kind='login';return end
        local fresh=assert(first.snapshot)
        local members=assert(M.members(fresh))
        if M.is_account(plan.book_id) then
            assert(type(plan.protected_digest)=='string' and M.protected(fresh,plan.book_id)==plan.protected_digest,'shelf_membership/changed')
        end
        local before=M.contains(fresh,plan.book_id)
        if before==(plan.operation=='add') then result.kind='noop';result.snapshot=fresh;return end
        if before~=plan.before or M.digest(members)~=plan.members_digest then
            result.kind='changed';result.snapshot=fresh;return
        end
        assert(owns() and Access.matches(settings,selected),'shelf_membership/replaced')
        local auth=Auth:new(client,{expected_vid=selected.scope.vid,is_current=function()
            return owns() and Access.matches(settings,selected)
        end})
        local accepted,response=pcall(auth.write_shelf_membership,auth,selected.credentials,plan.book_id,plan.operation,function() attempted=true end)
        local acknowledged=accepted and type(response)=='table' and (response.succ==1 or response.succ==true)
            and (response.errcode==nil or response.errcode==0) and (response.errCode==nil or response.errCode==0)
            and (response.success==nil or response.success==true)
        result.acknowledged=acknowledged==true
        if not attempted then result.kind='unavailable';return end
        result.kind='unconfirmed'
        for _i=1,3 do
            if _i>1 then require('socket').sleep(.5*(_i-1)) end
            local read,snapshot=pcall(M.fetch,client,settings,selected)
            if read then
                local observed=M.contains(snapshot,plan.book_id)==(plan.operation=='add')
                local same=M.digest(assert(M.members(snapshot)))==M.expected(plan)
                if M.is_account(plan.book_id) then same=same and M.protected(snapshot,plan.book_id)==plan.protected_digest end
                result.snapshot=snapshot
                if observed then
                    result.confirmed=acknowledged==true and same
                    if result.confirmed then result.kind='confirmed' end
                    break
                end
            end
        end
    end)
    result.attempted=attempted
    if not ok then result.kind=attempted and 'unconfirmed' or 'unavailable' end
    return result
end
return M
