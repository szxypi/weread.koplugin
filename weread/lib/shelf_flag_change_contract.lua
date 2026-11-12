-- Private-reading request and complete visible-state preservation. Python
-- verified both directions and the actual succ=1 receipts before this module.
local Base=require('weread.lib.finish_change_contract')
local Hash=require('weread.lib.thought_edit_contract')
local Remote=require('weread.lib.remote_progress')
local M={id=Base.id,flags=Base.flags,position_hash=Base.position_hash}
local function fail(reason) error('shelf_flag_change/' .. reason,0) end
local function array(value)
    if type(value)~='table' then return false end
    local count=0
    for key in pairs(value) do
        if type(key)~='number' or key%1~=0 or key<1 or key>#value then return false end
        count=count+1
    end
    return count==#value
end
local function scalar(value,positive)
    if type(value)=='string' then return value end
    if type(value)=='number' and value==value and value%1==0 and math.abs(value)<=9007199254740991 and (not positive or value>0) then return string.format('%.0f',value) end
end
function M.groups_hash(source)
    local rows=source.archive or {};if not array(rows) or #rows>10000 then fail('groups') end
    local groups,seen={},{}
    for _i,row in ipairs(rows) do
        if type(row)~='table' or row.name~=nil and type(row.name)~='string' then fail('groups') end
        local key=row.archiveId;if key==nil then key=row.id end
        key=scalar(key,false) or ''
        local name=row.name or '';local identity=Hash.digest({key,name})
        if seen[identity] then fail('groups') end;seen[identity]=true
        local members={}
        for _j,field in ipairs({'bookIds','albumIds'}) do
            local values=row[field] or {};if not array(values) then fail('groups') end
            local normalized={}
            for _k,value in ipairs(values) do local id=scalar(value,true);if not id then fail('groups') end;normalized[#normalized+1]=id end
            table.sort(normalized);members[#members+1]=normalized
        end
        local pin=row.isTop;local state=pin==nil and 'm' or (pin==true or pin==1) and '1' or (pin==false or pin==0) and '0' or 'i'
        if state=='i' then fail('groups') end
        groups[#groups+1]={key=key,name=name,members=members,pin=state}
    end
    table.sort(groups,function(a,b) if a.key~=b.key then return a.key<b.key end;return a.name<b.name end)
    local parts={'shelf-flag-groups-v1',#groups}
    for _i,row in ipairs(groups) do
        parts[#parts+1]=row.key;parts[#parts+1]=row.name;parts[#parts+1]=row.pin
        for _j,values in ipairs(row.members) do parts[#parts+1]=#values;for _k,value in ipairs(values) do parts[#parts+1]=value end end
    end
    return Hash.digest(parts)
end
function M.state_hash(source) return Hash.digest({'shelf-flag-state-v1',Base.flags_hash(Base.flags(source)),M.groups_hash(source)}) end
function M.point(progress,id)
    local value,reason=Remote.project(progress,id,'native')
    if reason or not value or not value.has_chapter_offset or value.chapter_uid==nil then fail('position') end
    local uid=tostring(value.chapter_uid)
    if uid=='0' then
        if value.chapter_idx~=0 or value.chapter_offset~=0 or value.raw_percent~=0 then fail('position') end
    elseif not M.id(uid) then fail('position') end
    return {chapter_uid=uid,chapter_idx=value.chapter_idx,chapter_offset=value.chapter_offset,percent=value.raw_percent}
end
function M.request(id,desired)
    if not M.id(id) or type(desired)~='boolean' then fail('target') end
    return {bookIds={id},private=desired and 1 or 0}
end
local function request_hash(id,desired) return Hash.digest({'shelf-flag-request-v1','private',id,desired and 1 or 0}) end
function M.make(source,progress,id,desired)
    local body=M.request(id,desired);local snapshot=M.flags(source);local row=snapshot[id]
    local before=row and row.private.value
    if type(before)~='boolean' then fail('unknown') end
    for _i,item in pairs(snapshot) do for _j,flag in pairs(item) do if flag.reason=='invalid' then fail('invalid_flag') end end end
    local point=M.point(progress,id);local groups=M.groups_hash(source);local before_hash=M.state_hash(source)
    row.private={value=desired}
    local after_hash=Hash.digest({'shelf-flag-state-v1',Base.flags_hash(snapshot),groups})
    return {metadata={kind='private',book_id=id,before=before,desired=desired,before_hash=before_hash,after_hash=after_hash,
        position_hash=M.position_hash(point),request_hash=request_hash(id,desired)},body=body}
end
function M.valid_metadata(value)
    if type(value)~='table' or value.kind~='private' or not M.id(value.book_id) or type(value.before)~='boolean' or type(value.desired)~='boolean' then return false end
    local allowed={kind=true,book_id=true,before=true,desired=true,before_hash=true,after_hash=true,position_hash=true,request_hash=true}
    local count=0;for key in pairs(value) do if not allowed[key] then return false end;count=count+1 end
    if count~=8 then return false end
    for _i,key in ipairs({'before_hash','after_hash','position_hash','request_hash'}) do if not Hash.hash(value[key]) then return false end end
    return value.request_hash==request_hash(value.book_id,value.desired)
end
function M.same(left,right)
    if not M.valid_metadata(left) or not M.valid_metadata(right) then return false end
    for key,value in pairs(left) do if right[key]~=value then return false end end;return true
end
function M.check(source,progress,metadata)
    if not M.valid_metadata(metadata) then fail('metadata') end
    return M.state_hash(source)==metadata.after_hash and M.position_hash(M.point(progress,metadata.book_id))==metadata.position_hash
end
return M
