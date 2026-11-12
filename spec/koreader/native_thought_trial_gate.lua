-- Test-only one-shot transport gate. The host has already reserved all three
-- slots in Keychain before arming; this FULL SQLite claim precedes each POST.
local Contract=require('weread.lib.thought_edit_contract')
local M={};M.__index=M
local function statement(db,sql,...)
    local s=db:prepare(sql);local args={...};local ok,row=pcall(function() return s:bind(unpack(args)):step() end)
    s:close();assert(ok);return row
end
function M:new(input,library,codec,root)
    local value=setmetatable({input=input,library=library,codec=codec,path=root..'/trial-gate.db'},self)
    local db=require('lua-ljsqlite3/init').open(value.path)
    db:exec('PRAGMA synchronous=FULL');db:exec('CREATE TABLE trial(id INTEGER PRIMARY KEY,phase TEXT,posts INTEGER,target TEXT,preview TEXT)')
    statement(db,'INSERT INTO trial VALUES(1,?,0,?,?)','create','','');db:close()
    return value
end
function M:_run(task)
    local db=require('lua-ljsqlite3/init').open(self.path);db:exec('PRAGMA synchronous=FULL')
    local ok,value=pcall(task,db)
    if not ok then pcall(db.exec,db,'ROLLBACK') end
    db:close();if not ok then error('native_trial/gate',0) end;return value
end
function M:read()
    return self:_run(function(db)
        local row=assert(statement(db,'SELECT phase,posts,target,preview FROM trial WHERE id=1'))
        return {phase=row[1],posts=tonumber(row[2]),target=row[3],preview=row[4]~='' and self.codec:json_decode(row[4]) or nil}
    end)
end
function M:advance(step,target)
    assert(type(step)=='number' and step>=1 and step<=2 and Contract.key(target))
    self:_run(function(db)
        db:exec('BEGIN IMMEDIATE');local row=assert(statement(db,'SELECT phase,posts,target FROM trial WHERE id=1'))
        assert(row[1]==(step==1 and 'create_pending' or 'edit_pending') and tonumber(row[2])==step
            and (step==1 and row[3]=='' or step==2 and row[3]==target))
        for _i,id in ipairs(self.input.original_ids) do assert(id~=target) end
        statement(db,'UPDATE trial SET phase=?,target=? WHERE id=1',step==1 and 'edit' or 'delete',target);db:exec('COMMIT')
    end)
end
local function same(a,b)
    for key,value in pairs(a) do if b[key]~=value then return false end end
    for key,value in pairs(b) do if a[key]~=value then return false end end
    return true
end
function M:claim(operation,body)
    assert(Contract.validate_body(operation,body))
    return self:_run(function(db)
        db:exec('BEGIN IMMEDIATE');local row=assert(statement(db,'SELECT phase,posts,target FROM trial WHERE id=1'))
        local expected=self.input.create_body
        if operation~='create' then
            assert(Contract.key(row[3]));expected={reviewId=row[3]}
            for _i,id in ipairs(self.input.original_ids) do assert(id~=row[3]) end
            if operation=='edit' then expected.content=self.input.edited_text end
        end
        assert(row[1]==operation and tonumber(row[2])==({create=0,edit=1,delete=2})[operation] and same(body,expected))
        local journal=require('weread.lib.thought_edit_store'):new(self.library,self.codec):read()
        assert(journal and journal.phase=='pending' and journal.metadata.operation==operation
            and journal.metadata.book_id==self.input.book_id and journal.metadata.request_hash==Contract.body_hash(body))
        if not self.input.permit_writes then
            assert(operation=='create' and tonumber(row[2])==0)
            statement(db,'UPDATE trial SET phase=?,preview=? WHERE id=1','blocked',self.codec:json_encode(body));db:exec('COMMIT');return false
        end
        statement(db,'UPDATE trial SET phase=?,posts=posts+1 WHERE id=1',operation..'_pending');db:exec('COMMIT');return true
    end)
end
return M
