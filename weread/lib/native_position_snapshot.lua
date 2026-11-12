-- Read-only native inputs for a source-bound operation. No document handles,
-- renewal, persistence or write route; the sender rechecks these observations.
local P=require('weread.lib.native_position_protocol')
local C=require('weread.lib.native_position_contract')
local Access=require('weread.lib.native_read_access')
local Shelf=require('weread.lib.shelf_flag_change_contract')
local Auth=require('weread.lib.native_authorization')
local BASE='https://i.weread.qq.com'
local M={}
function M.matches_expected(point,expected)
    expected=type(expected)=='table' and (expected.web or expected) or nil
    if not expected or expected.has_chapter_offset~=true or expected.has_chapter_index~=true
        or expected.source~='web' and expected.source~='native' then return false end
    for _i,key in ipairs({'book_id','chapter_uid'}) do if tostring(point[key])~=tostring(expected[key]) then return false end end
    return point.chapter_idx==expected.chapter_idx and point.chapter_offset==expected.chapter_offset
        and point.raw_percent==expected.raw_percent
end
function M.run(client,settings,selected,input,gate)
    local function current() return gate:valid() and Access.matches(settings,selected) end
    if not current() then return {kind='unavailable'} end
    local auth=Auth:new(client,{expected_vid=selected.scope.vid,is_current=current})
    local ok,value=pcall(function()
        local desired=P.point(input.candidate)
        local info=auth:_request('position_metadata',BASE..'/book/info?bookId='..desired.book_id,nil,selected.credentials)
        assert(P.id(info.bookId)==desired.book_id,'native_position/metadata')
        local version
        for _i,key in ipairs({'bookVersion','version'}) do if info[key]~=nil then
            assert(P.integer(info[key],0,2147483647) and (version==nil or version==info[key]),'native_position/version');version=info[key]
        end end
        assert(version~=nil,'native_position/version')
        local snapshot=P.snapshot(auth:_request('position_progress',BASE..'/book/getProgress?bookId='..desired.book_id,nil,selected.credentials),desired.book_id)
        assert(M.matches_expected(snapshot.position,input.expected_remote),'native_position/remote_changed')
        local shelf=auth:read_shelf(selected.credentials)
        local metadata={book_id=desired.book_id,before=snapshot.position,desired=desired,counts=snapshot.counts,
            version=version,shelf_sha256=Shelf.state_hash(shelf),source_sha256=input.source.raw_sha256,
            file_id=input.source.file_id,basis='raw_txt_utf16'}
        assert(C.valid(metadata) and current(),'native_position/metadata');return metadata
    end)
    auth:cancel()
    if ok then return {kind='ready',metadata=value} end
    if type(value)=='string' and value:find('native_position/remote_changed',1,true) then return {kind='changed'} end
    if require('weread.lib.native_position_task').expired(value) then return {kind='login',authentication_expired=true} end
    return {kind='unavailable'}
end
return M
