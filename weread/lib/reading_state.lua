-- Read the E-Ink start flag without changing reading position or shelf state.
local Access=require('weread.lib.native_read_access')
local Identity=require('weread.lib.read_access')
local Auth=require('weread.lib.native_authorization')
local M={}

function M.id(value)
    if type(value)~='string' then return nil end
    return Identity.display_book_id(value)
end

local function matches(value,expected)
    if value==nil then return true end
    if type(value)=='string' then return value==expected end
    if type(value)=='number' and value>=0 and value<=9007199254740991 and value%1==0 then
        return string.format('%.0f',value)==expected
    end
    return false
end

function M.project(raw,id,owner)
    if not M.id(id) or type(owner)~='string' or not owner:match('^[1-9]%d*$')
        or type(raw)~='table' or type(raw.book)~='table' then return nil,'invalid' end
    for _,node in ipairs({raw,raw.book}) do
        if not matches(node.bookId,id) or not matches(node.vid,owner)
            or not matches(node.userVid,owner) then return nil,'identity' end
    end
    for _,key in ipairs({'errcode','errCode'}) do
        if raw[key]~=nil and raw[key]~=0 then return nil,'invalid' end
    end
    if raw.succ~=nil and raw.succ~=1 and raw.succ~=true then return nil,'invalid' end
    local flag=raw.book.isStartReading
    if flag==nil then return nil,'missing' end
    if type(flag)~='number' or flag~=0 and flag~=1 then return nil,'invalid' end
    return flag==1
end

function M.read(client,settings,selected,id)
    local function current()
        return selected and not selected.renewal_pending and Access.matches(settings,selected)
    end
    if not M.id(id) or not current() then return {kind='login'} end
    local auth=Auth:new(client,{expected_vid=selected.scope.vid,is_current=current})
    local ok,raw=pcall(auth._request,auth,'reading_state',
        'https://i.weread.qq.com/book/getProgress?bookId='..id,nil,selected.credentials)
    auth:cancel()
    if not current() then return {kind='stale'} end
    if not ok then
        return {kind=raw=='native_auth/reading_state/http_401' and 'login' or 'unavailable'}
    end
    local value,reason=M.project(raw,id,selected.scope.vid)
    if reason then return {kind=reason=='missing' and 'missing' or 'unavailable'} end
    return {kind='known',started=value}
end

return M
