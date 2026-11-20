-- Native notebook list: independent read-only projection, never note bodies.
local Marks=require('weread.lib.my_cloud_marks')
local Protocol=require('weread.lib.protocol')
local M={MAX_ROWS=5000,capture=Marks.capture,matches=Marks.matches,EXPIRED='notebooks/native_expired'}
local function fail(reason) error('notebooks/'..reason,0) end
local function integer(value,max)
    return type(value)=='number' and value>=0 and value<=max and value%1==0
end
local function text(value,max,empty)
    return type(value)=='string' and (empty or value~='') and #value<=max and not value:find('[%z%c]')
        and Protocol.utf8_substr(value,#value+1)==value
end
local function identity(value)
    if integer(value,2^53-1) and value>0 then value=string.format('%.0f',value) end
    return text(value,256) and not value:find('%s') and value or nil
end
local function array(client,value)
    local null=client:json_decode('null');local mt=getmetatable(client:json_decode('[]'))
    if type(value)~='table' or value==null or #value>M.MAX_ROWS or #value==0 and mt and getmetatable(value)~=mt then fail('rows') end
    for key in pairs(value) do if not integer(key,M.MAX_ROWS) or key<1 or key>#value then fail('rows') end end
end
local function row(value,wire,present)
    if type(value)~='table' then fail('row') end
    local book=wire and value.book or value
    if type(book)~='table' then fail('row') end
    local id=identity(value.bookId)
    if not id or wire and identity(book.bookId)~=id or not text(book.title,4096) then fail('book') end
    local author=present(book.author) and book.author or ''
    if not text(author,4096,true) then fail('book') end
    local result={bookId=id,title=book.title,author=author}
    for _,key in ipairs({'noteCount','reviewCount','bookmarkCount','sort'}) do
        if present(value[key]) then
            if not integer(value[key],key=='sort' and 2^53-1 or 2147483647) then fail('number') end
            result[key]=value[key]
        end
    end
    return result
end
local function rows(client,values,wire)
    array(client,values)
    local null=client:json_decode('null');local function present(v) return v~=nil and v~=null end
    local result=client:json_decode('[]');local seen={}
    for _,value in ipairs(values) do
        local item=row(value,wire,present)
        if seen[item.bookId] then fail('duplicate') end
        seen[item.bookId]=true;result[#result+1]=item
    end
    return result
end
function M.project(client,source,now)
    if type(source)~='table' or not integer(now,2^53-1) or now==0 then fail('scope') end
    local null=client:json_decode('null');local function present(v) return v~=nil and v~=null end
    for _,key in ipairs({'errcode','errCode'}) do if present(source[key]) and source[key]~=0 then fail('rejected') end end
    if present(source.succ) and source.succ~=true and source.succ~=1 then fail('rejected') end
    if present(source.hasMore) and source.hasMore~=false and source.hasMore~=0 then fail('incomplete') end
    local books=rows(client,source.books,true)
    if not integer(source.totalBookCount,M.MAX_ROWS) or source.totalBookCount~=#books then fail('incomplete') end
    return {schema=1,fetched_at=now,books=books}
end
function M.validate(client,value)
    if type(value)~='table' or value.schema~=1 or not integer(value.fetched_at,2^53-1) or value.fetched_at==0 then fail('snapshot') end
    return {schema=1,fetched_at=value.fetched_at,books=rows(client,value.books,false)}
end
function M.fetch(client,access,options)
    options=options or {}
    local function current() return M.matches(client.settings,access) end
    if not current() then fail('session_changed') end
    local auth=require('weread.lib.native_authorization'):new(client,{expected_vid=access.native.scope.vid,is_current=current})
    local ok,value=pcall(auth.read_notebooks,auth,access.native.credentials)
    auth:cancel()
    if not current() then fail('session_changed') end
    if not ok then
        if value=='native_auth/notebooks/http_401' and options.recover_auth and not access.native.renewal_pending then fail('native_expired') end
        fail('unavailable')
    end
    return M.project(client,value,options.now or os.time())
end
return M
