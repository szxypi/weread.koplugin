-- Coverage and dispatch gates share one FULL SQLite transaction. Ledger
-- transitions commit first; a possibly dispatched request is never released.
local C=require('weread.lib.readtime_transfer_contract')
local M={};M.__index=M
local PHASES={prepared=true,claimed=true,unknown=true,confirmed=true,retired=true}
local function query(db,sql,...)
    local statement=db:prepare(sql);local args={...}
    local ok,result=pcall(function()
        if #args>0 then statement:bind(unpack(args)) end
        local rows={};while true do local row=statement:step();if not row then return rows end;rows[#rows+1]=row end
    end)
    statement:close();if not ok then error(result) end;return result
end
function M:new(options)
    return setmetatable({coverage=assert(options.coverage),ledger=assert(options.ledger),codec=assert(options.codec),
        now=options.now or os.time,nonce=options.nonce or function()
            local file=assert(io.open('/dev/urandom','rb'));local bytes=file:read(16);file:close();assert(bytes and #bytes==16)
            return (bytes:gsub('.',function(b) return string.format('%02x',b:byte()) end))
        end},self)
end
function M:_decode(row)
    if not row then return nil end
    assert(C.attempt(row[1]) and C.account(row[2]) and PHASES[row[3]] and C.hash(row[6]))
    assert(type(row[4])=='string' and #row[4]<=65536 and type(row[5])=='string' and #row[5]<=65536)
    local metadata,rows=self.codec:json_decode(row[4]),self.codec:json_decode(row[5])
    assert(type(metadata)=='table' and metadata.request_hash==row[6] and C.array(rows,1,100))
    local seen={};for _i,item in ipairs(rows) do assert(C.row(item) and not seen[item.id]);seen[item.id]=true end
    return {attempt=row[1],account=row[2],phase=row[3],metadata=metadata,rows=rows,request_hash=row[6],created=tonumber(row[7])}
end
function M:_record(db,attempt)
    return self:_decode(query(db,'SELECT attempt,scope,phase,metadata,rows,request_hash,created FROM offline_time_records WHERE attempt=?',attempt)[1])
end
function M:_matches(found,record,phase)
    return found and found.account==record.account and found.attempt==record.attempt and found.request_hash==record.request_hash
        and C.digest(found.metadata)==C.digest(record.metadata) and C.digest(found.rows)==C.digest(record.rows)
        and (not phase or found.phase==phase)
end
function M:read(account)
    if not C.account(account) then return nil,'account_unavailable' end
    return self.coverage:_access(function(db)
        local rows=query(db,[[SELECT attempt,scope,phase,metadata,rows,request_hash,created FROM offline_time_records
            WHERE scope=? AND phase IN ('prepared','claimed','unknown','confirmed')]],account)
        assert(#rows<=1,'corrupt');return {record=self:_decode(rows[1])}
    end)
end
function M:pending(account)
    local value,reason=self:read(account);return value and value.record,reason
end
function M:owns(record,phase)
    if type(record)~='table' or not C.account(record.account) or not C.attempt(record.attempt) then return false end
    return self.coverage:_access(function(db) return self:_matches(self:_record(db,record.attempt),record,phase) end)
end
local function ranges(db,account,row)
    local result=query(db,[[SELECT start_time,end_time FROM coverage WHERE (scope=? OR scope='') AND start_time<? AND end_time>?
        UNION ALL SELECT start_time,end_time FROM offline_time_seals WHERE scope=? AND start_time<? AND end_time>?]],
        account,row.start_time+row.duration,row.start_time,account,row.start_time+row.duration,row.start_time)
    for _i,value in ipairs(result) do value[1],value[2]=tonumber(value[1]),tonumber(value[2]) end
    return result
end
function M:begin(account,selection,metadata)
    if not C.account(account) or type(selection)~='table' or type(metadata)~='table' or not C.hash(metadata.request_hash) then return nil,'invalid' end
    return self.coverage:_access(function(db,since)
        assert(C.array(selection.rows,1,100) and C.array(selection.parts,1,100),'invalid')
        assert(#query(db,"SELECT attempt FROM offline_time_records WHERE scope=? AND phase IN ('prepared','claimed','unknown','confirmed')",account)==0,'pending')
        assert(#query(db,'SELECT attempt FROM offline_time_records LIMIT 50000')<50000,'full')
        assert(tonumber(query(db,'SELECT COUNT(*) FROM offline_time_seals')[1][1])+#selection.parts<=50000,'full')
        assert(C.digest(selection.rows)==selection.rows_hash and C.digest(selection.parts)==selection.parts_hash,'changed')
        local fresh,by_id={},{}
        for _i,row in ipairs(selection.rows) do
            assert(C.verified(row,self.now()) and not by_id[row.id],'source');fresh[row.id]=ranges(db,account,row);by_id[row.id]=row
        end
        local function covered(id,stamp)
            assert(by_id[id],'source')
            for _i,range in ipairs(fresh[id]) do if range[1]<=stamp and stamp<range[2] then return true end end
            return false
        end
        for _i,part in ipairs(selection.parts) do
            assert(C.part(part) and by_id[part.row_id] and part.start_time>=since,'unverified')
            for stamp=part.start_time,part.start_time+part.duration-1 do assert(not covered(part.row_id,stamp),'changed') end
        end
        local attempt='offtime-v1:'..self.nonce();assert(C.attempt(attempt),'nonce')
        local claimed=assert(self.ledger:claim_parts(account,selection.rows,selection.parts,attempt,covered),'ledger')
        local encoded_metadata,encoded_rows=self.codec:json_encode(metadata),self.codec:json_encode(claimed)
        assert(#encoded_metadata<=65536 and #encoded_rows<=65536,'limit')
        query(db,'INSERT INTO offline_time_records VALUES(?,?,?,?,?,?,?)',attempt,account,'prepared',encoded_metadata,encoded_rows,metadata.request_hash,self.now())
        for _i,row in ipairs(claimed) do query(db,'INSERT INTO offline_time_seals VALUES(?,?,?,?)',account,attempt,row.start_time,row.start_time+row.duration) end
        return assert(self:_record(db,attempt))
    end)
end
function M:claim(record)
    return self.coverage:_access(function(db)
        assert(self:_matches(self:_record(db,record.attempt),record,'prepared'),'replaced')
        assert(self.ledger:owns(record.account,record.rows,record.attempt)==true,'ledger')
        query(db,"UPDATE offline_time_records SET phase='claimed' WHERE attempt=?",record.attempt);return true
    end)
end
function M:outcome(record,confirmed)
    if type(confirmed)~='boolean' then return false end
    return self.coverage:_access(function(db)
        assert(self:_matches(self:_record(db,record.attempt),record,'claimed'),'replaced')
        query(db,'UPDATE offline_time_records SET phase=? WHERE attempt=?',confirmed and 'confirmed' or 'unknown',record.attempt)
        return true
    end)
end
function M:cancel_prepared(record)
    return self.coverage:_access(function(db)
        assert(self:_matches(self:_record(db,record.attempt),record,'prepared'),'replaced')
        assert(self.ledger:release_unsent(record.account,record.rows,record.attempt)==true,'ledger')
        query(db,'DELETE FROM offline_time_seals WHERE scope=? AND attempt=?',record.account,record.attempt)
        query(db,'DELETE FROM offline_time_records WHERE attempt=?',record.attempt);return true
    end)
end
function M:settle(record)
    return self.coverage:_access(function(db)
        assert(self:_matches(self:_record(db,record.attempt),record,'confirmed'),'replaced')
        assert(self.ledger:settle_confirmed(record.account,record.rows,record.attempt)==true,'ledger')
        -- Successful intervals merge into a permanent no-duplicate union.
        for _i,row in ipairs(record.rows) do
            local first,last=row.start_time,row.start_time+row.duration
            local existing=query(db,[[SELECT start_time,end_time FROM offline_time_seals
                WHERE scope=? AND attempt='' AND start_time<=? AND end_time>=?]],record.account,last,first)
            for _j,item in ipairs(existing) do first,last=math.min(first,tonumber(item[1])),math.max(last,tonumber(item[2])) end
            query(db,"DELETE FROM offline_time_seals WHERE scope=? AND attempt='' AND start_time<=? AND end_time>=?",record.account,last,first)
            query(db,'INSERT INTO offline_time_seals VALUES(?,?,?,?)',record.account,'',first,last)
        end
        query(db,'DELETE FROM offline_time_seals WHERE scope=? AND attempt=?',record.account,record.attempt)
        query(db,'DELETE FROM offline_time_records WHERE attempt=?',record.attempt);return true
    end)
end
function M:retire_unknown(record)
    return self.coverage:_access(function(db)
        local found=self:_record(db,record.attempt)
        assert(self:_matches(found,record) and (found.phase=='unknown' or found.phase=='claimed'),'replaced')
        assert(self.ledger:mark_unknown(record.account,record.rows,record.attempt)==true,'ledger')
        query(db,"UPDATE offline_time_records SET phase='retired' WHERE attempt=?",record.attempt);return true
    end)
end
-- Reopening never retries a dispatch. A prepared record is provably unsent;
-- confirmed bookkeeping is idempotent; claimed/unknown records stay isolated.
function M:recover(account)
    local record,reason=self:pending(account);if reason then return nil,reason end
    if not record then return true end
    if record.phase=='prepared' then return self:cancel_prepared(record) end
    if record.phase=='confirmed' then return self:settle(record) end
    return true
end
return M
