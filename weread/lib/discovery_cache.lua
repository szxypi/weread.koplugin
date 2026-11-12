-- Bounded, account-local bookstore batches. No credentials or remote session
-- identifiers are persisted; saved batches are display-only until refreshed.
local Crypto=require('weread.lib.crypto')
local M={MAX_QUERIES=12,MAX_PAGES=12,MAX_PAYLOAD=2*1024*1024,MAX_TOTAL=16*1024*1024};M.__index=M
local function fail() error('discovery_cache/invalid',0) end
local function text(value,limit,empty)
    return type(value)=='string' and (empty or value~='') and #value<=limit and not value:find('[%z%c]')
end
local function integer(value,max) return type(value)=='number' and value>=0 and value%1==0 and value<=(max or 2147483647) end
local function array(value,max)
    if type(value)~='table' or #value>max then return false end
    for key in pairs(value) do if not integer(key,max) or key<1 or key>#value then return false end end
    return true
end
function M.query(value)
    if type(value)~='table' then fail() end
    local query={kind=value.kind}
    if query.kind=='search' then
        if not text(value.keyword,4096) then fail() end;query.keyword=value.keyword
    elseif query.kind=='similar' then
        if not text(value.book_id,256) or not text(value.book_title or '',4096,true) then fail() end
        query.book_id,query.book_title=value.book_id,value.book_title or ''
    elseif query.kind=='category' then
        if not text(value.category_id,128) or not text(value.category_title,4096) or type(value.rank)~='boolean' then fail() end
        query.category_id,query.category_title,query.rank=value.category_id,value.category_title,value.rank
    elseif query.kind~='recommend' then fail() end
    return query
end
function M.key(value)
    local query=M.query(value)
    return Crypto.sha256_hex(query.kind..'\0'..(query.keyword or query.book_id or query.category_id or '')..'\0'..tostring(query.rank or false))
end
local function books(value)
    if not array(value,100) then fail() end
    local out,seen={},{}
    for _,book in ipairs(value) do
        if type(book)~='table' or not text(book.bookId,256) or seen[book.bookId] then fail() end
        seen[book.bookId]=true
        local row={bookId=book.bookId}
        for key,limit in pairs({title=4096,author=4096,cover=8192,category=4096}) do
            if not text(book[key],limit,true) then fail() end;row[key]=book[key]
        end
        if book.searchIdx~=nil then if not integer(book.searchIdx) then fail() end;row.searchIdx=book.searchIdx end
        out[#out+1]=row
    end
    return out
end
local function page(value)
    if type(value)~='table' or not integer(value.cursor) or not integer(value.next_cursor)
        or type(value.has_more)~='boolean' or not integer(value.loaded_at,2^53) or value.loaded_at==0
        or value.has_more and value.next_cursor<=value.cursor then fail() end
    return {cursor=value.cursor,next_cursor=value.next_cursor,has_more=value.has_more,loaded_at=value.loaded_at,books=books(value.books)}
end
function M.validate(value)
    if type(value)~='table' or value.schema~=1 or not text(value.generation,32) or not value.generation:match('^[a-f0-9]+$')
        or #value.generation~=32 or not integer(value.updated_at,2^53) or value.updated_at==0
        or not array(value.pages,M.MAX_PAGES) or #value.pages==0
        or value.source_kind~='native' and value.source_kind~='gateway' and value.source_kind~='public' then fail() end
    local out={schema=1,generation=value.generation,query=M.query(value.query),updated_at=value.updated_at,
        source_kind=value.source_kind,pages={}};local seen={}
    for _,row in ipairs(value.pages) do
        local projected=page(row);if seen[projected.cursor] then fail() end
        seen[projected.cursor]=true;out.pages[#out.pages+1]=projected
    end
    if not seen[0] then fail() end
    return out
end
function M.state(value,cursor)
    local saved=M.validate(value);cursor=cursor or saved.pages[#saved.pages].cursor
    local lookup={};for _,row in ipairs(saved.pages) do lookup[row.cursor]=row end
    local row=lookup[0];local history={}
    while row and row.cursor~=cursor and #history<M.MAX_PAGES do
        if not row.has_more or row.next_cursor<=row.cursor then return nil end
        history[#history+1]=row.cursor;row=lookup[row.next_cursor]
    end
    if not row or row.cursor~=cursor then return nil end
    local result=M.query(saved.query)
    for key,item in pairs(page(row)) do result[key]=item end
    result.history=history;result.has_more=row.has_more and lookup[row.next_cursor]~=nil
    result.source_kind=saved.source_kind;result.cached=true
    return result
end
local function nonce()
    local f=io.open('/dev/urandom','rb');if not f then return nil end
    local raw=f:read(16);f:close();if not raw or #raw~=16 then return nil end
    return (raw:gsub('.',function(c) return string.format('%02x',c:byte()) end))
end
local function statement(db,sql,...)
    local stmt=db:prepare(sql);local args={...}
    local ok,row=pcall(function() return stmt:bind(unpack(args)):step() end)
    stmt:close();if not ok then error(row,0) end;return row
end
local function run(self,task)
    if not self.library or type(self.library.open)~='function' then return nil end
    local db=self.library:open();if not db then return nil end
    local transaction=false
    local ok,result=pcall(function()
        db:exec([[CREATE TABLE IF NOT EXISTS discovery_cache (
            cache_key TEXT PRIMARY KEY,payload TEXT NOT NULL,serial INTEGER NOT NULL
        )]])
        local function begin() db:exec('BEGIN IMMEDIATE');transaction=true end
        local function commit() db:exec('COMMIT');transaction=false end
        return task(db,begin,commit)
    end)
    if transaction then pcall(db.exec,db,'ROLLBACK') end
    pcall(db.close,db);return ok and result or nil
end
function M:new(library,codec) return setmetatable({library=library,codec=codec},self) end
local function read(self,db,key)
    local sql='SELECT CASE WHEN length(CAST(payload AS BLOB))<=? THEN payload ELSE NULL END, cache_key FROM discovery_cache'
    local row
    if key then row=statement(db,sql..' WHERE cache_key=?',M.MAX_PAYLOAD,key)
    else row=statement(db,sql..' ORDER BY serial DESC LIMIT 1',M.MAX_PAYLOAD) end
    if not row or type(row[1])~='string' then return nil end
    local value=M.validate(self.codec:json_decode(row[1]));if M.key(value.query)~=row[2] then fail() end
    return value
end
function M:read(query,cursor)
    return run(self,function(db)
        local value=read(self,db,query and M.key(query))
        return value and M.state(value,cursor)
    end)
end
function M:write(state,previous,continuation)
    local projected=page(state);local query=M.query(state);local key=M.key(query)
    return run(self,function(db,begin,commit)
        begin()
        local saved
        if continuation then
            if not previous or previous.cached or not previous._cache_generation or M.key(previous)~=key
                or previous.source_kind~=state.source_kind or previous.source_revision~=state.source_revision then return nil end
            saved=read(self,db,key)
            if not saved or saved.generation~=previous._cache_generation then return nil end
        else
            if state.cursor~=0 then return nil end
            saved={schema=1,generation=nonce(),query=query,source_kind=state.source_kind,pages={},updated_at=state.loaded_at}
        end
        local found=false
        for i,row in ipairs(saved.pages) do if row.cursor==state.cursor then saved.pages[i]=projected;found=true;break end end
        if not found then saved.pages[#saved.pages+1]=projected end
        saved.updated_at=state.loaded_at;saved.query=query
        saved=M.validate(saved)
        -- Keep last viewed batch last without trusting arbitrary persisted history.
        for i,row in ipairs(saved.pages) do if row.cursor==state.cursor then table.remove(saved.pages,i);saved.pages[#saved.pages+1]=row;break end end
        local payload=self.codec:json_encode(saved)
        if type(payload)~='string' or #payload>M.MAX_PAYLOAD then return nil end
        statement(db,[[INSERT INTO discovery_cache(cache_key,payload,serial)
            VALUES(?,?,(SELECT COALESCE(MAX(serial),0)+1 FROM discovery_cache))
            ON CONFLICT(cache_key) DO UPDATE SET payload=excluded.payload,serial=excluded.serial]],key,payload)
        local stmt=db:prepare('SELECT cache_key,length(CAST(payload AS BLOB)) FROM discovery_cache ORDER BY serial DESC')
        local remove,count,bytes={},0,0
        local iterated,reason=pcall(function()
            local row=stmt:step()
            while row do
                count=count+1
                if count>M.MAX_QUERIES+1 then fail() end
                bytes=bytes+tonumber(row[2]);if count>M.MAX_QUERIES or bytes>M.MAX_TOTAL then remove[#remove+1]=row[1] end
                row=stmt:step()
            end
        end)
        stmt:close();if not iterated then error(reason,0) end
        for _,expired in ipairs(remove) do statement(db,'DELETE FROM discovery_cache WHERE cache_key=?',expired) end
        commit();return saved.generation
    end)
end
return M
