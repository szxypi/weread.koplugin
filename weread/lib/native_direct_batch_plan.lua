-- Local resume plans for E-Ink chapter ranges and standard EPUB downloads.
-- A new process verifies the current catalog before offering confirmation.
local Contract=require('weread.lib.native_position_contract')
local Protocol=require('weread.lib.native_position_protocol')
local Access=require('weread.lib.read_access')
local M={}
M.__index=M
local PREFIX={eink='eink_batch_v1:',standard='standard_full_v1:',selected='standard_selected_v1:'}
local MAX_SELECTION_BYTES=20000*21

local function hex(value,length)
    return type(value)=='string' and #value==length and value:match('^[a-f0-9]+$')~=nil
end

local function key(kind,id)
    if not PREFIX[kind] or type(id)~='string' then return end
    local valid=kind=='eink' and Protocol.id(id) or kind~='eink' and Access.display_book_id(id)
    if valid==id then return PREFIX[kind]..id end
end

local fields={schema=true,account=true,book_id=true,version=true,digest=true,count=true,first=true,last=true,revision=true}
local function valid(record,id,account,kind)
    if type(record)~='table' or record.schema~=1 or record.book_id~=id or record.account~=account
        or not hex(record.revision,32) or not hex(record.digest,64)
        or not Protocol.integer(record.version,0,2147483647) or not Protocol.integer(record.count,1,20000)
        or not Protocol.integer(record.first,1,record.count)
        or not Protocol.integer(record.last,record.first,record.count) then return false end
    for field in pairs(record) do
        if not fields[field] and (kind~='selected' or field~='selection') then return false end
    end
    if kind=='selected' then
        if type(record.selection)~='string' or #record.selection>MAX_SELECTION_BYTES
            or record.selection:find('[^%d,]') or record.selection:find(',,',1,true)
            or record.selection:sub(1,1)==',' or record.selection:sub(-1)==',' then return false end
        local count,seen=0,{}
        for uid in record.selection:gmatch('%d+') do
            if Access.book_id(uid)~=uid or seen[uid] then return false end
            seen[uid]=true
            count=count+1
        end
        return count==record.count
    end
    return true
end

local function revision()
    local file=io.open('/dev/urandom','rb')
    if not file then return end
    local bytes=file:read(16)
    if not file:close() or not bytes or #bytes~=16 then return end
    return (bytes:gsub('.',function(char) return string.format('%02x',char:byte()) end))
end

function M:new(library,scope,kind)
    kind=kind or 'eink'
    return setmetatable({library=library,account=Contract.account_key(scope.vid),kind=kind},self)
end

function M:_current(guard)
    local ok,result=pcall(function()
        return self.account and guard()==true and self.library:accountKey()==self.account
    end)
    return ok and result==true
end

function M:verified(record,id)
    return key(self.kind,id)~=nil and self.account~=nil and valid(record,id,self.account,self.kind)
        and (self.kind=='eink' or record.first==1 and record.last==record.count)
end

function M:read(id,guard)
    local name=key(self.kind,id)
    if not name or not self:_current(guard) or type(self.library.getProfileState)~='function' then return end
    local ok,value=pcall(self.library.getProfileState,self.library,name)
    if ok and self:verified(value,id) and self:_current(guard) then return value end
end

function M:list(guard)
    if not self:_current(guard) or type(self.library.openRead)~='function' then return end
    local opened,db=pcall(self.library.openRead,self.library)
    if not opened or not db then return end
    local statement
    local ok,records=pcall(function()
        local json=require('json')
        statement=db:prepare([[SELECT name,CASE WHEN length(CAST(payload AS BLOB))<=? THEN payload END
            FROM profile_state WHERE name GLOB ? ORDER BY name]])
        local prefix=PREFIX[self.kind]
        statement:bind(self.kind=='selected' and MAX_SELECTION_BYTES+1024 or 1024,prefix..'*')
        local result={}
        while true do
            local row=statement:step()
            if not row then break end
            local id=row[1]:sub(#prefix+1)
            if type(row[2])=='string' then
                local decoded,record=pcall(json.decode,row[2])
                if decoded and self:verified(record,id) then
                    result[#result+1]=self.kind=='selected'
                        and {book_id=id,count=record.count,revision=record.revision} or record
                end
            end
        end
        return result
    end)
    if statement then pcall(statement.close,statement) end
    pcall(db.close,db)
    if ok and self:_current(guard) then return records end
end

function M:range(record,catalog)
    if self:verified(record,catalog.book_id)
        and (record.version==catalog.version or self.kind~='eink' and (record.version==0 or catalog.version==0))
        and record.digest==catalog.reading_digest
        and record.count==#catalog.chapters
        and (self.kind~='selected' or record.selection==catalog.selection) then
        return {first=record.first,last=record.last}
    end
end

function M:checkpointScope(record)
    if self.kind=='eink' or type(record)~='table' or not self:verified(record,record.book_id) then return end
    local parts={'weread-standard-checkpoint-v1',self.kind,record.account,record.book_id,record.digest,tostring(record.version)}
    return require('weread.lib.crypto').sha256_hex(table.concat(parts,'\0'))
end

-- The ordered UIDs and ordinals define the whole EPUB's chapter scope.
-- The downloader still validates each staged chapter's content and version.
function M.standard_catalog(id,version,chapters)
    if not key('standard',id) or not chapters then return end
    local rows,uids={},{}
    for i,row in ipairs(chapters) do
        rows[i]=row.chapterUid..':'..tostring(row.chapterIdx or '')
        uids[i]=row.chapterUid
    end
    return {book_id=id,version=version,chapters=chapters,selection=table.concat(uids,','),
        reading_digest=require('weread.lib.crypto').sha256_hex(table.concat(rows,'\n'))}
end

function M:selectChapters(id,version,chapters,reference,guard)
    if self.kind~='selected' or type(reference)~='table' then return end
    local record=reference.book_id==id and self:read(id,guard)
    if not record or record.revision~=reference.revision then return end
    local selected={}
    local uids=record.selection:gmatch('%d+')
    local uid=uids()
    for _,chapter in ipairs(chapters) do
        if chapter.chapterUid==uid then
            selected[#selected+1]=chapter
            uid=uids()
        end
    end
    if not uid and self:range(record,M.standard_catalog(id,version,selected)) then return selected,record end
end

function M:begin(catalog,range,expected,guard)
    local id=catalog.book_id
    local name=key(self.kind,id)
    if not name or not self:_current(guard) or type(self.library.compareProfileState)~='function'
        or range~=nil and type(range)~='table'
        or expected~=nil and not self:verified(expected,id) then return end
    local first,last=1,#catalog.chapters
    if range then first,last=range.first,range.last end
    local record={schema=1,account=self.account,book_id=id,version=catalog.version,digest=catalog.reading_digest,
        count=#catalog.chapters,first=first,last=last,revision=revision()}
    if self.kind=='selected' then record.selection=catalog.selection end
    if not self:verified(record,id) or expected and expected.revision==record.revision then return end
    local ok,saved=pcall(self.library.compareProfileState,self.library,name,expected,record)
    if ok and saved==true and self:_current(guard) then return record end
end

function M:remove(id,record,guard)
    if type(record)~='table' then return false end
    if self.kind=='selected' then
        local latest=self:read(id,guard)
        if not latest or latest.revision~=record.revision then return false end
        record=latest
    end
    if not self:verified(record,id) or not self:_current(guard)
        or type(self.library.deleteProfileStateIf)~='function' then return false end
    local ok,removed=pcall(self.library.deleteProfileStateIf,self.library,key(self.kind,id),record)
    return ok and removed==true and self:_current(guard)
end
return M
