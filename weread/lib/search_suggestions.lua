-- Read-only, account-bound search words; never persist credentials or results.
local Auth=require('weread.lib.native_authorization')
local Access=require('weread.lib.native_gateway_access')
local Protocol=require('weread.lib.protocol')
local Trim=require('weread.lib.search_query').trim
local M={MAX_WORDS=10}

local function text(value)
    return type(value)=='string' and value~='' and #value<=512 and not value:find('[%z%c]')
        and Protocol.utf8_substr(value,#value+1)==value and Trim(value)==value
end
local function array(value)
    if type(value)~='table' or #value>100 then return false end
    for key in pairs(value) do
        if type(key)~='number' or key%1~=0 or key<1 or key>#value then return false end
    end
    return true
end

function M.keyword(value)
    value=Trim(value)
    return text(value) and value or nil
end

function M.project(data,keyword)
    if not text(keyword) or type(data)~='table' or data.keyword~=nil and data.keyword~=keyword
        or data.errcode~=nil and data.errcode~=0 or data.errCode~=nil and data.errCode~=0
        or not array(data.records) or not array(data.list) or not array(data.parts) then error('suggest/invalid',0) end
    local words,seen={},{}
    for _,rows in ipairs({data.records,data.list}) do
        for _,row in ipairs(rows) do
            if type(row)~='table' then error('suggest/invalid',0) end
            if row.word~=nil then
                if not text(row.word) then error('suggest/invalid',0) end
                if not seen[row.word] and #words<M.MAX_WORDS then
                    seen[row.word]=true;words[#words+1]=row.word
                end
            end
        end
    end
    return words
end

function M.fetch(client,selected,keyword)
    if not text(keyword) or not selected or not selected.native then error('suggest/access',0) end
    local function current() return Access.matches(client.settings,selected) end
    if not current() then error('suggest/session',0) end
    local auth=Auth:new(client,{expected_vid=selected.native.scope.vid,is_current=current})
    local ok,data=pcall(auth.read_search_suggestions,auth,selected.native.credentials,keyword)
    auth:cancel()
    if not current() then error('suggest/session',0) end
    if not ok then error(data,0) end
    return M.project(data,keyword)
end

return M
