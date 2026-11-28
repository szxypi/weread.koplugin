-- Bounded, account-local bookstore batches. No credentials or remote session
-- identifiers are persisted; saved batches are display-only until refreshed.
local Crypto=require('weread.lib.crypto')
local Protocol=require('weread.lib.protocol')
local M={MAX_QUERIES=12,MAX_PAGES=12,MAX_PAYLOAD=2*1024*1024,MAX_TOTAL=16*1024*1024};M.__index=M
-- Cache row serials start at one. Zero points to a guest category snapshot
-- and lets older versions ignore the position and open an account-local list.
local PUBLIC_REFERENCE_SERIAL=0
local query_metadata={metadata_only=true}
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
        if not text(value.keyword,4096) or Protocol.utf8_substr(value.keyword,#value.keyword+1)~=value.keyword then fail() end
        query.keyword=value.keyword
    elseif query.kind=='similar' then
        if not text(value.book_id,256) or not text(value.book_title or '',4096,true) then fail() end
        query.book_id,query.book_title=value.book_id,value.book_title or ''
    elseif query.kind=='category' then
        if not text(value.category_id,128) or not text(value.category_title,4096) or type(value.rank)~='boolean' then fail() end
        query.category_id,query.category_title,query.rank=value.category_id,value.category_title,value.rank
    elseif query.kind~='recommend' then fail() end
    return query
end
function M.key(value, public_search)
    local query=M.query(value)
    local identity=query.kind..'\0'..(query.keyword or query.book_id or query.category_id or '')..'\0'..tostring(query.rank or false)
    if query.kind=='search' and public_search then identity=identity..'\0public' end
    return Crypto.sha256_hex(identity)
end
local display_fields={title=4096,author=4096,cover=8192,category=4096}
local function books(value,build_cards)
    if not array(value,100) then fail() end
    local out=build_cards and {} or nil
    local seen={}
    for _,book in ipairs(value) do
        if type(book)~='table' or not text(book.bookId,256) or seen[book.bookId] then fail() end
        seen[book.bookId]=true
        for key,limit in pairs(display_fields) do
            if not text(book[key],limit,true) then fail() end
        end
        if book.reason~=nil and (not text(book.reason,512)
            or Protocol.utf8_substr(book.reason,#book.reason+1)~=book.reason) then fail() end
        if book.searchIdx~=nil and not integer(book.searchIdx) then fail() end
        if out then
            local row={bookId=book.bookId,title=book.title,author=book.author,cover=book.cover,
                category=book.category,reason=book.reason,searchIdx=book.searchIdx}
            if book._public_info~=nil then row._public_info=require('weread.lib.public_book_info').project(book._public_info) end
            out[#out+1]=row
        end
    end
    return out
end
local function page(value,build_cards)
    if type(value)~='table' or not integer(value.cursor) or not integer(value.next_cursor)
        or type(value.has_more)~='boolean' or not integer(value.loaded_at,2^53) or value.loaded_at==0
        or value.has_more and value.next_cursor<=value.cursor then fail() end
    return {cursor=value.cursor,next_cursor=value.next_cursor,has_more=value.has_more,loaded_at=value.loaded_at,
        books=books(value.books,build_cards~=false)}
end
local function valid_source(kind)
    return kind=='native' or kind=='gateway' or kind=='public'
end
local function validate_snapshot(value,selection)
    if type(value)~='table' or value.schema~=1 or not text(value.generation,32) or not value.generation:match('^[a-f0-9]+$')
        or #value.generation~=32 or not integer(value.updated_at,2^53) or value.updated_at==0
        or not array(value.pages,M.MAX_PAGES) or #value.pages==0
        or not valid_source(value.source_kind) then fail() end
    local cursor=selection and selection.cursor
    if selection and not selection.metadata_only and not cursor then
        local newest=value.pages[#value.pages]
        if type(newest)~='table' then fail() end
        cursor=newest.cursor
    end
    local out={schema=1,generation=value.generation,query=M.query(value.query),updated_at=value.updated_at,
        source_kind=value.source_kind,pages={}};local seen={}
    for _,row in ipairs(value.pages) do
        -- Validate every batch even when the caller only needs the query or
        -- the cards for one batch.
        local build_cards=not selection or cursor~=nil and type(row)=='table' and row.cursor==cursor
        local projected=page(row,build_cards);if seen[projected.cursor] then fail() end
        seen[projected.cursor]=true;out.pages[#out.pages+1]=projected
    end
    if not seen[0] then fail() end
    return out
end
function M.validate(value)
    return validate_snapshot(value)
end
-- The caller owns this freshly validated snapshot.
local function restored_state(saved,cursor)
    cursor=cursor or saved.pages[#saved.pages].cursor
    local lookup={};for _,row in ipairs(saved.pages) do lookup[row.cursor]=row end
    local row=lookup[0];local history={}
    while row and row.cursor~=cursor and #history<M.MAX_PAGES do
        if not row.has_more or row.next_cursor<=row.cursor then return nil end
        history[#history+1]=row.cursor;row=lookup[row.next_cursor]
    end
    if not row or row.cursor~=cursor then return nil end
    local result=saved.query
    for key,item in pairs(row) do result[key]=item end
    result.history=history;result.has_more=row.has_more and lookup[row.next_cursor]~=nil
    result.source_kind=saved.source_kind;result.cached=true
    return result
end
function M.state(value,cursor)
    return restored_state(validate_snapshot(value,{cursor=cursor}),cursor)
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
    local ok,result,reference=pcall(function()
        db:exec([[CREATE TABLE IF NOT EXISTS discovery_cache (
            cache_key TEXT PRIMARY KEY,payload TEXT NOT NULL,serial INTEGER NOT NULL
        ); CREATE TABLE IF NOT EXISTS discovery_position (
            id INTEGER PRIMARY KEY CHECK(id=1),cache_key TEXT NOT NULL,serial INTEGER NOT NULL,
            generation TEXT NOT NULL,cursor INTEGER NOT NULL,anchor INTEGER NOT NULL,focus TEXT
        )]])
        local function begin() db:exec('BEGIN IMMEDIATE');transaction=true end
        local function commit() db:exec('COMMIT');transaction=false end
        return task(db,begin,commit)
    end)
    if transaction then pcall(db.exec,db,'ROLLBACK') end
    pcall(db.close,db)
    if ok then return result,reference end
end
function M:new(library,codec) return setmetatable({library=library,codec=codec},self) end
local function read(self,db,key,selection)
    local sql='SELECT CASE WHEN length(CAST(payload AS BLOB))<=? THEN payload ELSE NULL END, cache_key, serial FROM discovery_cache'
    local row
    if key then row=statement(db,sql..' WHERE cache_key=?',M.MAX_PAYLOAD,key)
    else row=statement(db,sql..' ORDER BY serial DESC LIMIT 1',M.MAX_PAYLOAD) end
    if not row or type(row[1])~='string' then return nil end
    local value=validate_snapshot(self.codec:json_decode(row[1]),selection)
    -- Accept the original key for public searches saved by older versions.
    if M.key(value.query,value.source_kind=='public')~=row[2] and M.key(value.query)~=row[2] then fail() end
    return value,{key=row[2],serial=tonumber(row[3]),generation=value.generation}
end
local function search(self,db,query,selection)
    local function get(key)
        local ok,value,reference=pcall(read,self,db,key,selection)
        if ok then return value,reference end
    end
    local standard_key=M.key(query)
    local source=query.source_kind
    local standard,standard_reference
    if not query.public_only and source~='public' then
        standard,standard_reference=get(standard_key)
        if standard and standard.source_kind~='public' and (not source or source==standard.source_kind) then
            return standard,standard_reference
        end
        if source then return nil end
    end
    local public_key=M.key(query,true)
    local public,reference=get(public_key)
    if public then return public,reference end
    if not standard then standard,standard_reference=get(standard_key) end
    if standard and standard.source_kind=='public' then return standard,standard_reference end
end
local function valid_position(anchor,focus)
    return integer(anchor,100) and anchor>=1 and (focus==nil or text(focus,256))
end
local function cached_state(value,reference,cursor)
    local state=value and restored_state(value,cursor)
    if state then state._cache_view=reference end
    return state
end
local function valid_reference(key,generation)
    return type(key)=='string' and #key==64 and key:match('^[a-f0-9]+$')
        and type(generation)=='string' and #generation==32 and generation:match('^[a-f0-9]+$')
end
local function resume(self,db,resolve_public)
    local row=statement(db,[[SELECT cache_key,serial,generation,cursor,anchor,focus
        FROM discovery_position WHERE id=1]])
    if not row or not valid_reference(row[1],row[3]) then return nil end
    local cursor,anchor=tonumber(row[4]),tonumber(row[5])
    if not integer(cursor) or not valid_position(anchor,row[6]) then return nil end
    local serial=tonumber(row[2])
    local state
    if serial==PUBLIC_REFERENCE_SERIAL then
        if resolve_public then state=resolve_public(row[1],row[3],cursor) end
    else
        local value,reference=read(self,db,row[1],{cursor=cursor})
        if reference and reference.serial==serial and reference.generation==row[3] then
            state=cached_state(value,reference,cursor)
        end
    end
    if not state then return nil end
    state._browse_position={anchor=anchor,focus=row[6]}
    state._browse_saved=true
    return state
end
function M:read(query,cursor,resolve_public)
    return run(self,function(db)
        if not query and cursor==nil then
            local ok,state=pcall(resume,self,db,resolve_public)
            if ok and state then return state end
        end
        local value,reference
        local selection={cursor=cursor}
        if query and query.kind=='search' then value,reference=search(self,db,query,selection)
        else value,reference=read(self,db,query and M.key(query),selection) end
        return cached_state(value,reference,cursor)
    end)
end
function M:read_reference(key,generation,cursor)
    if not valid_reference(key,generation) or not integer(cursor) then return nil end
    return run(self,function(db)
        local value,reference=read(self,db,key,{cursor=cursor})
        if reference and reference.generation==generation then return cached_state(value,reference,cursor) end
    end)
end

-- Record the position without rewriting the cached books. A public reference
-- is resolved against the same public generation when the account reopens it.
function M:remember(state,position,shared_public)
    local reference=state._cache_view
    if not reference or not valid_position(position.anchor,position.focus) or not integer(state.cursor) then return false end
    if shared_public and (state.kind~='category' or state.source_kind~='public'
        or not valid_reference(reference.key,reference.generation) or M.key(state)~=reference.key) then return false end
    return run(self,function(db,begin,commit)
        begin()
        local serial=PUBLIC_REFERENCE_SERIAL
        if not shared_public then
            local row=statement(db,'SELECT serial FROM discovery_cache WHERE cache_key=?',reference.key)
            if not row or tonumber(row[1])~=reference.serial then return false end
            serial=reference.serial
        end
        statement(db,[[INSERT INTO discovery_position(id,cache_key,serial,generation,cursor,anchor,focus)
            VALUES(1,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET cache_key=excluded.cache_key,serial=excluded.serial,
            generation=excluded.generation,cursor=excluded.cursor,anchor=excluded.anchor,focus=excluded.focus]],
            reference.key,serial,reference.generation,state.cursor,position.anchor,position.focus)
        commit();return true
    end)
end
local function decode_search(self,payload)
    local value=self.codec:json_decode(payload)
    local query=type(value)=='table' and value.query
    if type(query)=='table' and query.kind=='search' then return validate_snapshot(value,query_metadata) end
end
-- List only validated search queries already stored in this account's cache.
-- Results remain display-only and are reopened with the ordinary cache path.
function M:search_entries()
    return run(self,function(db)
        local stmt=db:prepare([[SELECT CASE WHEN length(CAST(payload AS BLOB))<=? THEN payload ELSE NULL END,
            cache_key FROM discovery_cache ORDER BY serial DESC LIMIT ?]])
        local out,seen={},{}
        local ok,reason=pcall(function()
            local row=stmt:bind(M.MAX_PAYLOAD,M.MAX_QUERIES):step()
            while row do
                if type(row[1])=='string' then
                    local valid,value=pcall(decode_search,self,row[1])
                    if valid and value then
                        local key=M.key(value.query,value.source_kind=='public')
                        if not seen[key] and (key==row[2] or M.key(value.query)==row[2]) then
                            out[#out+1]={keyword=value.query.keyword,generation=value.generation,source_kind=value.source_kind}
                            seen[key]=true
                        end
                    end
                end
                row=stmt:step()
            end
        end)
        stmt:close();if not ok then error(reason,0) end
        return out
    end)
end
function M:searches()
    local entries=self:search_entries()
    if not entries then return nil end
    local out,seen={},{}
    for _,entry in ipairs(entries) do
        if not seen[entry.keyword] then out[#out+1]=entry.keyword;seen[entry.keyword]=true end
    end
    return out
end

-- Delete only the exact generation shown to the user. A refresh from another
-- process must not be removed by a delayed confirmation.
function M:remove_search(keyword,generation,source_kind)
    if type(generation)~='string' or #generation~=32 or not generation:match('^[a-f0-9]+$') then return nil end
    local query={kind='search',keyword=keyword,source_kind=source_kind}
    local valid=pcall(M.query,query)
    if not valid then return nil end
    return run(self,function(db,begin,commit)
        begin()
        local saved,reference=search(self,db,query,query_metadata)
        if not saved or saved.generation~=generation then
            commit();return 'changed'
        end
        statement(db,'DELETE FROM discovery_cache WHERE cache_key=?',reference.key)
        statement(db,'DELETE FROM discovery_position WHERE cache_key=?',reference.key)
        commit();return 'deleted'
    end)
end
function M:write(state,previous,continuation)
    local projected=page(state);local query=M.query(state)
    local public_search=query.kind=='search' and state.source_kind=='public'
    local key=M.key(query,public_search)
    return run(self,function(db,begin,commit)
        begin()
        local saved
        if continuation then
            if not previous or previous.cached or not previous._cache_generation or M.key(previous,previous.source_kind=='public')~=key
                or previous.source_kind~=state.source_kind or previous.source_revision~=state.source_revision then return nil end
            saved=read(self,db,key)
            if not saved or saved.generation~=previous._cache_generation then return nil end
        else
            if projected.cursor~=0 or not valid_source(state.source_kind) then return nil end
            local generation=nonce()
            if not generation then return nil end
            saved={schema=1,generation=generation,source_kind=state.source_kind,pages={}}
            if query.kind=='search' then
                local legacy_key=public_search and M.key(query) or key
                local ok,legacy=pcall(read,self,db,legacy_key)
                if ok and legacy and legacy.source_kind=='public' then
                    if public_search then
                        statement(db,'DELETE FROM discovery_cache WHERE cache_key=?',legacy_key)
                    else
                        statement(db,[[INSERT OR IGNORE INTO discovery_cache(cache_key,payload,serial)
                            SELECT ?,?,serial FROM discovery_cache WHERE cache_key=?]],
                            M.key(query,true),self.codec:json_encode(legacy),legacy_key)
                    end
                end
            end
        end
        -- read() validated all saved pages. The new page and query were
        -- checked separately. Apply the cap after removing any replaced page.
        for i,row in ipairs(saved.pages) do
            if row.cursor==projected.cursor then table.remove(saved.pages,i);break end
        end
        if #saved.pages>=M.MAX_PAGES then return nil end
        -- The newest online batch stays last, as the fallback for older caches.
        saved.pages[#saved.pages+1]=projected
        saved.updated_at=projected.loaded_at;saved.query=query
        local payload=self.codec:json_encode(saved)
        if type(payload)~='string' or #payload>M.MAX_PAYLOAD then return nil end
        local serial=assert(tonumber(statement(db,'SELECT COALESCE(MAX(serial),0)+1 FROM discovery_cache')[1]))
        statement(db,[[INSERT INTO discovery_cache(cache_key,payload,serial) VALUES(?,?,?)
            ON CONFLICT(cache_key) DO UPDATE SET payload=excluded.payload,serial=excluded.serial]],key,payload,serial)
        db:exec('DELETE FROM discovery_position')
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
        commit();return saved.generation,{key=key,serial=serial,generation=saved.generation}
    end)
end
return M
