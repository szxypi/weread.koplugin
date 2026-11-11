-- Pure ownership/interval binding for the offline queue, not a transport grant.
local Crypto=require('weread.lib.crypto')
local Protocol=require('weread.lib.readtime_protocol')
local M={}
function M.integer(v,low,high) return type(v)=='number' and v==v and v%1==0 and v>=low and v<=high end
function M.hash(v) return type(v)=='string' and #v==64 and v:match('^[a-f0-9]+$')~=nil end
function M.account(v) return type(v)=='string' and #v==20 and v:match('^[a-f0-9]+$')~=nil end
function M.id(v) return type(v)=='string' and #v<=20 and v:match('^[1-9]%d*$')~=nil end
function M.attempt(v) return type(v)=='string' and #v==43 and v:match('^offtime%-v1:[a-f0-9]+$')~=nil end
function M.array(v,minimum,maximum)
    if type(v)~='table' or not M.integer(#v,minimum,maximum) then return false end
    local count=0
    for key in pairs(v) do if not M.integer(key,1,#v) then return false end;count=count+1 end
    return count==#v
end
local ROW_KEYS={id=true,book_id=true,start_time=true,duration=true,time_zone=true,book_version=true,file_id=true,version_source=true}
local PART_KEYS={row_id=true,start_time=true,duration=true}
local function exact_keys(value,keys)
    if type(value)~='table' then return false end
    for key in pairs(value) do if not keys[key] then return false end end
    for key in pairs(keys) do if value[key]==nil then return false end end
    return true
end
local function encode(v,depth)
    assert(depth<16,'readtime_transfer/depth')
    if type(v)=='string' then return 's'..#v..':'..v end
    if type(v)=='boolean' then return v and 't;' or 'f;' end
    if type(v)=='number' then
        assert(v==v and math.abs(v)<math.huge,'readtime_transfer/number')
        return 'n'..(v==0 and '0' or string.format('%.17g',v))..';'
    end
    assert(type(v)=='table','readtime_transfer/value')
    local keys,count,numeric={},0,true
    for key in pairs(v) do count=count+1;numeric=numeric and M.integer(key,1,#v);keys[#keys+1]=key end
    local result={};if numeric and count>0 and count==#v then
        result[1]='a'..count..':'
        for _i,item in ipairs(v) do result[#result+1]=encode(item,depth+1) end
    else
        table.sort(keys);result[1]='m'..count..':'
        for _i,key in ipairs(keys) do assert(type(key)=='string');result[#result+1]=encode(key,depth+1);result[#result+1]=encode(v[key],depth+1) end
    end
    return table.concat(result)
end
function M.digest(v) return Crypto.sha256_hex(encode(v,0)) end
function M.row(row)
    return exact_keys(row,ROW_KEYS) and M.integer(row.id,1,2^53-1) and type(row.book_id)=='string' and #row.book_id>0 and #row.book_id<=256
        and M.integer(row.start_time,1,4102444800) and M.integer(row.duration,1,60)
        and row.start_time+row.duration<=4102444800 and M.integer(row.book_version,0,2147483647)
        and type(row.file_id)=='string' and #row.file_id<=64 and type(row.version_source)=='string' and #row.version_source<=32
        and type(row.time_zone)=='string' and #row.time_zone<=6
end
function M.part(part) return exact_keys(part,PART_KEYS) and M.integer(part.row_id,1,2^53-1)
    and M.integer(part.start_time,1,4102444800) and M.integer(part.duration,1,60) end
function M.verified(row,now)
    return M.row(row) and M.id(row.book_id) and row.book_version>0 and M.hash(row.file_id)
        and row.version_source=='epub_snapshot' and row.start_time+row.duration<=now and pcall(Protocol.zone,row.time_zone)
end
function M.protocol_rows(rows)
    local result={}
    for _i,row in ipairs(rows) do
        result[#result+1]={start_time=row.start_time,duration=row.duration,time_zone=row.time_zone,book_version=row.book_version}
    end
    return result
end
function M.select(rows,coverage,now,book_id)
    assert(M.array(rows,0,100) and type(coverage)=='table' and M.array(coverage.parts,0,6000))
    local by_id={};for _i,row in ipairs(rows) do assert(M.row(row) and not by_id[row.id]);by_id[row.id]=row end
    local selected={rows={},parts={},seconds=0};local seen={}
    for _i,part in ipairs(coverage.parts) do
        assert(M.part(part))
        local row=assert(by_id[part.row_id])
        assert(M.integer(part.start_time,row.start_time,row.start_time+row.duration-1)
            and M.integer(part.duration,1,row.start_time+row.duration-part.start_time))
        if M.verified(row,now) and (not book_id or row.book_id==book_id) and selected.seconds<600 and #selected.parts<100 then
            if not selected.book_id then
                selected.book_id,selected.file_id,selected.book_version,selected.time_zone=row.book_id,row.file_id,row.book_version,row.time_zone
            end
            if row.book_id==selected.book_id and row.file_id==selected.file_id and row.book_version==selected.book_version and row.time_zone==selected.time_zone then
                local duration=math.min(part.duration,600-selected.seconds)
                selected.parts[#selected.parts+1]={row_id=row.id,start_time=part.start_time,duration=duration}
                selected.seconds=selected.seconds+duration
                if not seen[row.id] then seen[row.id]=true;selected.rows[#selected.rows+1]=row end
            end
        end
    end
    if not selected.book_id then return nil end
    local protocol={}
    for _i,part in ipairs(selected.parts) do
        local row=by_id[part.row_id]
        protocol[#protocol+1]={start_time=part.start_time,duration=part.duration,time_zone=row.time_zone,book_version=row.book_version}
    end
    Protocol.validate_rows(protocol,selected.book_id,now);selected.protocol_rows=protocol
    selected.rows_hash=M.digest(selected.rows);selected.parts_hash=M.digest(selected.parts)
    return selected
end
return M
