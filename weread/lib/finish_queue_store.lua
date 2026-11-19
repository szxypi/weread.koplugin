-- Account-local offline finished-mark intents. A claimed intent is never
-- automatically returned to the queue: its write may already have happened.
local Contract = require('weread.lib.finish_change_contract')
local M = {}; M.__index = M
local LIMIT = 1000

local function token(value)
    return type(value) == 'string' and #value == 32 and value:match('^[a-f0-9]+$') ~= nil
end
local function nonce()
    local file = io.open('/dev/urandom', 'rb')
    if not file then return end
    local raw = file:read(16); file:close()
    if not raw or #raw ~= 16 then return end
    return (raw:gsub('.', function(char) return string.format('%02x', char:byte()) end))
end
local function statement(db, sql, ...)
    local query = db:prepare(sql)
    local args = {...}
    local ok, result = pcall(function() return query:bind(unpack(args)):step() end)
    query:close()
    assert(ok, 'finish_queue/statement')
    return result
end
local function valid_integer(value)
    return type(value) == 'number' and value >= 0 and value % 1 == 0 and value <= 9007199254740990
end
local function row(value, account)
    if not value then return nil end
    local result = {book_id=value[1], id=value[2], before=tonumber(value[3]), desired=tonumber(value[4]),
        phase=value[5], created_at=tonumber(value[6]), account=account}
    assert(Contract.id(result.book_id) and token(result.id) and (result.before==0 or result.before==1)
        and (result.desired==0 or result.desired==1) and result.before~=result.desired
        and (result.phase=='queued' or result.phase=='dispatching' or result.phase=='conflict')
        and valid_integer(result.created_at), 'finish_queue/invalid')
    result.before, result.desired = result.before==1, result.desired==1
    return result
end
local function matches(value, expected, phase)
    return value and type(expected)=='table' and value.account==expected.account and value.book_id==expected.book_id
        and value.id==expected.id and value.before==expected.before and value.desired==expected.desired
        and value.created_at==expected.created_at and value.phase==expected.phase and (not phase or value.phase==phase)
end
local function read(db, account, id)
    return row(statement(db, 'SELECT book_id,token,before_value,desired_value,phase,created_at FROM finish_offline_queue WHERE book_id=?', id), account)
end
local function run(self, write, callback)
    local account = self.library:accountKey()
    if not account then return nil, 'account' end
    local opened, db = pcall(self.library.open, self.library)
    if not opened or not db then return nil, 'storage' end
    local transaction = false
    local ok, result = pcall(function()
        db:exec('PRAGMA synchronous=FULL')
        db:exec([[CREATE TABLE IF NOT EXISTS finish_offline_queue (
            book_id TEXT PRIMARY KEY, token TEXT NOT NULL, before_value INTEGER NOT NULL,
            desired_value INTEGER NOT NULL, phase TEXT NOT NULL, created_at INTEGER NOT NULL
        ) WITHOUT ROWID]])
        if write then db:exec('BEGIN IMMEDIATE'); transaction = true end
        assert(self.library:accountKey()==account, 'finish_queue/account')
        local value = callback(db, account)
        assert(self.library:accountKey()==account, 'finish_queue/account')
        if transaction then db:exec('COMMIT'); transaction = false end
        return value
    end)
    if transaction then pcall(db.exec, db, 'ROLLBACK') end
    pcall(db.close, db)
    if not ok then return nil, 'storage' end
    return result
end
function M:new(library, options)
    return setmetatable({library=library, nonce=options and options.nonce or nonce, now=options and options.now or os.time}, self)
end
function M:get(id)
    if not Contract.id(id) then return nil, 'invalid' end
    return run(self, false, function(db, account) return read(db, account, id) end)
end
function M:list()
    return run(self, false, function(db, account)
        local query=db:prepare('SELECT book_id,token,before_value,desired_value,phase,created_at FROM finish_offline_queue ORDER BY created_at,book_id LIMIT 1001')
        local ok, result=pcall(function()
            local entries={}; local value=query:step()
            while value do
                entries[#entries+1]=row(value,account)
                assert(#entries<=LIMIT, 'finish_queue/limit')
                value=query:step()
            end
            return entries
        end)
        query:close(); assert(ok, 'finish_queue/invalid'); return result
    end)
end
-- New intent requires no existing row. Replacing a queued/conflict intent or
-- discarding any intent uses its exact token and phase as a compare-and-swap.
function M:put(id, before, desired, expected)
    if not Contract.id(id) or type(before)~='boolean' or type(desired)~='boolean' or before==desired then return nil, 'invalid' end
    local id_token=self.nonce(); local created=self.now()
    if not token(id_token) or not valid_integer(created) then return nil, 'storage' end
    return run(self, true, function(db, account)
        local previous=read(db,account,id)
        if expected then
            assert(matches(previous,expected) and (previous.phase=='queued' or previous.phase=='conflict'), 'finish_queue/replaced')
            assert(previous.id~=id_token, 'finish_queue/token_reused')
        else
            assert(not previous, 'finish_queue/exists')
            local count=statement(db,'SELECT count(*) FROM finish_offline_queue')
            assert(count and tonumber(count[1])<LIMIT, 'finish_queue/limit')
        end
        statement(db, [[INSERT INTO finish_offline_queue(book_id,token,before_value,desired_value,phase,created_at)
            VALUES(?,?,?,?,?,?) ON CONFLICT(book_id) DO UPDATE SET token=excluded.token,before_value=excluded.before_value,
            desired_value=excluded.desired_value,phase=excluded.phase,created_at=excluded.created_at]],
            id,id_token,before and 1 or 0,desired and 1 or 0,'queued',created)
        local saved=read(db,account,id)
        assert(saved and saved.id==id_token and saved.before==before and saved.desired==desired and saved.phase=='queued', 'finish_queue/readback')
        return saved
    end)
end
function M:transition(expected, next_phase)
    if next_phase~='dispatching' and next_phase~='conflict' then return nil, 'invalid' end
    return run(self, true, function(db, account)
        local previous=read(db,account,expected and expected.book_id or '')
        assert(matches(previous,expected,'queued'), 'finish_queue/replaced')
        statement(db,'UPDATE finish_offline_queue SET phase=? WHERE book_id=?',next_phase,previous.book_id)
        local saved=read(db,account,previous.book_id)
        assert(saved and saved.id==previous.id and saved.phase==next_phase, 'finish_queue/readback')
        return saved
    end)
end
-- Only the caller that has proof that commit was never sent may release a
-- claim; uncertain or interrupted dispatches must remain dispatching.
function M:release_unsent(expected)
    return run(self, true, function(db, account)
        local previous=read(db,account,expected and expected.book_id or '')
        assert(matches(previous,expected,'dispatching'), 'finish_queue/replaced')
        statement(db,'UPDATE finish_offline_queue SET phase=? WHERE book_id=?','queued',previous.book_id)
        local saved=read(db,account,previous.book_id)
        assert(saved and saved.id==previous.id and saved.phase=='queued', 'finish_queue/readback')
        return saved
    end)
end
function M:remove(expected)
    return run(self, true, function(db, account)
        local previous=read(db,account,expected and expected.book_id or '')
        assert(matches(previous,expected), 'finish_queue/replaced')
        statement(db,'DELETE FROM finish_offline_queue WHERE book_id=?',previous.book_id)
        assert(not read(db,account,previous.book_id), 'finish_queue/readback')
        return true
    end)
end
return M
