-- SQLite-backed offline index for shelf entries, book details, and catalogs.
-- Downloaded EPUB/HTML files remain in the ordinary cache directory; this
-- database only stores small, queryable metadata needed to browse offline.

local logger = require("weread.lib.logger")
local Crypto = require("weread.lib.crypto")
local ShelfSnapshot = require("weread.lib.shelf_snapshot")
local BookStore = require("weread.lib.book_store")

local ok_json, json = pcall(require, "json")
if not ok_json then
    ok_json, json = pcall(require, "rapidjson")
end

local LibraryDB = {}
LibraryDB.__index = LibraryDB

local function getSQ3()
    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    return ok and SQ3 or nil
end

local function encode(value)
    if not ok_json then return nil, "JSON module is not available" end
    local ok, result = pcall(function()
        return json.encode and json.encode(value) or json:encode(value)
    end)
    return ok and result or nil, ok and nil or result
end

local function decode(value)
    if type(value) ~= "string" or value == "" or not ok_json then return nil end
    local ok, result = pcall(function()
        return json.decode and json.decode(value) or json:decode(value)
    end)
    return ok and type(result) == "table" and result or nil
end

local function copy(value)
    local result={};for key,item in pairs(value) do result[key]=item end
    local mt=getmetatable(value);if type(mt)=='table' then setmetatable(result,mt) end
    return result
end

-- Older caches retained the exact book identity in the SQLite primary key,
-- while their JSON numeric field could have lost digits during serialization.
local function shelf_book(value, key)
    if type(value)~='table' or type(key)~='string' or not ShelfSnapshot.identity(key) then return nil end
    local seen=false
    for _,field in ipairs({'book_id','bookId'}) do
        local id=value[field]
        if id~=nil then
            seen=true
            if type(id)=='number' then
                local number=tonumber(key)
                if not number or not ShelfSnapshot.identity(id) or ShelfSnapshot.identity(number)~=key then return nil end
                local expected,actual=encode(number),encode(id)
                if type(expected)~='string' or expected~=actual then return nil end
                value[field]=key
            elseif ShelfSnapshot.identity(id)~=key then return nil end
        end
    end
    return seen and value or nil
end

local function shelf_archives(archives)
    if type(archives)~='table' then return archives end
    local result=copy(archives)
    for i,archive in ipairs(archives) do
        if type(archive)~='table' then return nil end
        local row=copy(archive)
        for _,key in ipairs({'archiveId','archive_id','id'}) do
            if type(row[key])=='number' then
                row[key]=ShelfSnapshot.identity(row[key]);if not row[key] then return nil end
            end
        end
        if type(row.bookIds)=='table' then
            row.bookIds=copy(row.bookIds)
            for index,id in ipairs(row.bookIds) do
                if type(id)=='number' then
                    row.bookIds[index]=ShelfSnapshot.identity(id);if not row.bookIds[index] then return nil end
                end
            end
        end
        result[i]=row
    end
    return result
end

local function close_statement(stmt)
    if stmt then pcall(function() stmt:close() end) end
end

function LibraryDB:new(settings)
    local data_dir = settings.data_dir or settings.cache_dir or "."
    return setmetatable({
        settings = settings,
        data_dir = data_dir,
    }, self)
end

-- The hash keeps the user VID out of filenames while giving each login a
-- stable database that can be reused when the user switches back.
function LibraryDB:accountKey()
    local account = self.settings:get("account", {})
    local user_vid = type(account) == "table" and account.user_vid or nil
    if user_vid == nil or tostring(user_vid) == "" then return nil end
    return string.sub(Crypto.sha256_hex("weread-library:" .. tostring(user_vid)), 1, 20)
end

function LibraryDB:databasePath()
    local account_key = self:accountKey()
    if not account_key then return nil end
    return self.data_dir .. "/library-" .. account_key .. ".db"
end

function LibraryDB:open()
    local path = self:databasePath()
    if not path then
        logger.info("library_db skipped without an identified account")
        return nil
    end
    local SQ3 = getSQ3()
    if not SQ3 then
        logger.warn("library_db lua-ljsqlite3 unavailable")
        return nil
    end
    local ok, db = pcall(SQ3.open, path)
    if not ok or not db then
        logger.warn("library_db open failed:", path, db)
        return nil
    end
    local schema_ok, schema_err = pcall(function()
        db:exec("PRAGMA journal_mode=WAL")
        db:exec("PRAGMA synchronous=NORMAL")
        db:exec([[
            CREATE TABLE IF NOT EXISTS books (
                book_id           TEXT PRIMARY KEY,
                kind              TEXT NOT NULL DEFAULT 'book',
                payload           TEXT NOT NULL,
                on_shelf          INTEGER NOT NULL DEFAULT 0,
                shelf_position    INTEGER,
                shelf_updated_at  INTEGER,
                detail_updated_at INTEGER,
                detail_payload    TEXT
            ) WITHOUT ROWID
        ]])
        db:exec([[
            CREATE TABLE IF NOT EXISTS chapters (
                book_id      TEXT NOT NULL,
                chapter_uid  TEXT NOT NULL,
                position     INTEGER NOT NULL,
                payload      TEXT NOT NULL,
                updated_at   INTEGER NOT NULL,
                PRIMARY KEY (book_id, chapter_uid)
            ) WITHOUT ROWID
        ]])
        db:exec([[
            CREATE TABLE IF NOT EXISTS shelf_state (
                name TEXT PRIMARY KEY,
                payload TEXT NOT NULL
            ) WITHOUT ROWID
        ]])
        -- Adds the richer detail snapshot for databases created by an early
        -- development build. Duplicate-column errors are intentionally ignored.
        pcall(function() db:exec("ALTER TABLE books ADD COLUMN detail_payload TEXT") end)
        db:exec("CREATE INDEX IF NOT EXISTS chapters_position ON chapters(book_id, position)")
        db:exec([[
            CREATE TABLE IF NOT EXISTS shelf_progress (
                book_id TEXT PRIMARY KEY,
                payload TEXT NOT NULL
            ) WITHOUT ROWID
        ]])
        db:exec([[
            CREATE TABLE IF NOT EXISTS profile_state (
                name TEXT PRIMARY KEY,
                payload TEXT NOT NULL
            ) WITHOUT ROWID
        ]])
    end)
    if not schema_ok then
        logger.warn("library_db schema init failed:", schema_err)
        pcall(function() db:close() end)
        return nil
    end
    return db
end

-- Cached reads must not try to initialize or change the journal mode.
-- An existing database can be readable while another connection prevents a
-- WAL migration; treating that as a missing catalog breaks reader recovery.
function LibraryDB:openRead()
    local path = self:databasePath()
    local SQ3 = path and getSQ3()
    if not SQ3 then return nil end
    local ok, db = pcall(SQ3.open, path, "ro")
    return ok and db or nil
end

function LibraryDB:cacheShelf(books, archives)
    local snapshot = ShelfSnapshot.metadata(books, os.time())
    if not snapshot then return false end
    local db = self:open()
    if not db or type(books) ~= "table" then return false end
    local transaction_open = false
    local stmt
    local ok, err = pcall(function()
        db:exec("BEGIN")
        transaction_open = true
        db:exec("UPDATE books SET on_shelf=0, shelf_position=NULL")
        stmt = db:prepare([[
            INSERT INTO books
                (book_id, kind, payload, on_shelf, shelf_position, shelf_updated_at)
            VALUES (?, ?, ?, 1, ?, ?)
            ON CONFLICT(book_id) DO UPDATE SET
                kind=excluded.kind,
                payload=excluded.payload,
                on_shelf=1,
                shelf_position=excluded.shelf_position,
                shelf_updated_at=excluded.shelf_updated_at
        ]])
        local now = snapshot.cached_at
        for position, book in ipairs(books) do
            local book_id = ShelfSnapshot.id(book)
            local stored=copy(book)
            if type(stored.book_id)=='number' then stored.book_id=book_id end
            if type(stored.bookId)=='number' then stored.bookId=book_id end
            local payload, encode_err = encode(stored)
            if type(payload) ~= "string" then error(encode_err or "invalid shelf payload") end
            local kind = book_id:match("^MP_WXS_") and "mp" or "book"
            stmt:reset():bind(book_id, kind, payload, position, now):step()
        end
        close_statement(stmt)
        stmt = nil
        -- Keep groups and their membership in the same snapshot as the books.
        if archives ~= nil then
            local stored=shelf_archives(archives)
            if not stored then error('invalid shelf archive identity') end
            local payload, encode_err = encode(stored)
            if not payload then error(encode_err) end
            stmt = db:prepare([[
                INSERT INTO shelf_state (name, payload) VALUES ('archives', ?)
                ON CONFLICT(name) DO UPDATE SET payload=excluded.payload
            ]])
            stmt:reset():bind(payload):step()
            close_statement(stmt)
            stmt = nil
        end
        local payload, encode_err = encode(snapshot)
        if not payload then error(encode_err) end
        stmt = db:prepare([[
            INSERT INTO shelf_state (name, payload) VALUES ('membership_snapshot', ?)
            ON CONFLICT(name) DO UPDATE SET payload=excluded.payload
        ]])
        stmt:bind(payload):step()
        close_statement(stmt)
        stmt = nil
        db:exec("COMMIT")
        transaction_open = false
    end)
    close_statement(stmt)
    if not ok and transaction_open then pcall(function() db:exec("ROLLBACK") end) end
    pcall(function() db:close() end)
    if not ok then logger.warn("library_db shelf write failed:", err) end
    return ok
end

local function read_shelf_archives(db)
    local stmt, archives
    local ok = pcall(function()
        stmt = db:prepare("SELECT payload FROM shelf_state WHERE name='archives'")
        local row = stmt:reset():step()
        archives = row and decode(row[1]) or nil
    end)
    close_statement(stmt)
    return ok and archives or nil
end

local function read_shelf_books(db)
    local books = {}
    local stmt
    local ok = pcall(function()
        stmt = db:prepare([[
            SELECT book_id, payload FROM books
            WHERE on_shelf=1
            ORDER BY shelf_position, book_id
        ]])
        local row = stmt:reset():step()
        while row do
            local book = shelf_book(decode(row[2]),row[1])
            if not book then error('invalid shelf book identity') end
            books[#books + 1] = book
            row = stmt:step()
        end
    end)
    close_statement(stmt)
    return ok and books or nil
end

function LibraryDB:getShelfArchives()
    local db = self:openRead()
    if not db then return nil end
    local archives = read_shelf_archives(db)
    pcall(function() db:close() end)
    return archives
end

function LibraryDB:getShelf()
    local db = self:openRead()
    if not db then return nil end
    local books = read_shelf_books(db)
    pcall(function() db:close() end)
    return books
end

local function read_shelf_preferences(db, account)
    local stmt, values = nil, {}
    local ok = pcall(function()
        stmt = db:prepare([[
            SELECT name, payload FROM profile_state
            WHERE name IN ('shelf_multi_groups_v1', 'shelf_local_groups_v1', 'shelf_local_pins_v1')
        ]])
        local row = stmt:reset():step()
        while row do
            values[row[1]] = decode(row[2])
            row = stmt:step()
        end
    end)
    close_statement(stmt)
    if ok then return { account = account, values = values } end
end

function LibraryDB:getShelfSnapshot(with_preferences)
    local account = with_preferences and self:accountKey()
    local db = self:openRead()
    if not db then return nil, nil end
    local ok, books, archives, preferences = pcall(function()
        -- Retain the same read generation if a sync commits between queries.
        db:exec('BEGIN')
        local rows = read_shelf_books(db)
        local groups = read_shelf_archives(db)
        local profile = account and read_shelf_preferences(db, account)
        db:exec('COMMIT')
        return rows, groups, profile
    end)
    pcall(function() db:close() end)
    if ok and (not account or self:accountKey() == account) then return books, archives, preferences end
    return nil, nil
end

function LibraryDB:getShelfPreferences()
    local account = self:accountKey()
    if not account then return nil end
    local db = self:openRead()
    if not db then return nil end
    local preferences = read_shelf_preferences(db, account)
    pcall(function() db:close() end)
    if self:accountKey() == account then return preferences end
end

function LibraryDB:getProfileState(name)
    local db = self:openRead()
    if not db then return nil end
    local stmt, result
    local ok = pcall(function()
        stmt = db:prepare("SELECT payload FROM profile_state WHERE name=?")
        local row = stmt:reset():bind(name):step()
        result = row and decode(row[1])
    end)
    close_statement(stmt)
    pcall(function() db:close() end)
    return ok and result or nil
end

-- Reading the overview together avoids multiple opens and keeps the values
-- on the same account snapshot. The home clock has no use for the nickname.
local function read_profile_overview(self, with_name)
    local db = self:openRead()
    if not db then return nil, nil, nil end
    local stmt, statistics, goal, account_name
    local ok = pcall(function()
        local keys = with_name and "('statistics', 'goal', 'account_name')" or "('statistics', 'goal')"
        stmt = db:prepare("SELECT name, payload FROM profile_state WHERE name IN " .. keys)
        local row = stmt:reset():step()
        while row do
            if row[1] == 'statistics' then statistics = decode(row[2])
            elseif row[1] == 'goal' then goal = decode(row[2])
            elseif row[1] == 'account_name' then account_name = decode(row[2]) end
            row = stmt:step()
        end
    end)
    close_statement(stmt)
    pcall(function() db:close() end)
    if not ok then return nil, nil, nil end
    return statistics, goal, account_name
end

function LibraryDB:getHomeProfileState()
    local statistics, goal = read_profile_overview(self, false)
    return statistics, goal
end

function LibraryDB:getProfileOverview()
    return read_profile_overview(self, true)
end

function LibraryDB:putProfileState(name, value)
    local payload = encode(value)
    if not payload then return false end
    local db = self:open()
    if not db then return false end
    local stmt
    local ok = pcall(function()
        stmt = db:prepare([[
            INSERT INTO profile_state (name, payload) VALUES (?, ?)
            ON CONFLICT(name) DO UPDATE SET payload=excluded.payload
        ]])
        stmt:reset():bind(name, payload):step()
    end)
    close_statement(stmt)
    pcall(function() db:close() end)
    return ok
end

-- Replace only the state the caller actually reviewed. A corrupt existing
-- row is never treated as an absent row, and the account is checked again
-- before commit. This is for local metadata, not cloud mutations.
function LibraryDB:compareProfileState(name, expected, value)
    if type(name)~='string' or name=='' or expected~=nil and type(expected)~='table' or type(value)~='table' then return false end
    local account=self:accountKey();local payload=encode(value)
    if not account or not payload then return false end
    local function equal(a,b)
        if type(a)~=type(b) then return false end
        if type(a)~='table' then return a==b end
        for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
        for k in pairs(b) do if a[k]==nil then return false end end
        return true
    end
    local db=self:open();if not db then return false end
    local stmt,transaction,changed
    local ok=pcall(function()
        assert(self:accountKey()==account)
        db:exec('BEGIN IMMEDIATE');transaction=true
        stmt=db:prepare('SELECT payload FROM profile_state WHERE name=?')
        local row=stmt:reset():bind(name):step();local previous=row and decode(row[1])
        close_statement(stmt);stmt=nil
        if (not row and expected==nil) or (row and type(previous)=='table' and expected~=nil and equal(previous,expected)) then
            stmt=db:prepare('INSERT INTO profile_state (name,payload) VALUES (?,?) ON CONFLICT(name) DO UPDATE SET payload=excluded.payload')
            stmt:reset():bind(name,payload):step();close_statement(stmt);stmt=nil;changed=true
        end
        assert(self:accountKey()==account)
        db:exec('COMMIT');transaction=false
    end)
    close_statement(stmt)
    if transaction then pcall(function() db:exec('ROLLBACK') end) end
    pcall(function() db:close() end)
    return ok and changed==true
end

-- Delete only the exact profile value the user reviewed. The immediate
-- transaction prevents a concurrent update from being removed accidentally.
function LibraryDB:deleteProfileStateIf(name, expected)
    if type(name)~='string' or name=='' or type(expected)~='table' then return false end
    local function equal(a,b)
        if type(a)~=type(b) then return false end
        if type(a)~='table' then return a==b end
        for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
        for k in pairs(b) do if a[k]==nil then return false end end
        return true
    end
    local db=self:open();if not db then return false end
    local stmt,transaction,removed
    local ok=pcall(function()
        db:exec('BEGIN IMMEDIATE');transaction=true
        stmt=db:prepare('SELECT payload FROM profile_state WHERE name=?')
        local row=stmt:reset():bind(name):step()
        local payload=row and row[1];local value=payload and decode(payload)
        close_statement(stmt);stmt=nil
        if type(value)=='table' and equal(value,expected) then
            stmt=db:prepare('DELETE FROM profile_state WHERE name=? AND payload=?')
            stmt:reset():bind(name,payload):step();close_statement(stmt);stmt=nil;removed=true
        end
        db:exec('COMMIT');transaction=false
    end)
    close_statement(stmt)
    if transaction then pcall(function() db:exec('ROLLBACK') end) end
    pcall(function() db:close() end)
    return ok and removed==true
end

local PROGRESS_QUERY_BATCH = 256

function LibraryDB:getShelfProgress(ids)
    local result = {}
    if type(ids) ~= "table" or #ids == 0 then return result end
    local db = self:openRead()
    if not db then return result end
    local stmt, statement_size
    local function read_batch(batch)
        if statement_size ~= #batch then
            close_statement(stmt)
            stmt = nil
            -- Keep the number of parameters bounded on older SQLite builds.
            local placeholders = string.rep('?,', #batch - 1) .. '?'
            stmt = db:prepare('SELECT book_id, payload FROM shelf_progress WHERE book_id IN (' .. placeholders .. ')')
            statement_size = #batch
        end
        local row = stmt:reset():bind(unpack(batch)):step()
        while row do
            result[row[1]] = decode(row[2])
            row = stmt:step()
        end
    end
    local ok = pcall(function()
        -- All batches must see the same progress when a refresh writes in
        -- parallel. A single SELECT already has a consistent read snapshot.
        local multi_batch = #ids > PROGRESS_QUERY_BATCH
        if multi_batch then db:exec('BEGIN') end
        local batch = {}
        for _, id in ipairs(ids) do
            batch[#batch + 1] = tostring(id)
            if #batch == PROGRESS_QUERY_BATCH then
                read_batch(batch)
                batch = {}
            end
        end
        if #batch > 0 then read_batch(batch) end
        if multi_batch then db:exec('COMMIT') end
    end)
    close_statement(stmt)
    pcall(function() db:close() end)
    return ok and result or {}
end

local function prefer_summary(incoming, previous)
    if not incoming.updated_at then return false end
    if not previous or previous.book_id ~= incoming.book_id then return true end
    local observed = tonumber(previous.fetched_at) or 0
    if observed > incoming.fetched_at then return false end
    local updated = tonumber(previous.updated_at)
    local previous_percent = tonumber(previous.exact_percent) or tonumber(previous.percent)
    if updated then
        return incoming.updated_at > updated
            or incoming.updated_at == updated and incoming.exact_percent == previous_percent
    end
    -- A legacy per-book observation may know more than an older summary.
    return incoming.updated_at > observed or incoming.exact_percent == previous_percent
end

function LibraryDB:putShelfProgress(snapshots, merge_summary)
    if type(snapshots) ~= "table" or #snapshots == 0 then return false end
    local db = self:open()
    if not db then return false end
    local stmt, read, transaction_open
    local stored = merge_summary and {} or nil
    local ok = pcall(function()
        db:exec(merge_summary and "BEGIN IMMEDIATE" or "BEGIN")
        transaction_open = true
        if merge_summary then read = db:prepare("SELECT payload FROM shelf_progress WHERE book_id=?") end
        stmt = db:prepare([[
            INSERT INTO shelf_progress (book_id, payload) VALUES (?, ?)
            ON CONFLICT(book_id) DO UPDATE SET payload=excluded.payload
        ]])
        for _, snapshot in ipairs(snapshots) do
            local id = tostring(assert(snapshot.book_id))
            local previous = read and read:reset():bind(id):step()
            if not merge_summary or prefer_summary(snapshot, previous and decode(previous[1])) then
                local payload = assert(encode(snapshot))
                stmt:reset():bind(id, payload):step()
                if stored then stored[id] = true end
            end
        end
        close_statement(read); read = nil
        db:exec("COMMIT")
        transaction_open = false
    end)
    close_statement(read)
    close_statement(stmt)
    if not ok and transaction_open then pcall(function() db:exec("ROLLBACK") end) end
    pcall(function() db:close() end)
    return ok, ok and stored or nil
end

function LibraryDB:putBook(book)
    if type(book) ~= "table" then return false end
    local book_id = ShelfSnapshot.id(book)
    if not book_id then return false end
    local stored=BookStore.without_reading_state(book)
    if type(stored.book_id)=='number' then stored.book_id=book_id end
    if type(stored.bookId)=='number' then stored.bookId=book_id end
    local payload = encode(stored)
    if not payload then return false end
    local db = self:open()
    if not db then return false end
    local stmt
    local ok, err = pcall(function()
        stmt = db:prepare([[
            INSERT INTO books
                (book_id, kind, payload, detail_payload, detail_updated_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(book_id) DO UPDATE SET
                kind=excluded.kind,
                detail_payload=excluded.detail_payload,
                detail_updated_at=excluded.detail_updated_at
        ]])
        local kind = tostring(book_id):match("^MP_WXS_") and "mp" or "book"
        stmt:reset():bind(tostring(book_id), kind, payload, payload, os.time()):step()
    end)
    close_statement(stmt)
    pcall(function() db:close() end)
    if not ok then logger.warn("library_db book write failed:", err) end
    return ok
end

function LibraryDB:getBook(book_id)
    book_id=ShelfSnapshot.identity(book_id)
    if not book_id then return nil end
    local db = self:openRead()
    if not db then return nil end
    local stmt
    local result
    local ok = pcall(function()
        local prepared, value = pcall(db.prepare, db, "SELECT COALESCE(detail_payload, payload) FROM books WHERE book_id=?")
        if prepared then
            stmt = value
        else
            -- An early schema has only payload. Check the actual columns before
            -- falling back, so other query errors never select stale details.
            local columns = db:prepare("PRAGMA table_info(books)")
            local has_payload, has_detail = false, false
            local columns_ok = pcall(function()
                local column = columns:step()
                while column do
                    if column[2] == 'payload' then has_payload = true end
                    if column[2] == 'detail_payload' then has_detail = true end
                    column = columns:step()
                end
            end)
            close_statement(columns)
            assert(columns_ok and has_payload and not has_detail, 'library_db/book_schema')
            stmt = db:prepare("SELECT payload FROM books WHERE book_id=?")
        end
        local row = stmt:reset():bind(book_id):step()
        local decoded = row and shelf_book(decode(row[1]),book_id) or nil
        -- Older detail rows may contain a checkpoint copied before a sync.
        -- Filter on read as well, without rewriting those legacy rows.
        result = decoded and BookStore.without_reading_state(decoded) or nil
    end)
    close_statement(stmt)
    pcall(function() db:close() end)
    return ok and result or nil
end

-- A shelf state must come from the last account shelf snapshot, never an old
-- detail payload. Opening a book/refreshing its metadata cannot change it.
function LibraryDB:getShelfEntry(book_id)
    if type(book_id)~='string' or book_id=='' or #book_id>256 or book_id:find('[%z%c]') then return nil end
    local db=self:openRead()
    if not db then return nil end
    local stmt,result
    local ok=pcall(function()
        stmt=db:prepare([[SELECT CASE WHEN length(CAST(payload AS BLOB))<=262144 THEN payload ELSE NULL END,
            shelf_updated_at FROM books WHERE book_id=? AND on_shelf=1]])
        local row=stmt:bind(book_id):step()
        local book=row and shelf_book(decode(row[1]),book_id)
        if not book then return end
        result={book=book,cached_at=tonumber(row[2]) or 0}
    end)
    close_statement(stmt);pcall(function() db:close() end)
    return ok and result or nil
end

-- Membership and flags share one SQLite read snapshot. An absent row only
-- means "not on shelf" when a complete validated list was committed with it.
function LibraryDB:getShelfStatus(book_id)
    if not ShelfSnapshot.id({bookId=book_id}) or type(book_id)~='string' then return nil end
    local db=self:openRead()
    if not db then return nil end
    local stmt,result
    local ok=pcall(function()
        stmt=db:prepare([[SELECT
            (SELECT CASE WHEN length(CAST(payload AS BLOB))<=4096 THEN payload ELSE '' END
                FROM shelf_state WHERE name='membership_snapshot'),
            (SELECT COUNT(*) FROM books WHERE on_shelf=1),
            b.on_shelf,b.shelf_updated_at,
            CASE WHEN length(CAST(b.payload AS BLOB))<=262144 THEN b.payload ELSE NULL END
            FROM (SELECT 1) AS singleton LEFT JOIN books AS b ON b.book_id=?]])
        local row=stmt:bind(book_id):step()
        if not row then return end
        local present,stamp=ShelfSnapshot.state(decode(row[1]),tonumber(row[2]),
            tonumber(row[3]),tonumber(row[4]),row[1]==nil)
        local book=tonumber(row[3])==1 and shelf_book(decode(row[5]),book_id) or nil
        result={present=present,cached_at=stamp or (book and tonumber(row[4])),book=book}
    end)
    close_statement(stmt);pcall(function() db:close() end)
    return ok and result or nil
end

function LibraryDB:putChapters(book_id, chapters)
    if not book_id or type(chapters) ~= "table" then return false end
    local db = self:open()
    if not db then return false end
    local transaction_open = false
    local stmt
    local ok, err = pcall(function()
        db:exec("BEGIN")
        transaction_open = true
        local delete_stmt = db:prepare("DELETE FROM chapters WHERE book_id=?")
        delete_stmt:reset():bind(tostring(book_id)):step()
        delete_stmt:close()
        stmt = db:prepare([[
            INSERT INTO chapters (book_id, chapter_uid, position, payload, updated_at)
            VALUES (?, ?, ?, ?, ?)
        ]])
        local now = os.time()
        for position, chapter in ipairs(chapters) do
            local uid = chapter.chapterUid or chapter.chapterId or position
            local payload, encode_err = encode(chapter)
            if payload then
                stmt:reset():bind(tostring(book_id), tostring(uid), position, payload, now):step()
            else
                error(encode_err)
            end
        end
        close_statement(stmt)
        stmt = nil
        db:exec("COMMIT")
        transaction_open = false
    end)
    close_statement(stmt)
    if not ok and transaction_open then pcall(function() db:exec("ROLLBACK") end) end
    pcall(function() db:close() end)
    if not ok then logger.warn("library_db catalog write failed:", err) end
    return ok
end

function LibraryDB:getChapters(book_id)
    if not book_id then return nil end
    local db = self:openRead()
    if not db then return nil end
    local chapters = {}
    local stmt
    local ok = pcall(function()
        stmt = db:prepare([[
            SELECT payload FROM chapters WHERE book_id=? ORDER BY position
        ]])
        local row = stmt:reset():bind(tostring(book_id)):step()
        while row do
            local chapter = decode(row[1])
            if chapter then chapters[#chapters + 1] = chapter end
            row = stmt:step()
        end
    end)
    close_statement(stmt)
    pcall(function() db:close() end)
    return ok and #chapters > 0 and chapters or nil
end

return LibraryDB
