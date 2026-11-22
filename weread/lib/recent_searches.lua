-- Short, account-local search history. Search results remain in their own cache.
local Query=require('weread.lib.search_query')
local Protocol=require('weread.lib.protocol')
local M={LIMIT=20,KEY='bookstore_recent_searches_v1'}
local function keyword(value)
    value=Query.trim(value)
    if value=='' or #value>4096 or value:find('[%z%c]')
        or Protocol.utf8_substr(value,#value+1)~=value then return nil end
    return value
end
local function valid(value)
    if type(value)~='table' or value.schema~=1 or type(value.entries)~='table' or #value.entries>M.LIMIT then return false end
    local seen={}
    for key in pairs(value) do if key~='schema' and key~='entries' then return false end end
    for key in pairs(value.entries) do if type(key)~='number' or key%1~=0 or key<1 or key>#value.entries then return false end end
    for _,entry in ipairs(value.entries) do
        if type(entry)~='table' or type(entry.keyword)~='string' or keyword(entry.keyword)~=entry.keyword
            or type(entry.public)~='boolean' then return false end
        for key in pairs(entry) do if key~='keyword' and key~='public' then return false end end
        local k=(entry.public and 'p' or 'a')..entry.keyword
        if seen[k] then return false end;seen[k]=true
    end
    return true
end
local function load(host)
    local db=host.library_db
    local account=db and db.accountKey and db:accountKey()
    if not account then
        local value=host._guest_recent_searches
        if value and not valid(value) then return nil,'storage' end
        return value,nil,nil
    end
    if not db.getProfileState or not db.compareProfileState then return nil,'storage',account end
    local ok,value=pcall(db.getProfileState,db,M.KEY)
    if not ok or value~=nil and not valid(value) then return nil,'storage',account end
    if db:accountKey()~=account then return nil,'account',account end
    return value,nil,account
end
local function save(host,account,before,after)
    local db=host.library_db
    if not account then
        if db and db.accountKey and db:accountKey() or host._guest_recent_searches~=before then return false end
        host._guest_recent_searches=after;return true
    end
    if not db or db:accountKey()~=account then return false end
    local ok,saved=pcall(db.compareProfileState,db,M.KEY,before,after)
    return ok and saved==true and db:accountKey()==account
end
function M.list(host)
    local state,err,account=load(host)
    if err then return nil,err end
    return state or {schema=1,entries={}},nil,account,state
end
function M.record(host,value,public)
    local term=keyword(value);if not term or type(public)~='boolean' then return false end
    local initial_account
    for attempt=1,2 do
        local current,err,account,original=M.list(host);if err then return false end
        if attempt==1 then initial_account=account elseif account~=initial_account then return false end
        local entries={{keyword=term,public=public}}
        for _,entry in ipairs(current.entries) do
            if (entry.keyword~=term or entry.public~=public) and #entries<M.LIMIT then
                entries[#entries+1]={keyword=entry.keyword,public=entry.public}
            end
        end
        if save(host,account,original,{schema=1,entries=entries}) then return true end
    end
    return false
end
function M.remove(host,snapshot,account,original,index)
    if not valid(snapshot) or type(index)~='number' or index%1~=0 or not snapshot.entries[index] then return false end
    local entries={}
    for i,entry in ipairs(snapshot.entries) do if i~=index then entries[#entries+1]={keyword=entry.keyword,public=entry.public} end end
    return save(host,account,original,{schema=1,entries=entries})
end
function M.clear(host,snapshot,account,original)
    if not valid(snapshot) then return false end
    return save(host,account,original,{schema=1,entries={}})
end
return M
