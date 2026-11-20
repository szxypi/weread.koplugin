-- Per-account imported Reader links. Does not change cloud shelf membership.
local Link=require('weread.lib.reader_link')
local Access=require('weread.lib.read_access')
local M={};M.__index=M
local function close(value) if value then pcall(value.close,value) end end
local function run(self,task)
    local db=self.library:open()
    if not db then return nil end
    local stmt
    local ok,result=pcall(function()
        db:exec([[CREATE TABLE IF NOT EXISTS reader_links (
            book_id TEXT PRIMARY KEY, reader_url TEXT NOT NULL UNIQUE,
            payload TEXT NOT NULL, imported_at INTEGER NOT NULL
        ) WITHOUT ROWID]])
        return task(function(sql) stmt=db:prepare(sql);return stmt end)
    end)
    close(stmt);close(db)
    return ok and result or nil
end
function M:new(library,codec) return setmetatable({library=library,codec=codec},self) end
function M:put(record,now)
    local ok,bounded=pcall(Link.record,record)
    now=now or os.time()
    if not ok or type(now)~='number' or now<0 or now>2^53 or now%1~=0 then return false end
    local encoded,payload=pcall(self.codec.json_encode,self.codec,bounded)
    if not encoded or type(payload)~='string' or #payload>256*1024 then return false end
    return run(self,function(prepare)
        prepare([[INSERT INTO reader_links (book_id,reader_url,payload,imported_at) VALUES (?,?,?,?)
            ON CONFLICT(book_id) DO UPDATE SET reader_url=excluded.reader_url,payload=excluded.payload,imported_at=excluded.imported_at]])
            :bind(bounded.metadata.bookId,bounded.reader_url,payload,now):step()
        return true
    end)==true
end
local function decode(self,row)
    if not row or type(row[1])~='string' or #row[1]>256*1024 then return nil end
    local ok,record=pcall(function() return Link.record(self.codec:json_decode(row[1])) end)
    if not ok or row[3]~=record.metadata.bookId or row[4]~=record.reader_url then return nil end
    record.imported_at=tonumber(row[2]) or 0
    return record
end
function M:find(url)
    url=Link.canonical(url)
    if not url then return nil end
    return run(self,function(prepare)
        return decode(self,prepare('SELECT payload,imported_at,book_id,reader_url FROM reader_links WHERE reader_url=?'):bind(url):step())
    end)
end
function M:get(id)
    id=Access.book_id(id)
    if not id then return nil end
    return run(self,function(prepare)
        return decode(self,prepare('SELECT payload,imported_at,book_id,reader_url FROM reader_links WHERE book_id=?'):bind(id):step())
    end)
end
function M:list(offset,limit)
    offset,limit=offset or 0,limit or 20
    if type(offset)~='number' or offset<0 or offset>1e6 or offset%1~=0
        or type(limit)~='number' or limit<1 or limit>50 or limit%1~=0 then return nil end
    return run(self,function(prepare)
        local stmt=prepare('SELECT payload,imported_at,book_id,reader_url FROM reader_links ORDER BY imported_at DESC,book_id LIMIT ? OFFSET ?'):bind(limit+1,offset)
        local result={books={},has_more=false}
        for i=1,limit+1 do
            local row=stmt:step()
            if not row then break end
            if i>limit then result.has_more=true;break end
            local record=decode(self,row)
            if record then
                result.books[#result.books+1]={book_id=record.metadata.bookId,title=record.metadata.title,author=record.metadata.author,
                    reader_url=record.reader_url,imported_at=record.imported_at}
            end
        end
        return result
    end)
end
function M:remove(id)
    id=Access.book_id(id)
    if not id then return false end
    return run(self,function(prepare) prepare('DELETE FROM reader_links WHERE book_id=?'):bind(id):step();return true end)==true
end
return M
