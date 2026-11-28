-- Account-local, bounded snapshots of already displayed public reviews.
local Data=require('weread.lib.native_book_reviews')
local Protocol=require('weread.lib.protocol')
local M={MAX_BOOKS=32,MAX_PAYLOAD=2*1024*1024,MAX_TOTAL=16*1024*1024};M.__index=M
local function integer(value,max)
    return type(value)=='number' and value>=0 and value<=max and value%1==0
end
local function text(value,max,empty)
    return type(value)=='string' and (empty or value~='') and #value<=max
        and not value:find('[%z\1-\8\11\12\14-\31\127]')
        and Protocol.utf8_substr(value,#value)==value
end
local function cache_key(id,mode)
    if mode==nil then return Data.list_book_id(id) and id or nil end
    if (mode=='recommended' or mode=='latest') and text(id,256) and not id:find('[%c]') then return mode..':'..id end
end
function M.validate(codec,value,id,mode)
    assert(cache_key(id,mode) and type(value)=='table' and value.schema==1 and value.book_id==id
        and (not mode or value.mode==mode)
        and integer(value.saved_at,4102444800) and value.saved_at>0
        and type(value.items)=='table' and #value.items<=Data.MAX_ITEMS
        and type(value.has_more)=='boolean' and type(value.limited)=='boolean'
        and not (value.has_more and value.limited), 'reviews_cache/snapshot')
    if not mode then
        assert(integer(value.limit,Data.MAX_ITEMS) and value.limit>0 and #value.items<=value.limit
            and (not value.has_more or #value.items==value.limit and value.limit<Data.MAX_ITEMS)
            and (not value.limited or #value.items==value.limit and value.limit==Data.MAX_ITEMS), 'reviews_cache/limit')
    end
    local items=codec:json_decode('[]');local array_mt=getmetatable(items)
    assert(#value.items>0 or not array_mt or getmetatable(value.items)==array_mt,'reviews_cache/array')
    local ids,seen,last={}, {}, nil
    local count=0
    for key in pairs(value.items) do assert(integer(key,#value.items) and key>0,'reviews_cache/array');count=count+1 end
    assert(count==#value.items,'reviews_cache/array')
    for _,row in ipairs(value.items) do
        assert(type(row)=='table','reviews_cache/item')
        local rid=row.review_id
        assert((mode and rid==nil or text(rid,256) and not rid:find('%s') and not seen[rid])
            and text(row.author,4096,true) and text(row.content,131072,true)
            and type(row.rating)=='number' and row.rating>=0 and row.rating<=5
            and integer(row.create_time,mode and 4102444800000 or 4102444800) and type(row.is_finish)=='boolean', 'reviews_cache/item')
        if not mode then
            assert(row.create_time>0 and (not last or row.create_time<=last)
                and integer(row.idx,9007199254740991),'reviews_cache/order')
            last=row.create_time;ids[#ids+1]=rid
        end
        if rid then seen[rid]=true end
        local item={review_id=rid,author=row.author,content=row.content,rating=row.rating,
            create_time=row.create_time,is_finish=row.is_finish}
        if not mode then item.idx=row.idx end
        local attachment=require('weread.lib.thought_attachments').cached(row)
        if attachment then item.attachment_state,item.attachment_urls=attachment.state,attachment.urls end
        items[#items+1]=item
    end
    return {schema=1,book_id=id,mode=mode,saved_at=value.saved_at,items=items,ids=not mode and ids or nil,limit=not mode and value.limit or nil,
        has_more=value.has_more,limited=value.limited}
end
function M:new(library,codec,account,mode)
    return setmetatable({library=library,codec=codec,account=account,mode=mode,
        table_name=mode and 'gateway_book_reviews' or 'native_book_reviews'},self)
end
local function current(self) return self.account~=nil and self.library:accountKey()==self.account end
local function same_prefix(previous,current_page)
    if not current_page.has_more or #previous.items<=#current_page.items then return false end
    for index,item in ipairs(current_page.items) do
        local old=previous.items[index]
        if not item.review_id then return false end
        for _,field in ipairs({'review_id','author','content','rating','create_time','is_finish','idx',
            'attachment_state','attachment_urls'}) do
            if not old or old[field]~=item[field] then return false end
        end
    end
    return true
end
function M:read(id)
    local key=cache_key(id,self.mode)
    if not current(self) or not key then return nil end
    local db=self.library:openRead();if not db then return nil end
    local stmt
    local ok,result=pcall(function()
        stmt=db:prepare([[SELECT CASE WHEN length(CAST(payload AS BLOB))<=? THEN payload ELSE NULL END FROM ]]
            ..self.table_name..' WHERE book_id=?')
        local row=stmt:bind(M.MAX_PAYLOAD,key):step()
        if not row or type(row[1])~='string' or not current(self) then return nil end
        return M.validate(self.codec,self.codec:json_decode(row[1]),id,self.mode)
    end)
    if stmt then pcall(stmt.close,stmt) end;pcall(db.close,db)
    return ok and current(self) and result or nil
end
function M:write(id,page,now)
    local key=cache_key(id,self.mode)
    if not current(self) or not key or type(page)~='table' then return false end
    local ok,model=pcall(function()
        local items=page.items
        if self.mode and type(items)=='table' and next(items)==nil then items=self.codec:json_decode('[]') end
        return M.validate(self.codec,{schema=1,book_id=id,mode=self.mode,saved_at=now,items=items,
            limit=page.limit,has_more=page.has_more,limited=page.limited==true},id,self.mode)
    end)
    if not ok then return false end
    model.ids=nil
    local encoded,payload=pcall(self.codec.json_encode,self.codec,model)
    if not encoded or type(payload)~='string' or #payload>M.MAX_PAYLOAD then return false end
    local db=self.library:open();if not db then return false end
    local stmt,transaction
    local success=pcall(function()
        db:exec('CREATE TABLE IF NOT EXISTS '..self.table_name
            ..' (book_id TEXT PRIMARY KEY,payload TEXT NOT NULL,serial INTEGER NOT NULL)')
        db:exec('BEGIN IMMEDIATE');transaction=true
        assert(current(self),'reviews_cache/account')
        stmt=db:prepare([[SELECT CASE WHEN length(CAST(payload AS BLOB))<=? THEN payload ELSE NULL END FROM ]]
            ..self.table_name..' WHERE book_id=?')
        local cached_row=stmt:bind(M.MAX_PAYLOAD,key):step();stmt:close();stmt=nil
        if cached_row and type(cached_row[1])=='string' then
            local previous_ok,previous=pcall(function()
                return M.validate(self.codec,self.codec:json_decode(cached_row[1]),id,self.mode)
            end)
            if previous_ok and same_prefix(previous,model) then payload=cached_row[1] end
        end
        stmt=db:prepare('INSERT INTO '..self.table_name..[[(book_id,payload,serial)
            VALUES(?,?,(SELECT COALESCE(MAX(serial),0)+1 FROM ]]..self.table_name..[[))
            ON CONFLICT(book_id) DO UPDATE SET payload=excluded.payload,serial=excluded.serial]])
        stmt:bind(key,payload):step();stmt:close();stmt=nil
        stmt=db:prepare('SELECT book_id,length(CAST(payload AS BLOB)) FROM '..self.table_name..' ORDER BY serial DESC')
        local remove,count,bytes={},0,0;local row=stmt:step()
        while row do
            count=count+1;assert(count<=M.MAX_BOOKS+1,'reviews_cache/quota')
            bytes=bytes+assert(tonumber(row[2]));if count>M.MAX_BOOKS or bytes>M.MAX_TOTAL then remove[#remove+1]=row[1] end
            row=stmt:step()
        end
        stmt:close();stmt=nil
        stmt=db:prepare('DELETE FROM '..self.table_name..' WHERE book_id=?')
        for _,expired in ipairs(remove) do stmt:reset():bind(expired):step() end
        stmt:close();stmt=nil
        assert(current(self),'reviews_cache/account');db:exec('COMMIT');transaction=false
    end)
    if stmt then pcall(stmt.close,stmt) end
    if transaction then pcall(db.exec,db,'ROLLBACK') end
    pcall(db.close,db)
    return success and current(self)
end
return M
