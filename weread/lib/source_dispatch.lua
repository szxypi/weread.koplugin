-- A bounded per-book dispatch journal. Persist before a possible write and
-- retain uncertainty across process loss; receipts cannot clear newer work.
local Crypto = require('weread.lib.crypto')
local Readback = require('weread.lib.progress_readback')
local M = {}; M.__index = M
local function nonce()
    local file = io.open('/dev/urandom','rb')
    if not file then return end
    local bytes = file:read(16); file:close()
    if not bytes or #bytes ~= 16 then return end
    return (bytes:gsub('.',function(char) return string.format('%02x',char:byte()) end))
end
local function copy(value)
    if type(value) ~= 'table' then return value end
    local out={}; for key,item in pairs(value) do out[key]=copy(item) end; return out
end
function M:new(options)
    return setmetatable({settings=assert(options.settings),now=options.now or os.time,nonce=options.nonce or nonce},self)
end
function M:_account()
    local account=self.settings:get('account',{})
    local vid=type(account)=='table' and account.user_vid
    if vid==nil or tostring(vid)=='' then return end
    local scope
    if self.settings.get_auth_scope then
        scope=self.settings:get_auth_scope()
        if not scope or not self.settings:auth_scope_matches(scope) then return end
    end
    return Crypto.sha256_hex('weread-library:'..tostring(vid)):sub(1,20),scope and scope.epoch
end
function M:_record(book_id)
    local book=self.settings.get_book and self.settings:get_book(book_id) or self.settings:get('books',{})[book_id]
    return type(book)=='table' and book.source_dispatch
end
function M:pending(book_id)
    local record=self:_record(tostring(book_id))
    return record~=nil and record~=false and (type(record)~='table' or record.account==nil or record.account==self:_account())
end
function M:_save(book_id,record)
    if self.settings.patch_reading_state then
        local ok,err=self.settings:patch_reading_state(book_id,{source_dispatch=record and copy(record) or false})
        if not ok then error(err or 'Could not save dispatch state',0) end
        return
    end
    local books=self.settings:get('books',{})
    local book=books[book_id] or {book_id=book_id}
    book.source_dispatch=record and copy(record) or nil; books[book_id]=book
    self.settings:set('books',books); self.settings:flush()
end
function M:owns(receipt)
    local account,epoch=self:_account()
    if type(receipt)~='table' or receipt.account~=account or receipt.epoch~=epoch then return false end
    local record=self:_record(receipt.book_id)
    return type(record)=='table' and record.id==receipt.id and record.account==receipt.account and record.epoch==receipt.epoch
end
function M:begin(book_id,position,source,kind)
    book_id=tostring(book_id)
    local target=Readback.expected(book_id,position)
    local account,epoch=self:_account()
    if not target or not account or self:pending(book_id) or type(source)~='table'
        or source.book_id~=book_id or source.basis~='filtered_xhtml_utf16' or source.upload_verified~=false
        or source.chapter_uid~=target.chapter_uid or source.chapter_offset~=target.chapter_offset
        or kind~='position' and kind~='time' then return nil end
    local id=self.nonce()
    if type(id)~='string' or #id~=32 or not id:match('^[0-9a-f]+$') then return nil end
    local origin={}
    for _i,key in ipairs({'book_id','chapter_uid','chapter_offset','file_id','book_version','raw_sha256','render_path','basis','upload_verified'}) do
        if type(source[key])~='string' and type(source[key])~='number' and type(source[key])~='boolean' then return nil end
        origin[key]=source[key]
    end
    local receipt={book_id=book_id,id=id,account=account,epoch=epoch}
    local record={schema=1,id=id,account=account,epoch=epoch,book_id=book_id,position=target,source_position=origin,kind=kind,started_at=self.now()}
    local ok=pcall(self._save,self,book_id,record)
    return ok and self:owns(receipt) and receipt or nil
end
function M:finish(receipt,outcome)
    if not self:owns(receipt) then return false end
    if type(outcome)=='table' and (outcome.acknowledged==true and outcome.position_confirmed==true
        or outcome.enter_attempted==false and outcome.report_attempted==false) then
        return pcall(self._save,self,receipt.book_id,nil)
    end
    return true
end
-- Call only after an exact read-only comparison or an explicit sync choice.
function M:resolve(book_id)
    book_id=tostring(book_id)
    local record=self:_record(book_id)
    local account=self:_account()
    if not account or not record or type(record)=='table' and record.account~=nil and record.account~=account then return false end
    return pcall(self._save,self,book_id,nil)
end
return M
