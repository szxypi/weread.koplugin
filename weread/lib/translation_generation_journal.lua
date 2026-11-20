-- Durable, account-scoped, once-only claims for a single chapter. A claim is
-- consumed before dispatch, including when the process dies or a reply is lost.
-- The record stores hashes and protocol state, never credentials or book text.
local Model=require('weread.lib.translation_generation')
local M={MAX_RECORDS=4096};M.__index=M
local fields={'owner','book_id','chapter_uid','book_version','translate_version','grant_sha256',
    'catalog_sha256','source_sha256','baseline_sha256'}
local phases={prepared=true,mode_claimed=true,mode_confirmed=true,generation_claimed=true,
    response_received=true}
local function query(db,sql,...)
    local stmt=db:prepare(sql);local args={...}
    local ok,result=pcall(function()
        if #args>0 then stmt:bind(unpack(args)) end
        local rows={};while true do local row=stmt:step();if not row then return rows end;rows[#rows+1]=row end
    end)
    stmt:close();if not ok then error(result,0) end;return result
end
function M:new(library,codec,scope)
    return setmetatable({library=library,codec=codec,scope=scope,account=library:accountKey()},self)
end
function M:current(plan)
    return self.account and self.library:accountKey()==self.account and self.scope
        and self.scope.vid==plan.owner and self.library.settings:auth_scope_matches(self.scope) or false
end
function M:open(plan)
    if not Model.valid(plan) or not self:current(plan) then return nil end
    local db=self.library:open();if not db then return nil end
    local ok=pcall(function()
        db:exec('PRAGMA synchronous=FULL')
        local row=query(db,'PRAGMA synchronous')[1];assert(row and tonumber(row[1])>=2)
        db:exec([[CREATE TABLE IF NOT EXISTS translation_generation_claims (
            book_id TEXT NOT NULL, uid INTEGER NOT NULL, plan TEXT NOT NULL, phase TEXT NOT NULL,
            result TEXT, PRIMARY KEY(book_id,uid)
        ) WITHOUT ROWID]])
    end)
    if not ok then pcall(db.close,db);return nil end
    return db
end
local function access(self,plan,operation)
    local db=self:open(plan);if not db then return nil end
    local ok,result=pcall(function()
        db:exec('BEGIN IMMEDIATE')
        local value=operation(db)
        assert(self:current(plan));db:exec('COMMIT')
        -- A switched session after commit must never dispatch the old claim.
        if not self:current(plan) then return nil end
        return value
    end)
    if not ok then pcall(db.exec,db,'ROLLBACK') end
    pcall(db.close,db);return ok and result or nil
end
local function read(self,db,plan)
    local row=query(db,'SELECT plan,phase,result FROM translation_generation_claims WHERE book_id=? AND uid=?',
        plan.book_id,plan.chapter_uid)[1]
    if not row then return nil end
    assert(type(row[1])=='string' and #row[1]<=2048 and phases[row[2]])
    local stored=self.codec:json_decode(row[1]);assert(Model.valid(stored))
    for _,key in ipairs(fields) do assert(stored[key]==plan[key]) end
    assert(row[3]==nil or row[2]=='response_received' and (row[3]=='ready' or row[3]=='pending' or row[3]=='stopped_unavailable'))
    assert(row[2]~='response_received' or row[3]~=nil)
    return {phase=row[2],result=row[3]}
end
-- Inspect the record by account/book/chapter before deciding whether a stale
-- pre-dispatch plan may be replaced. Claimed operations are never deleted.
local function lookup(self,db,plan)
    local row=query(db,'SELECT plan FROM translation_generation_claims WHERE book_id=? AND uid=?',plan.book_id,plan.chapter_uid)[1]
    if not row then return nil end
    assert(type(row[1])=='string' and #row[1]<=2048)
    local saved=self.codec:json_decode(row[1])
    assert(Model.valid(saved) and saved.owner==plan.owner and saved.book_id==plan.book_id and saved.chapter_uid==plan.chapter_uid)
    local state=assert(read(self,db,saved));state.same=true
    for _,key in ipairs(fields) do if saved[key]~=plan[key] then state.same=false end end
    return state
end
function M:lookup(plan)
    return access(self,plan,function(db) return lookup(self,db,plan) end)
end
function M:discard_stale_prepared(plan)
    return access(self,plan,function(db)
        local state=lookup(self,db,plan)
        if not state or state.same or state.phase~='prepared' then return false end
        query(db,'DELETE FROM translation_generation_claims WHERE book_id=? AND uid=?',plan.book_id,plan.chapter_uid)
        return true
    end)==true
end
-- A confirmed mode change can be followed by a freshly checked plan after
-- cancellation or ordinary progress changes. A claimed generation cannot.
function M:rebase_confirmed(plan)
    return access(self,plan,function(db)
        local state=lookup(self,db,plan)
        if not state or state.same or state.phase~='mode_confirmed' then return false end
        local encoded=self.codec:json_encode(plan);assert(type(encoded)=='string' and #encoded<=2048)
        query(db,'UPDATE translation_generation_claims SET plan=? WHERE book_id=? AND uid=?',
            encoded,plan.book_id,plan.chapter_uid)
        local updated=assert(read(self,db,plan))
        return updated.phase=='mode_confirmed'
    end)==true
end
function M:prepare(plan)
    return access(self,plan,function(db)
        if read(self,db,plan) then return nil end
        local count=tonumber(query(db,'SELECT COUNT(*) FROM translation_generation_claims')[1][1])
        if not count or count>=M.MAX_RECORDS then return nil end
        local encoded=self.codec:json_encode(plan);assert(type(encoded)=='string' and #encoded<=2048)
        query(db,'INSERT INTO translation_generation_claims(book_id,uid,plan,phase) VALUES(?,?,?,?)',
            plan.book_id,plan.chapter_uid,encoded,'prepared')
        return read(self,db,plan)
    end)
end
function M:state(plan)
    return access(self,plan,function(db) return read(self,db,plan) end)
end
local function transition(self,plan,expected,next_phase,result)
    return access(self,plan,function(db)
        local state=read(self,db,plan);if not state or state.phase~=expected then return nil end
        query(db,'UPDATE translation_generation_claims SET phase=?,result=? WHERE book_id=? AND uid=?',
            next_phase,result or '',plan.book_id,plan.chapter_uid)
        -- Empty result keeps the bind parameter list dense in Lua 5.1.
        if not result then query(db,'UPDATE translation_generation_claims SET result=NULL WHERE book_id=? AND uid=?',
            plan.book_id,plan.chapter_uid) end
        return read(self,db,plan)
    end)
end
function M:claim_mode(plan) return transition(self,plan,'prepared','mode_claimed') end
local function confirmed_wire(wire)
    return type(wire)=='table' and wire.http_status==200 and wire.body_truncated==false
end
function M:record_mode(plan,response,wire)
    if not confirmed_wire(wire) or not Model.mode_ack(response,plan) then return nil end
    return transition(self,plan,'mode_claimed','mode_confirmed')
end
function M:claim_generation(plan) return transition(self,plan,'mode_confirmed','generation_claimed') end
function M:record_status(plan,response,wire)
    if not confirmed_wire(wire) then return nil end
    local status=Model.status(response,plan);if not status then return nil end
    return transition(self,plan,'generation_claimed','response_received',status.kind)
end
return M
