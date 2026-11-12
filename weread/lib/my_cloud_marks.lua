-- Display-only own marks, verified by verify_my_cloud_marks.py before Lua.
-- Endpoint reference: MiuRead c1893562aa25a870b8dd076d7be062a3348f823e,
-- AGPL-3.0-only, Copyright (C) 2026 MiuRead contributors.
local Access=require('weread.lib.native_read_access')
local Crypto=require('weread.lib.crypto')
local Protocol=require('weread.lib.protocol')
local M={MAX_ROWS=5000}
local function fail(reason) error('my_marks/'..reason,0) end
function M.id(value)
    return type(value)=='string' and #value<=20 and value:match('^[1-9]%d*$') and value or nil
end
local function integer(value,max) return type(value)=='number' and value>=0 and value%1==0 and value<=max end
local function text(value,max,empty)
    return type(value)=='string' and (empty or value~='') and #value<=max
        and not value:find('[%z\1-\8\11\12\14-\31\127]') and Protocol.utf8_substr(value,#value)==value
end
function M.project(client,source,id,owner,now)
    if not M.id(id) or not integer(now,2^53-1) or now==0 then fail('scope') end
    local null=client:json_decode('null');local mt=getmetatable(client:json_decode('[]'))
    local function present(value) return value~=nil and value~=null end
    local function scope(value)
        if type(value)~='table' or value==null then fail('object') end
        for _i,key in ipairs({'bookId','book_id'}) do
            if present(value[key]) and tostring(value[key])~=id then fail('book') end
        end
        for _i,key in ipairs({'userVid','vid'}) do
            if owner and present(value[key]) and tostring(value[key])~=owner then fail('owner') end
        end
    end
    local function array(value)
        if type(value)~='table' or value==null or #value>M.MAX_ROWS or #value==0 and mt and getmetatable(value)~=mt then fail('rows') end
        for key in pairs(value) do if not integer(key,M.MAX_ROWS) or key<1 or key>#value then fail('rows') end end
    end
    scope(source)
    for _i,key in ipairs({'errcode','errCode'}) do if present(source[key]) and source[key]~=0 then fail('rejected') end end
    if present(source.succ) and source.succ~=true and source.succ~=1 then fail('rejected') end
    if present(source.hasMore) and source.hasMore~=false and source.hasMore~=0 then fail('incomplete') end
    if present(source.book) then scope(source.book) end
    local chapters=source.chapters==nil and client:json_decode('[]') or source.chapters
    array(source.updated);array(chapters)
    local result={schema=1,book_id=id,fetched_at=now,updated=client:json_decode('[]'),chapters=client:json_decode('[]')}
    local seen={}
    for _i,row in ipairs(source.updated) do
        scope(row);local key=row.bookmarkId
        if not text(key,256) or key:find('%s') or seen[key] then fail('identity') end
        seen[key]=true;local item={bookmarkId=key}
        for name,max in pairs({markText=131072,abstract=65536,range=256}) do
            if present(row[name]) then if not text(row[name],max,true) then fail('text') end;item[name]=row[name] end
        end
        for _j,name in ipairs({'chapterUid','chapterIdx','type','style','colorStyle','createTime'}) do
            if present(row[name]) then
                if not integer(row[name],name=='createTime' and 4102444800 or 2147483647) then fail('number') end
                item[name]=row[name]
            end
        end
        result.updated[#result.updated+1]=item
    end
    seen={}
    for _i,row in ipairs(chapters) do
        scope(row);local uid=row.chapterUid
        if not integer(uid,2147483647) or seen[uid] or not text(row.title,4096) then fail('chapter') end
        seen[uid]=true;result.chapters[#result.chapters+1]={chapterUid=uid,title=row.title}
    end
    return result
end
function M.validate(client,value,id)
    if type(value)~='table' or value.schema~=1 or value.book_id~=id then fail('snapshot') end
    return M.project(client,value,id,nil,value.fetched_at)
end
function M.capture(settings,store)
    local native=Access.capture(settings,store);if not native then return end
    return {native=native,revision=native.fingerprint,
        base_revision=Crypto.sha256_hex(native.scope.vid..'\0'..tostring(native.scope.epoch))}
end
function M.matches(settings,selected)
    return selected~=nil and Access.matches(settings,selected.native)
end
function M.fetch(client,id,selected,options)
    options=options or {}
    if not M.id(id) then fail('scope') end
    local function current() return M.matches(client.settings,selected) end
    if not current() then fail('session_changed') end
    local auth=require('weread.lib.native_authorization'):new(client,{expected_vid=selected.native.scope.vid,is_current=current})
    local ok,value=pcall(auth.read_my_cloud_marks,auth,selected.native.credentials,id)
    auth:cancel();if not current() then fail('session_changed') end
    if not ok then
        if value=='native_auth/my_marks/http_401' and options.recover_auth and not selected.native.renewal_pending then fail('native_expired') end
        fail('unavailable')
    end
    return M.project(client,value,id,selected.native.scope.vid,options.now or os.time())
end
return M
