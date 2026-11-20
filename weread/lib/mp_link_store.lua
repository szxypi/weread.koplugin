-- Imported links belong to the current account's existing library database.
local M={MAX_ROWS=500}
local Model=require('weread.lib.mp_link')
local function identity(book,review)
    if type(book)~='string' or type(review)~='string' or #review>512 then return false end
    local owner,id=review:match('^MP_WXS_([1-9]%d*)_([%w_%-]+)$')
    return owner~=nil and #owner<=20 and id~='' and book=='MP_WXS_'..owner
end
M.identity=identity
local function statement(db,sql,...)
    local stmt=db:prepare(sql);local args={...}
    local ok,row=pcall(function() return stmt:bind(unpack(args)):step() end)
    stmt:close();if not ok then error('mp_link_store/statement',0) end;return row
end
local function run(library,account,task)
    if not library or not account or library:accountKey()~=account then return nil end
    local db=library:open();if not db then return nil end
    local transaction=false
    local ok,result=pcall(function()
        db:exec("CREATE TABLE IF NOT EXISTS imported_mp_articles (review_id TEXT PRIMARY KEY, book_id TEXT NOT NULL, serial INTEGER NOT NULL, title TEXT NOT NULL DEFAULT '')")
        return task(db,function() db:exec('BEGIN IMMEDIATE');transaction=true end,function()
            assert(library:accountKey()==account,'mp_link_store/account');db:exec('COMMIT');transaction=false
        end)
    end)
    if transaction then pcall(db.exec,db,'ROLLBACK') end
    pcall(db.close,db)
    if library:accountKey()~=account then return nil end
    return ok and result or nil
end
function M.add(library,account,book,review,title)
    title=title or ''
    if not identity(book,review) or not Model.title(title) then return false end
    return run(library,account,function(db,begin,commit)
        begin()
        local exists=statement(db,'SELECT book_id FROM imported_mp_articles WHERE review_id=?',review)
        if exists then
            assert(exists[1]==book,'mp_link_store/identity')
            if title~='' then statement(db,"UPDATE imported_mp_articles SET title=? WHERE review_id=? AND title=''",title,review) end
        else
            local count=statement(db,'SELECT COUNT(*) FROM imported_mp_articles')
            assert(count and tonumber(count[1])<M.MAX_ROWS,'mp_link_store/quota')
            statement(db,'INSERT INTO imported_mp_articles (review_id,book_id,serial,title) VALUES (?,?,(SELECT COALESCE(MAX(serial),0)+1 FROM imported_mp_articles),?)',review,book,title)
        end
        commit();return true
    end)==true
end
function M.list(library,account)
    return run(library,account,function(db)
        local stmt=db:prepare('SELECT book_id,review_id,title FROM imported_mp_articles ORDER BY serial DESC LIMIT 501')
        local rows={};local ok=pcall(function()
            local row=stmt:step()
            while row do
                assert(#rows<M.MAX_ROWS and identity(row[1],row[2]) and Model.title(row[3]),'mp_link_store/invalid')
                rows[#rows+1]={book_id=row[1],review_id=row[2],title=row[3]};row=stmt:step()
            end
        end)
        stmt:close();if not ok then error('mp_link_store/read',0) end
        return rows
    end)
end
return M
