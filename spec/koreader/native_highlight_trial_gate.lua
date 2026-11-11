-- Test-only one-shot transport gate. The host reserves both slots first;
-- deletion stays disabled until the independent host read proves the new ID.
local Contract=require('weread.lib.mark_edit_contract')
local Key=require('weread.lib.thought_edit_contract').key
local M={};M.__index=M
local function statement(db,sql,...)
    local s=db:prepare(sql);local args={...};local ok,row=pcall(function() return s:bind(unpack(args)):step() end)
    s:close();assert(ok);return row
end
local function same(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~='table' then return a==b end
    for k,v in pairs(a) do if not same(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end;return true
end
function M:new(input,library,codec,root)
    assert(not input.bookmarks or input.bookmarks==true and not input.styles)
    assert(Contract.validate_body(input.bookmarks and 'bookmark_create' or 'create',input.create_body))
    local value=setmetatable({input=input,library=library,codec=codec,path=root..(input.bookmarks and '/bookmark-trial-gate.db' or '/highlight-trial-gate.db')},self)
    local db=require('lua-ljsqlite3/init').open(value.path);db:exec('PRAGMA synchronous=FULL')
    db:exec('CREATE TABLE trial(id INTEGER PRIMARY KEY,phase TEXT,posts INTEGER,target TEXT,preview TEXT)')
    statement(db,'INSERT INTO trial VALUES(1,?,0,?,?)','create','','');db:close();return value
end
function M:_run(task)
    local db=require('lua-ljsqlite3/init').open(self.path);db:exec('PRAGMA synchronous=FULL')
    local ok,value=pcall(task,db);if not ok then pcall(db.exec,db,'ROLLBACK') end
    db:close();if not ok then error('native_highlight/gate',0) end;return value
end
function M:read()
    return self:_run(function(db)
        local row=assert(statement(db,'SELECT phase,posts,target,preview FROM trial WHERE id=1'))
        return {phase=row[1],posts=tonumber(row[2]),target=row[3],preview=row[4]~='' and self.codec:json_decode(row[4]) or nil}
    end)
end
function M:advance(target)
    assert(Key(target))
    self:_run(function(db)
        db:exec('BEGIN IMMEDIATE');local row=assert(statement(db,'SELECT phase,posts,target FROM trial WHERE id=1'))
        assert(row[1]=='create_pending' and tonumber(row[2])==1 and row[3]=='')
        for _i,id in ipairs(self.input.original_ids) do assert(id~=target) end
        statement(db,'UPDATE trial SET phase=?,target=? WHERE id=1',self.input.styles and 'style0' or 'delete',target);db:exec('COMMIT')
    end)
end
function M:advance_style(target,style)
    assert(self.input.styles and Key(target) and (style==0 or style==2))
    self:_run(function(db)
        db:exec('BEGIN IMMEDIATE');local row=assert(statement(db,'SELECT phase,posts,target FROM trial WHERE id=1'))
        assert(row[1]=='style'..style..'_pending' and tonumber(row[2])==(style==0 and 2 or 3) and row[3]==target)
        statement(db,'UPDATE trial SET phase=? WHERE id=1',style==0 and 'style2' or 'delete');db:exec('COMMIT')
    end)
end
function M:claim(operation,body)
    assert(Contract.validate_body(operation,body))
    local action=operation
    if self.input.bookmarks then
        assert(operation=='bookmark_create' or operation=='bookmark_delete');action=operation=='bookmark_create' and 'create' or 'delete'
    else assert(operation=='create' or operation=='delete' or operation=='style') end
    return self:_run(function(db)
        db:exec('BEGIN IMMEDIATE');local row=assert(statement(db,'SELECT phase,posts,target FROM trial WHERE id=1'))
        local expected=self.input.create_body
        local phase=action;local posts=action=='create' and 0 or self.input.styles and 3 or 1
        if operation=='style' then
            assert(self.input.styles and Key(row[3]) and (row[1]=='style0' or row[1]=='style2'))
            local style=row[1]=='style0' and 0 or 2;phase=row[1];posts=style==0 and 1 or 2
            expected={bookmarkId=row[3],style=style,colorStyle=self.input.create_body.colorStyle}
        end
        if action=='delete' then
            assert(Key(row[3]));expected={bookmarkIds={row[3]}}
            for _i,id in ipairs(self.input.original_ids) do assert(id~=row[3]) end
        end
        assert(row[1]==phase and tonumber(row[2])==posts and same(body,expected))
        local journal=require('weread.lib.mark_edit_service').new_journal(self.library,self.codec):read()
        assert(journal and journal.phase=='pending' and journal.metadata.operation==operation
            and journal.metadata.book_id==self.input.book_id and journal.metadata.request_hash==Contract.body_hash(body))
        if not self.input.permit_writes then
            assert(action=='create' and tonumber(row[2])==0)
            statement(db,'UPDATE trial SET phase=?,preview=? WHERE id=1','blocked',self.codec:json_encode(body));db:exec('COMMIT');return false
        end
        statement(db,'UPDATE trial SET phase=?,posts=posts+1 WHERE id=1',phase..'_pending');db:exec('COMMIT');return true
    end)
end
return M
