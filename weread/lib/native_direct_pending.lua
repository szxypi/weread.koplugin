-- Local reminders only: never a grant to send a cloud position.
local P=require('weread.lib.native_position_protocol')
local Contract=require('weread.lib.native_position_contract')
local M={MAX_RECORDS=256}
local function pointer(value)
    return type(value)=='string' and #value>0 and #value<=4096 and not value:find('[%z%c]')
end
local function current(library,settings,scope,guard)
    if type(library)~='table' or type(library.accountKey)~='function' or type(settings)~='table'
        or type(settings.auth_scope_matches)~='function' or type(scope)~='table' or type(guard)~='function' then return false end
    local ok,value=pcall(function()
        return guard()==true and settings:auth_scope_matches(scope)==true
            and library:accountKey()==Contract.account_key(scope.vid)
    end)
    return ok and value==true
end
local function valid_entry(entry,scope)
    return type(scope)=='table' and require('weread.lib.native_direct_cache').valid_entry(entry,entry and entry.book_id,scope.vid)
        and type(entry.file_id)=='string' and #entry.file_id==64 and entry.file_id:match('^[a-f0-9]+$')~=nil
end
local function query(db,sql,...)
    local stmt=db:prepare(sql);local args={...}
    local ok,result=pcall(function()
        if #args>0 then stmt:bind(unpack(args)) end
        local rows={};while true do local row=stmt:step();if not row then break end;rows[#rows+1]=row end
        return rows
    end)
    stmt:close();if not ok then error('native_direct_pending/query',0) end;return result
end
local function schema(db,name)
    local rows=query(db,'SELECT type FROM sqlite_master WHERE name=?',name or 'native_direct_offline_pending')
    return #rows==0 and 'missing' or #rows==1 and rows[1][1]=='table' and 'present' or 'invalid'
end
local display_table='native_direct_offline_display'
local function percentage(value)
    return type(value)=='number' and value>=0 and value<=100
end

local display_query=[[SELECT d.book_id,d.percent FROM native_direct_offline_display d
    JOIN native_direct_offline_pending p ON p.book_id=d.book_id AND p.file_id=d.file_id AND p.xpointer=d.xpointer]]
local display_limit=' LIMIT '..(M.MAX_RECORDS+1)
-- Typical viewports need a few IDs. A whole-shelf sort can use one capped scan.
local DISPLAY_LOOKUP_LIMIT=32

-- An exact join keeps removed or replaced reminders from leaving stale estimates.
function M.display_estimates(db,ids)
    if type(ids)~='table' or #ids==0 then return {} end
    local ok,value=pcall(function()
        if schema(db,display_table)~='present' then return {} end
        local rows
        if #ids<=DISPLAY_LOOKUP_LIMIT then
            local placeholders=string.rep('?,',#ids-1)..'?'
            rows=query(db,display_query..' WHERE d.book_id IN ('..placeholders..')'..display_limit,unpack(ids))
        else
            rows=query(db,display_query..display_limit)
        end
        if #rows==0 or #rows>M.MAX_RECORDS then return {} end
        local wanted={};for _,id in ipairs(ids) do wanted[id]=true end
        local result={}
        for _,row in ipairs(rows) do
            local estimate=tonumber(row[2])
            if wanted[row[1]] and percentage(estimate) then result[row[1]]=estimate end
        end
        return result
    end)
    return ok and value or {}
end

local function save_display(db,entry,xpointer,estimate)
    if percentage(estimate) then
        db:exec([[CREATE TABLE IF NOT EXISTS native_direct_offline_display (
            book_id TEXT PRIMARY KEY NOT NULL,file_id TEXT NOT NULL,xpointer TEXT NOT NULL,percent REAL NOT NULL)]])
        query(db,[[INSERT INTO native_direct_offline_display(book_id,file_id,xpointer,percent) VALUES(?,?,?,?)
            ON CONFLICT(book_id) DO UPDATE SET file_id=excluded.file_id,xpointer=excluded.xpointer,percent=excluded.percent]],
            entry.book_id,entry.file_id,xpointer,estimate)
    elseif schema(db,display_table)=='present' then
        query(db,'DELETE FROM native_direct_offline_display WHERE book_id=?',entry.book_id)
    end
end
local function read_row(db,entry)
    local rows=query(db,[[SELECT book_id,chapter_uid,version,source_sha256,cache_key,copy,xpointer
        FROM native_direct_offline_pending WHERE file_id=?]],entry.file_id)
    if #rows==0 then return nil end
    assert(#rows==1)
    local row=rows[1]
    if row[1]~=entry.book_id or row[2]~=entry.chapter_uid or tonumber(row[3])~=entry.book_version
        or row[4]~=entry.source_sha256 or row[5]~=entry.key or tonumber(row[6])~=entry.copy
        or not pointer(row[7]) then return nil end
    return {file_id=entry.file_id,book_id=entry.book_id,chapter_uid=entry.chapter_uid,
        version=entry.book_version,source_sha256=entry.source_sha256,key=entry.key,copy=entry.copy,xpointer=row[7]}
end
local function same_record(a,b)
    if type(a)~='table' or type(b)~='table' then return false end
    for _,field in ipairs({'file_id','book_id','chapter_uid','version','source_sha256','key','copy','xpointer'}) do
        if a[field]~=b[field] then return false end
    end
    return true
end
function M.read(library,settings,scope,entry,guard)
    if not valid_entry(entry,scope) or not current(library,settings,scope,guard)
        or type(library.openRead)~='function' then return nil end
    local opened,db=pcall(library.openRead,library);if not opened or not db then return nil end
    local ok,result=pcall(function()
        db:exec('PRAGMA busy_timeout=200')
        if schema(db)~='present' then return nil end
        local value=read_row(db,entry)
        if not current(library,settings,scope,guard) then return nil end
        return value
    end)
    pcall(db.close,db);return ok and result or nil
end
-- Decorate saved-chapter candidates only after reopening each matching file.
-- The hint carries no location and grants no sync authority.
function M.mark(library,settings,scope,book,entries,guard)
    local Cache=require('weread.lib.native_direct_cache')
    if type(book)~='string' or P.id(book)~=book or type(entries)~='table' or #entries>Cache.MAX_ENTRIES
        or not current(library,settings,scope,guard) or type(library.openRead)~='function' then return false end
    local opened,db=pcall(library.openRead,library);if not opened or not db then return false end
    local ok,result=pcall(function()
        db:exec('PRAGMA busy_timeout=200')
        if schema(db)~='present' then return {} end
        local rows=query(db,[[SELECT file_id,chapter_uid,version,source_sha256,cache_key,copy,xpointer
            FROM native_direct_offline_pending WHERE book_id=? LIMIT 257]],book)
        assert(#rows<=M.MAX_RECORDS)
        local candidates={}
        for _,row in ipairs(rows) do
            if type(row[5])=='string' and #row[5]==64 and row[5]:match('^[a-f0-9]+$')
                and P.integer(tonumber(row[6]),0,Cache.MAX_COPIES-1) and pointer(row[7]) then
                candidates[row[5]..':'..tostring(tonumber(row[6]))]=row
            end
        end
        local matches={}
        for index,entry in ipairs(entries) do
            assert(Cache.valid_entry(entry,book,scope.vid) and current(library,settings,scope,guard))
            local row=candidates[entry.key..':'..tostring(entry.copy)]
            if row and row[2]==entry.chapter_uid and tonumber(row[3])==entry.book_version
                and row[4]==entry.source_sha256 then
                local file=Cache.open(settings,scope.vid,book,entry,guard)
                if file and file.file_id==row[1] then matches[index]=true end
            end
        end
        assert(current(library,settings,scope,guard))
        return matches
    end)
    pcall(db.close,db)
    if not ok then return false end
    for index in pairs(result) do entries[index].pending_offline=true end
    return true
end
-- expected=nil means the caller observed no prior reminder. An existing row
-- may only be replaced if it still matches the caller's full snapshot.
function M.save(library,settings,scope,entry,xpointer,guard,expected,estimate)
    if not valid_entry(entry,scope) or not pointer(xpointer) or not current(library,settings,scope,guard)
        or type(library.open)~='function' then return false end
    local opened,db=pcall(library.open,library);if not opened or not db then return false end
    local transaction=false
    local ok=pcall(function()
        db:exec('PRAGMA busy_timeout=200');db:exec('PRAGMA synchronous=FULL')
        db:exec([[CREATE TABLE IF NOT EXISTS native_direct_offline_pending (
            file_id TEXT PRIMARY KEY NOT NULL,book_id TEXT NOT NULL,chapter_uid TEXT NOT NULL,version INTEGER NOT NULL,
            source_sha256 TEXT NOT NULL,cache_key TEXT NOT NULL,copy INTEGER NOT NULL,xpointer TEXT NOT NULL)]])
        assert(schema(db)=='present');db:exec('BEGIN IMMEDIATE');transaction=true
        assert(current(library,settings,scope,guard))
        local existing=query(db,'SELECT file_id FROM native_direct_offline_pending WHERE file_id=?',entry.file_id)
        local count=query(db,'SELECT COUNT(*) FROM native_direct_offline_pending')
        assert(#existing<=1 and #count==1 and P.integer(tonumber(count[1][1]),0,M.MAX_RECORDS))
        assert(#existing==1 or tonumber(count[1][1])<M.MAX_RECORDS)
        local previous=#existing==1 and read_row(db,entry) or nil
        assert(#existing==0 and expected==nil or #existing==1 and same_record(previous,expected),
            'existing reminder changed')
        query(db,[[INSERT INTO native_direct_offline_pending(file_id,book_id,chapter_uid,version,source_sha256,cache_key,copy,xpointer)
            VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(file_id) DO UPDATE SET xpointer=excluded.xpointer]],
            entry.file_id,entry.book_id,entry.chapter_uid,entry.book_version,entry.source_sha256,entry.key,entry.copy,xpointer)
        local saved=read_row(db,entry);assert(saved and saved.xpointer==xpointer)
        -- A damaged display table cannot invalidate the offline page reminder.
        pcall(save_display,db,entry,xpointer,estimate)
        assert(current(library,settings,scope,guard));db:exec('COMMIT');transaction=false
    end)
    if transaction then pcall(db.exec,db,'ROLLBACK') end
    pcall(db.close,db);return ok
end
function M.remove(library,settings,scope,entry,record,guard)
    if not valid_entry(entry,scope) or type(record)~='table' or not pointer(record.xpointer)
        or record.file_id~=entry.file_id or record.book_id~=entry.book_id or record.chapter_uid~=entry.chapter_uid
        or record.version~=entry.book_version or record.source_sha256~=entry.source_sha256
        or record.key~=entry.key or record.copy~=entry.copy
        or not current(library,settings,scope,guard) or type(library.open)~='function' then return false end
    local opened,db=pcall(library.open,library);if not opened or not db then return false end
    local transaction=false
    local ok=pcall(function()
        db:exec('PRAGMA busy_timeout=200');db:exec('PRAGMA synchronous=FULL')
        assert(schema(db)=='present');db:exec('BEGIN IMMEDIATE');transaction=true
        assert(current(library,settings,scope,guard))
        local actual=read_row(db,entry)
        assert(actual and actual.xpointer==record.xpointer and actual.file_id==record.file_id)
        query(db,'DELETE FROM native_direct_offline_pending WHERE file_id=? AND xpointer=?',entry.file_id,record.xpointer)
        if schema(db,display_table)=='present' then
            pcall(query,db,'DELETE FROM native_direct_offline_display WHERE book_id=? AND file_id=?',entry.book_id,entry.file_id)
        end
        assert(not read_row(db,entry) and current(library,settings,scope,guard))
        db:exec('COMMIT');transaction=false
    end)
    if transaction then pcall(db.exec,db,'ROLLBACK') end
    pcall(db.close,db);return ok
end
return M
