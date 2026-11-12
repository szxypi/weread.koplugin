-- Explicit absence is an observation, never a chapter coordinate or a restore
-- target. Keep ordinary positive-point hashes and validation unchanged.
local P=require('weread.lib.native_position_protocol')
local Remote=require('weread.lib.remote_progress')
local Hash=require('weread.lib.thought_edit_contract')
local M={}
local fields={kind=true,book_id=true,chapter_uid=true,chapter_offset=true,raw_percent=true,index_present=true,summary_present=true}
function M.none(value)
    if type(value)~='table' or value.kind~='no_chapter' or type(value.book_id)~='string' or P.id(value.book_id)~=value.book_id
        or value.chapter_uid~='0' or value.chapter_offset~=0 or value.raw_percent~=0
        or type(value.index_present)~='boolean' or type(value.summary_present)~='boolean'
        or value.index_present and value.chapter_idx~=0 or not value.index_present and value.chapter_idx~=nil
        or value.summary_present and value.summary~='' or not value.summary_present and value.summary~=nil then return false end
    for key in pairs(value) do
        if not fields[key] and not (key=='chapter_idx' and value.index_present) and not (key=='summary' and value.summary_present) then return false end
    end
    return true
end
function M.from(raw,id)
    local p,reason,provided=Remote.project(raw,id,'native')
    if reason or not p or not provided.chapter_uid or tostring(p.chapter_uid)~='0' or p.raw_percent~=0
        or not provided.chapter_offset or p.chapter_offset~=0 or p.summary~='' or provided.chapter_idx and p.chapter_idx~=0 then return nil end
    local value={kind='no_chapter',book_id=id,chapter_uid='0',chapter_offset=0,raw_percent=0,
        index_present=provided.chapter_idx,summary_present=provided.summary}
    if value.index_present then value.chapter_idx=0 end
    if value.summary_present then value.summary='' end
    return M.none(value) and value or nil
end
function M.valid(value)
    if M.none(value) then return true end
    if type(value)~='table' then return false end
    local allowed={book_id=true,chapter_uid=true,chapter_idx=true,chapter_offset=true,raw_percent=true,summary=true}
    local n=0;for key in pairs(value) do if not allowed[key] then return false end;n=n+1 end
    return n==6 and pcall(P.point,value)
end
function M.hash(value)
    assert(M.valid(value),'native_position/cloud_state')
    if not M.none(value) then return P.point_hash(value) end
    return Hash.digest({'native-no-chapter-v1',value.book_id,value.index_present and 'present' or 'absent',value.summary_present and 'present' or 'absent'})
end
function M.equal(a,b) return M.valid(a) and M.valid(b) and M.hash(a)==M.hash(b) end
function M.snapshot(raw,id)
    local value=M.from(raw,id)
    if value then return {position=value,counts=P.counts(assert(Remote.node(raw,id)))} end
    return P.snapshot(raw,id)
end
function M.zero(counts)
    local ok,value=pcall(P.counts,counts)
    return ok and value.readingTime==0 and value.recordReadingTime==0 and value.ttsTime==0
end
return M
