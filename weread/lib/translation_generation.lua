-- Single-chapter official translation request model. This module does not
-- authorize, persist or dispatch requests; callers must establish all three.
-- Request contract based on MiuRead c1893562aa25a870b8dd076d7be062a3348f823e,
-- Copyright (C) 2026 MiuRead contributors, AGPL-3.0-only.
local M={}
local function integer(value,minimum,maximum)
    return type(value)=='number' and value==value and value%1==0 and value>=minimum and value<=maximum
end
local function identity(value)
    return type(value)=='string' and #value<=20 and value:match('^[1-9]%d*$')~=nil
end
local function digest(value)
    return type(value)=='string' and #value==64 and value:match('^[a-f0-9]+$')~=nil
end
local fields={owner=true,book_id=true,chapter_uid=true,book_version=true,translate_version=true,
    grant_sha256=true,catalog_sha256=true,source_sha256=true,baseline_sha256=true}
function M.valid(plan)
    if type(plan)~='table' then return false end
    for key in pairs(plan) do if not fields[key] then return false end end
    return identity(plan.owner) and identity(plan.book_id)
        and integer(plan.chapter_uid,1,2147483647) and integer(plan.book_version,0,2147483647)
        and integer(plan.translate_version,0,2147483647) and digest(plan.grant_sha256)
        and digest(plan.catalog_sha256) and digest(plan.source_sha256) and digest(plan.baseline_sha256)
end
function M.mode_query(plan)
    if not M.valid(plan) then return nil end
    return {cbid=plan.book_id,transFormat='epubTranslate',transType='epubTranslate'}
end
function M.generation_body(plan,codec)
    if not M.valid(plan) or type(codec)~='table' then return nil end
    local ok,empty=pcall(function()
        local value=codec:json_decode('[]')
        assert(type(value)=='table' and next(value)==nil and codec:json_encode(value)=='[]')
        return value
    end)
    if not ok then return nil end
    return {bookId=plan.book_id,read={{uid=plan.chapter_uid,translateVersion=plan.translate_version}},
        reference={uid=plan.chapter_uid,texts=empty},freeTrial=0}
end
local function success(value,plan)
    if type(value)~='table' then return false end
    for _,key in ipairs({'errcode','errCode','code'}) do
        if value[key]~=nil and value[key]~=0 then return false end
    end
    if value.succ~=nil and value.succ~=true and value.succ~=1 then return false end
    for _,key in ipairs({'bookId','book_id'}) do
        if value[key]~=nil and tostring(value[key])~=plan.book_id then return false end
    end
    if value.vid~=nil and tostring(value.vid)~=plan.owner then return false end
    return true
end
function M.mode_ack(value,plan)
    return M.valid(plan) and success(value,plan) and (value.succ==true or value.succ==1) or false
end
local function array_length(value)
    if type(value)~='table' then return nil end
    local count=0
    for key in pairs(value) do
        if not integer(key,1,2) then return nil end
        count=count+1
    end
    for index=1,count do if value[index]==nil then return nil end end
    return count
end
function M.status(value,plan)
    if not M.valid(plan) then return nil end
    for _=1,4 do
        if not success(value,plan) then return nil end
        if value.stopPoll~=nil or value.curStatus~=nil or value.translationProgress~=nil then break end
        local child,count=nil,0
        for _,key in ipairs({'data','result','payload'}) do
            if value[key]~=nil then child=value[key];count=count+1 end
        end
        if count~=1 or type(child)~='table' then return nil end
        value=child
    end
    if not success(value,plan) then return nil end
    local stopped=value.stopPoll
    if stopped==0 then stopped=false elseif stopped==1 then stopped=true end
    if stopped~=nil and type(stopped)~='boolean' then return nil end
    if value.translationProgress~=nil and not integer(value.translationProgress,0,100) then return nil end
    if stopped==nil then if value.translationProgress==nil then return nil end;stopped=false end
    local rows=value.curStatus
    if rows==nil then rows={} end
    local count=array_length(rows);if not count then return nil end
    local seen,version={},nil
    for index=1,count do
        local row=rows[index]
        if not success(row,plan) or not integer(row.uid,1,2147483647) or seen[row.uid]
            or row.uid~=plan.chapter_uid or not integer(row.translateVersion,0,2147483647)
            or row.translateVersion<plan.translate_version then return nil end
        seen[row.uid]=true;version=row.translateVersion
    end
    if value.tips~=nil and (type(value.tips)~='string' or #value.tips>8192) then return nil end
    if stopped and version and version>0 then return {kind='ready',version=version} end
    return {kind=stopped and 'stopped_unavailable' or 'pending',version=version}
end
return M
