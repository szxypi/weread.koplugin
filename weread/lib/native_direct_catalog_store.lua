-- Account-bound metadata for the saved chapter outline and local progress.
-- These values never grant cloud position upload authority.
local Crypto=require('weread.lib.crypto')
local Protocol=require('weread.lib.native_position_protocol')
local Cache=require('weread.lib.native_direct_cache')
local M={MAX_CHAPTERS=20000,MAX_BYTES=2*1024*1024,MAX_PER_BOOK=4,MAX_CATALOGS=256}

local function hash(value)
    return type(value)=='string' and #value==64 and value:match('^[a-f0-9]+$')~=nil
end
local function identifier(value)
    return type(value)=='string' and Protocol.id(value)==value
end
local function title(value)
    return type(value)=='string' and #value<=2048 and not value:find('[%z%c]')
        and require('weread.lib.protocol').utf8_substr(value,#value)==value
end
local function scope_current(library,settings,scope,current)
    if type(library)~='table' or type(library.accountKey)~='function' or type(settings)~='table'
        or type(settings.auth_scope_matches)~='function' or type(scope)~='table' or not identifier(scope.vid)
        or type(current)~='function' then return false end
    local ok,value=pcall(function()
        return current()==true and settings:auth_scope_matches(scope)==true
            and library:accountKey()==require('weread.lib.native_position_contract').account_key(scope.vid)
    end)
    return ok and value==true
end
local function compact(catalog)
    if type(catalog)~='table' or not identifier(catalog.book_id) or not hash(catalog.reading_digest)
        or not Protocol.integer(catalog.version,0,2147483647) or type(catalog.chapters)~='table' then return nil end
    local count=#catalog.chapters
    if count<1 or count>M.MAX_CHAPTERS then return nil end
    local n=0
    for key in pairs(catalog.chapters) do
        if not Protocol.integer(key,1,count) then return nil end;n=n+1
    end
    if n~=count then return nil end
    local rows,seen,total={},{},0
    local all_levels,all_words,hierarchy=true,true,false
    for index,row in ipairs(catalog.chapters) do
        if type(row)~='table' or not identifier(row.chapterUid) or seen[row.chapterUid]
            or row.wordCountKnown==true and not Protocol.integer(row.wordCount,0,100000000)
            or row.level~=nil and not Protocol.integer(row.level,0,100) then return nil end
        local words=row.wordCountKnown==true and row.wordCount or nil
        all_words=all_words and words~=nil
        all_levels=all_levels and row.level~=nil
        seen[row.chapterUid]=true;total=total+(words or 0)
        rows[index]={uid=row.chapterUid,words=words}
    end
    if all_levels then
        for index,row in ipairs(catalog.chapters) do
            local following=catalog.chapters[index+1]
            if following and following.level>row.level then
                if not title(row.title) then return nil end
                hierarchy=true
                rows[index].title=row.title
            end
        end
    end
    if hierarchy then
        for index,row in ipairs(catalog.chapters) do rows[index].level=row.level end
    elseif not all_words or total<=0 then return nil end
    return {schema=hierarchy and 2 or 1,book_id=catalog.book_id,version=catalog.version,
        digest=catalog.reading_digest,chapters=rows}
end
M.compact=compact
local function valid(value)
    if type(value)~='table' or value.schema~=1 and value.schema~=2 or not identifier(value.book_id) or not hash(value.digest)
        or not Protocol.integer(value.version,0,2147483647) or type(value.chapters)~='table' then return false end
    for key in pairs(value) do
        if key~='schema' and key~='book_id' and key~='version' and key~='digest' and key~='chapters' then return false end
    end
    local count=#value.chapters
    if count<1 or count>M.MAX_CHAPTERS then return false end
    local n=0;for key in pairs(value.chapters) do if not Protocol.integer(key,1,count) then return false end;n=n+1 end
    if n~=count then return false end
    local seen,total,hierarchy={},0,false
    local outline=value.schema==2
    for _,row in ipairs(value.chapters) do
        if type(row)~='table' or not identifier(row.uid) or seen[row.uid]
            or (not outline or row.words~=nil) and not Protocol.integer(row.words,0,100000000)
            or outline and not Protocol.integer(row.level,0,100) then return false end
        for key in pairs(row) do
            if key~='uid' and key~='words' and not (outline and (key=='level' or key=='title')) then return false end
        end
        seen[row.uid]=true;total=total+(row.words or 0)
    end
    if not outline then return total>0 end
    for index,row in ipairs(value.chapters) do
        local following=value.chapters[index+1]
        if following and following.level>row.level then
            if not title(row.title) then return false end
            hierarchy=true
        elseif row.title~=nil then return false end
    end
    return hierarchy
end
local function matches(value,entry)
    if type(entry)~='table' or entry.book_id~=value.book_id
        or entry.book_version~=value.version or entry.catalog_sha256~=value.digest
        or entry.catalog_count~=#value.chapters or not Protocol.integer(entry.catalog_order,1,#value.chapters) then return false end
    local index=entry.catalog_order;local row=value.chapters[index]
    return row.uid==entry.chapter_uid
        and (index==1 and entry.catalog_prev==nil or index>1 and entry.catalog_prev==value.chapters[index-1].uid)
        and (index==#value.chapters and entry.catalog_next==nil
            or index<#value.chapters and entry.catalog_next==value.chapters[index+1].uid)
end
function M.matches(value,entry)
    return valid(value) and matches(value,entry)
end
-- Retain original ordinals only for references that match the whole catalog.
function M.saved_orders(value,entries)
    if not valid(value) or value.schema~=2 then return nil end
    local orders={}
    for index,entry in ipairs(entries) do
        if matches(value,entry) then orders[index]=entry.catalog_order end
    end
    return next(orders) and orders or nil
end
function M.weights(value,entry)
    if not M.matches(value,entry) then return nil end
    local before,total,current=0,0,nil
    for index,row in ipairs(value.chapters) do
        if row.words==nil then return nil end
        total=total+row.words
        if index<entry.catalog_order then before=before+row.words end
        if index==entry.catalog_order then current=row.words end
    end
    if not current or current==0 or total==0 then return nil end
    return {before=before,chapter=current,total=total}
end
function M.estimate(value,entry,percent)
    if type(percent)~='number' or not (percent>=0 and percent<=100) then return nil end
    local weights=M.weights(value,entry)
    return weights and (weights.before+weights.chapter*percent/100)/weights.total*100 or nil
end
local function query(db,sql,...)
    local statement=db:prepare(sql);local args={...}
    local ok,rows=pcall(function()
        if #args>0 then statement:bind(unpack(args)) end
        local result={};while true do local row=statement:step();if not row then break end;result[#result+1]=row end
        return result
    end)
    statement:close();if not ok then error('native_catalog_store/query',0) end;return rows
end
function M.save(library,settings,codec,scope,catalog,current)
    local snapshot=compact(catalog)
    if not snapshot or not scope_current(library,settings,scope,current) or type(library.open)~='function'
        or type(codec)~='table' or type(codec.json_encode)~='function' then return false end
    local encoded,raw=pcall(codec.json_encode,codec,snapshot)
    if not encoded or type(raw)~='string' or #raw<1 or #raw>M.MAX_BYTES then return false end
    local opened,db=pcall(library.open,library);if not opened or not db then return false end
    local transaction=false
    local ok=pcall(function()
        db:exec('PRAGMA busy_timeout=200')
        db:exec([[CREATE TABLE IF NOT EXISTS native_direct_catalog_estimate (
            book_id TEXT NOT NULL,digest TEXT NOT NULL,version INTEGER NOT NULL,payload TEXT NOT NULL,
            payload_sha256 TEXT NOT NULL,serial INTEGER NOT NULL,PRIMARY KEY(book_id,digest))]])
        db:exec('BEGIN IMMEDIATE');transaction=true
        assert(scope_current(library,settings,scope,current))
        local serial=tonumber(query(db,'SELECT COALESCE(MAX(serial),0) FROM native_direct_catalog_estimate')[1][1])
        assert(Protocol.integer(serial,0,9007199254740989))
        query(db,[[INSERT INTO native_direct_catalog_estimate(book_id,digest,version,payload,payload_sha256,serial)
            VALUES(?,?,?,?,?,?) ON CONFLICT(book_id,digest) DO UPDATE SET version=excluded.version,
            payload=excluded.payload,payload_sha256=excluded.payload_sha256,serial=excluded.serial]],
            snapshot.book_id,snapshot.digest,snapshot.version,raw,Crypto.sha256_hex(raw),serial+1)
        query(db,[[DELETE FROM native_direct_catalog_estimate WHERE book_id=? AND digest NOT IN
            (SELECT digest FROM native_direct_catalog_estimate WHERE book_id=? ORDER BY serial DESC LIMIT 4)]],snapshot.book_id,snapshot.book_id)
        db:exec('DELETE FROM native_direct_catalog_estimate WHERE rowid NOT IN (SELECT rowid FROM native_direct_catalog_estimate ORDER BY serial DESC LIMIT 256)')
        assert(scope_current(library,settings,scope,current))
        db:exec('COMMIT');transaction=false
    end)
    if transaction then pcall(db.exec,db,'ROLLBACK') end
    pcall(db.close,db)
    return ok
end
function M.read(library,settings,codec,scope,entry,current)
    if not scope_current(library,settings,scope,current) or type(library.openRead)~='function'
        or type(codec)~='table' or type(codec.json_decode)~='function'
        or not Cache.valid_entry(entry,entry and entry.book_id,scope.vid) or not entry.catalog_sha256 then return nil end
    local opened,db=pcall(library.openRead,library);if not opened or not db then return nil end
    local ok,result=pcall(function()
        db:exec('PRAGMA busy_timeout=200')
        local schema=query(db,"SELECT type FROM sqlite_master WHERE name='native_direct_catalog_estimate'")
        if #schema~=1 or schema[1][1]~='table' then return nil end
        local rows=query(db,[[SELECT CASE WHEN length(CAST(payload AS BLOB))<=? THEN payload ELSE NULL END,payload_sha256
            FROM native_direct_catalog_estimate WHERE book_id=? AND digest=? AND version=?]],
            M.MAX_BYTES,entry.book_id,entry.catalog_sha256,entry.book_version)
        if #rows~=1 or type(rows[1][1])~='string' or not hash(rows[1][2])
            or Crypto.sha256_hex(rows[1][1])~=rows[1][2] then return nil end
        local decoded,value=pcall(codec.json_decode,codec,rows[1][1])
        if not decoded or not M.matches(value,entry) or not scope_current(library,settings,scope,current) then return nil end
        return value
    end)
    pcall(db.close,db)
    return ok and result or nil
end
return M
