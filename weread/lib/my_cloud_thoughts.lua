-- Own thoughts: listType=11 verified by verify_my_cloud_thoughts.py first.
-- Reference: weread_to_notion aa828ac9f2b6ffc6e62872340bef11fed796b873.
-- A false hasMore flag is insufficient: actual count=1/2 replies were prefixes.
local Marks=require('weread.lib.my_cloud_marks')
local Protocol=require('weread.lib.protocol')
local M={MAX_ROWS=5000,id=Marks.id,capture=Marks.capture,matches=Marks.matches,EXPIRED='my_thoughts/native_expired'}
local function fail(reason) error('my_thoughts/'..reason,0) end
local function integer(value,max) return type(value)=='number' and value>=0 and value%1==0 and value<=max end
local function text(value,max,empty)
    return type(value)=='string' and (empty or value~='') and #value<=max and not value:find('[%z\1-\8\11\12\14-\31\127]')
        and Protocol.utf8_substr(value,#value)==value
end
local function codec_info(client)
    local null=client:json_decode('null');local mt=getmetatable(client:json_decode('[]'))
    local function present(value) return value~=nil and value~=null end
    local function array(value)
        if type(value)~='table' or value==null or #value>M.MAX_ROWS or #value==0 and mt and getmetatable(value)~=mt then fail('rows') end
        for key in pairs(value) do if not integer(key,M.MAX_ROWS) or key<1 or key>#value then fail('rows') end end
    end
    local function scope(value,id,owner)
        if type(value)~='table' or value==null then fail('object') end
        for _i,key in ipairs({'bookId','book_id'}) do if present(value[key]) and tostring(value[key])~=id then fail('book') end end
        for _i,key in ipairs({'userVid','vid'}) do if owner and present(value[key]) and tostring(value[key])~=owner then fail('owner') end end
    end
    return present,array,scope
end
local function entry(value,present)
    local id=value.reviewId
    if not text(id,256) or id:find('%s') then fail('identity') end
    local out={reviewId=id}
    for name,max in pairs({content=131072,abstract=65536,chapterName=4096,range=256}) do
        if present(value[name]) then if not text(value[name],max,true) then fail('text') end;out[name]=value[name] end
    end
    if out.content==nil then fail('text') end
    for _i,name in ipairs({'chapterUid','chapterIdx','type','createTime','isPrivate','isFinish'}) do
        if present(value[name]) then
            local observed=value[name]
            -- Native creation echoes the decimal chapter UID as a string.
            -- Keep one canonical numeric cache shape; no other field coerces.
            if name=='chapterUid' and type(observed)=='string' and #observed<=10
                and (observed=='0' or observed:match('^[1-9]%d*$')) then observed=tonumber(observed) end
            local max=name=='createTime' and 4102444800 or (name=='isPrivate' or name=='isFinish') and 1 or 2147483647
            if not integer(observed,max) then fail('number') end;out[name]=observed
        end
    end
    return out
end
function M.page(client,source,id,owner)
    if not M.id(id) or not M.id(owner) then fail('scope') end
    local present,array,scope=codec_info(client);scope(source,id,owner)
    for _i,key in ipairs({'errcode','errCode'}) do if present(source[key]) and source[key]~=0 then fail('rejected') end end
    if present(source.succ) and source.succ~=true and source.succ~=1 then fail('rejected') end
    array(source.reviews)
    if not integer(source.totalCount,M.MAX_ROWS) or source.hasMore~=true and source.hasMore~=false and source.hasMore~=0 and source.hasMore~=1 then fail('page') end
    local out,seen=client:json_decode('[]'),{}
    for _i,row in ipairs(source.reviews) do
        scope(row,id,owner);local review=row.review;scope(review,id,owner)
        if not present(review.bookId) or tostring(review.bookId)~=id then fail('book') end
        local explicit=false
        for _j,name in ipairs({'userVid','vid'}) do if present(review[name]) then explicit=true end end
        if present(review.author) then
            scope(review.author,id,owner)
            if present(review.author.userVid) then explicit=true end
        end
        if not explicit then fail('owner') end
        if present(review.book) then scope(review.book,id,owner) end
        local item=entry(review,present)
        if present(row.reviewId) and row.reviewId~=item.reviewId then fail('identity') end
        if seen[item.reviewId] then fail('duplicate') end
        seen[item.reviewId]=true;out[#out+1]=item
    end
    if #out>source.totalCount then fail('page') end
    return {reviews=out,total_count=source.totalCount,has_more=source.hasMore==true or source.hasMore==1 or #out<source.totalCount}
end
function M.snapshot(client,page,id,now)
    if not M.id(id) or not integer(now,2^53-1) or now==0 then fail('time') end
    if page.has_more or #page.reviews~=page.total_count then fail('incomplete') end
    return M.validate(client,{schema=1,book_id=id,fetched_at=now,reviews=page.reviews},id)
end
function M.validate(client,value,id)
    if not M.id(id) or type(value)~='table' or value.schema~=1 or value.book_id~=id
        or not integer(value.fetched_at,2^53-1) or value.fetched_at==0 then fail('snapshot') end
    local present,array,scope=codec_info(client);scope(value,id);array(value.reviews)
    local out={schema=1,book_id=id,fetched_at=value.fetched_at,reviews=client:json_decode('[]')};local seen={}
    for _i,row in ipairs(value.reviews) do
        scope(row,id);local item=entry(row,present)
        if seen[item.reviewId] then fail('duplicate') end
        seen[item.reviewId]=true;out.reviews[#out.reviews+1]=item
    end
    return out
end
function M.project(client,source,id,owner,now)
    return M.snapshot(client,M.page(client,source,id,owner),id,now)
end
local function same(left,right)
    for key,value in pairs(left) do if right[key]~=value then return false end end
    for key,value in pairs(right) do if left[key]~=value then return false end end
    return true
end
function M.fetch(client,id,selected,options)
    options=options or {};if not M.id(id) then fail('scope') end
    local function current() return M.matches(client.settings,selected) end
    if not current() then fail('session_changed') end
    local auth=require('weread.lib.native_authorization'):new(client,{expected_vid=selected.native.scope.vid,is_current=current})
    local previous,count=nil,20
    for _attempt=1,9 do
        local ok,source=pcall(auth.read_my_cloud_thoughts,auth,selected.native.credentials,id,count)
        if not current() then auth:cancel();fail('session_changed') end
        if not ok then
            auth:cancel()
            if source=='native_auth/my_thoughts/http_401' and options.recover_auth and not selected.native.renewal_pending then fail('native_expired') end
            fail('unavailable')
        end
        local valid,page=pcall(M.page,client,source,id,selected.native.scope.vid)
        if not valid then auth:cancel();fail('invalid') end
        if previous then
            if page.total_count~=previous.total_count or #page.reviews<=#previous.reviews then auth:cancel();fail('changed') end
            for index,row in ipairs(previous.reviews) do if not same(row,page.reviews[index]) then auth:cancel();fail('changed') end end
        end
        if not page.has_more then auth:cancel();return M.snapshot(client,page,id,options.now or os.time()) end
        if count>=M.MAX_ROWS then break end
        previous=page;count=math.min(M.MAX_ROWS,count*2)
    end
    auth:cancel();fail('incomplete')
end
return M
