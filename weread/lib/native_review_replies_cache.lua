-- Bounded account-local snapshots of public review and thought replies.
local Book=require('weread.lib.native_book_reviews')
local Data=require('weread.lib.native_review_replies')
local Protocol=require('weread.lib.protocol')
local M={MAX_THREADS=64,MAX_PAYLOAD=2*1024*1024,MAX_TOTAL=16*1024*1024};M.__index=M
local function integer(value,max) return type(value)=='number' and value>=0 and value<=max and value%1==0 end
local function text(value,max,empty)
    return type(value)=='string' and (empty or value~='') and #value<=max
        and not value:find('[%z\1-\8\11\12\14-\31\127]') and Protocol.utf8_substr(value,#value)==value
end
local function valid_key(book,id,kind)
    return Book.book_id(book) and Data.review_id(id) and (kind==1 or kind==4)
end
function M.validate(codec,value,book,id,kind)
    assert(valid_key(book,id,kind) and type(value)=='table' and value.schema==1 and value.book_id==book
        and value.review_id==id and value.review_type==kind and integer(value.saved_at,4102444800) and value.saved_at>0
        and integer(value.limit,Data.MAX_ITEMS) and value.limit>0 and type(value.items)=='table'
        and #value.items<=value.limit and type(value.has_more)=='boolean' and type(value.limited)=='boolean'
        and not (value.has_more and value.limited)
        and (not value.has_more or #value.items==value.limit and value.limit<Data.MAX_ITEMS)
        and (not value.limited or #value.items==value.limit and value.limit==Data.MAX_ITEMS), 'replies_cache/snapshot')
    local items=codec:json_decode('[]');local mt=getmetatable(items)
    assert(#value.items>0 or not mt or getmetatable(value.items)==mt,'replies_cache/array')
    local count=0
    for key in pairs(value.items) do assert(integer(key,#value.items) and key>0,'replies_cache/array');count=count+1 end
    assert(count==#value.items,'replies_cache/array')
    local ids,seen={},{}
    for _,row in ipairs(value.items) do
        assert(type(row)=='table' and Data.review_id(row.review_id) and not seen[row.review_id]
            and text(row.author,4096,true) and text(row.content,131072,true)
            and row.rating==0 and integer(row.create_time,4102444800) and row.create_time>0
            and row.is_finish==false and row.idx==0,'replies_cache/item')
        seen[row.review_id]=true;ids[#ids+1]=row.review_id
        items[#items+1]={review_id=row.review_id,author=row.author,content=row.content,rating=0,
            create_time=row.create_time,is_finish=false,idx=0}
    end
    return {schema=1,book_id=book,review_id=id,review_type=kind,saved_at=value.saved_at,
        items=items,ids=ids,limit=value.limit,has_more=value.has_more,limited=value.limited}
end
function M:new(library,codec,account) return setmetatable({library=library,codec=codec,account=account},self) end
local function current(self) return self.account~=nil and self.library:accountKey()==self.account end
local function same_prefix(old,new)
    if not new.has_more or #old.items<=#new.items then return false end
    for index,item in ipairs(new.items) do
        local prior=old.items[index]
        for _,key in ipairs({'review_id','author','content','rating','create_time','is_finish','idx'}) do
            if not prior or prior[key]~=item[key] then return false end
        end
    end
    return true
end
function M:read(book,id,kind)
    if not current(self) or not valid_key(book,id,kind) then return nil end
    local db=self.library:openRead();if not db then return nil end
    local stmt
    local ok,result=pcall(function()
        stmt=db:prepare([[SELECT CASE WHEN length(CAST(payload AS BLOB))<=? THEN payload ELSE NULL END
            FROM native_review_replies WHERE book_id=? AND review_id=? AND review_type=?]])
        local row=stmt:bind(M.MAX_PAYLOAD,book,id,kind):step()
        if not row or type(row[1])~='string' or not current(self) then return nil end
        return M.validate(self.codec,self.codec:json_decode(row[1]),book,id,kind)
    end)
    if stmt then pcall(stmt.close,stmt) end;pcall(db.close,db)
    return ok and current(self) and result or nil
end
function M:write(book,id,kind,page,now)
    if not current(self) or type(page)~='table' then return false end
    local ok,model=pcall(M.validate,self.codec,{schema=1,book_id=book,review_id=id,review_type=kind,saved_at=now,
        items=page.items,limit=page.limit,has_more=page.has_more,limited=page.limited==true},book,id,kind)
    if not ok then return false end
    model.ids=nil
    local encoded,payload=pcall(self.codec.json_encode,self.codec,model)
    if not encoded or type(payload)~='string' or #payload>M.MAX_PAYLOAD then return false end
    local db=self.library:open();if not db then return false end
    local stmt,transaction
    local success=pcall(function()
        db:exec([[CREATE TABLE IF NOT EXISTS native_review_replies (
            book_id TEXT NOT NULL,review_id TEXT NOT NULL,review_type INTEGER NOT NULL,
            payload TEXT NOT NULL,serial INTEGER NOT NULL,PRIMARY KEY(book_id,review_id,review_type)) WITHOUT ROWID]])
        db:exec('BEGIN IMMEDIATE');transaction=true;assert(current(self),'replies_cache/account')
        stmt=db:prepare([[SELECT CASE WHEN length(CAST(payload AS BLOB))<=? THEN payload ELSE NULL END
            FROM native_review_replies WHERE book_id=? AND review_id=? AND review_type=?]])
        local existing=stmt:bind(M.MAX_PAYLOAD,book,id,kind):step();stmt:close();stmt=nil
        if existing and type(existing[1])=='string' then
            local valid,prior=pcall(function() return M.validate(self.codec,self.codec:json_decode(existing[1]),book,id,kind) end)
            if valid and same_prefix(prior,model) then payload=existing[1] end
        end
        stmt=db:prepare([[INSERT INTO native_review_replies(book_id,review_id,review_type,payload,serial)
            VALUES(?,?,?,?,(SELECT COALESCE(MAX(serial),0)+1 FROM native_review_replies))
            ON CONFLICT(book_id,review_id,review_type) DO UPDATE SET payload=excluded.payload,serial=excluded.serial]])
        stmt:bind(book,id,kind,payload):step();stmt:close();stmt=nil
        stmt=db:prepare([[SELECT book_id,review_id,review_type,length(CAST(payload AS BLOB))
            FROM native_review_replies ORDER BY serial DESC]])
        local remove,count,bytes={},0,0;local row=stmt:step()
        while row do
            count=count+1;assert(count<=M.MAX_THREADS+1,'replies_cache/quota')
            bytes=bytes+assert(tonumber(row[4]))
            if count>M.MAX_THREADS or bytes>M.MAX_TOTAL then remove[#remove+1]={row[1],row[2],row[3]} end
            row=stmt:step()
        end
        stmt:close();stmt=nil
        stmt=db:prepare('DELETE FROM native_review_replies WHERE book_id=? AND review_id=? AND review_type=?')
        for _,key in ipairs(remove) do stmt:reset():bind(unpack(key)):step() end
        stmt:close();stmt=nil;assert(current(self),'replies_cache/account')
        db:exec('COMMIT');transaction=false
    end)
    if stmt then pcall(stmt.close,stmt) end
    if transaction then pcall(db.exec,db,'ROLLBACK') end
    pcall(db.close,db);return success and current(self)
end
return M
