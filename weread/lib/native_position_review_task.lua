-- Two current cloud observations. No POST, renewal or journal mutation.
local P=require('weread.lib.native_position_protocol')
local C=require('weread.lib.native_position_contract')
local O=require('weread.lib.native_position_observation')
local Access=require('weread.lib.native_read_access')
local Auth=require('weread.lib.native_authorization')
local Shelf=require('weread.lib.shelf_flag_change_contract')
local BASE='https://i.weread.qq.com'
local M={}
function M.current(journal,record)
    local row=journal:read()
    return row and row.phase==record.phase and row.revision==record.revision and row.id==record.id
        and row.account==record.account and row.epoch==record.epoch and C.same(row.metadata,record.metadata) or false
end
function M.run(client,settings,access,record,journal,gate)
    local out={kind='unavailable',readbacks=0}
    if type(record)~='table' or not C.valid(record.metadata) or type(access)~='table' or type(access.scope)~='table'
        or type(gate)~='table' or type(gate.valid)~='function' then return out end
    local function current()
        return gate:valid() and not access.renewal_pending and Access.matches(settings,access)
            and record.account==C.account_key(access.scope.vid) and M.current(journal,record)
    end
    if not current() then return out end
    local auth=Auth:new(client,{expected_vid=access.scope.vid,is_current=current})
    local ok,reason=pcall(function()
        local previous
        for _i=1,2 do
            local id=record.metadata.book_id
            local info=auth:_request('position_metadata',BASE..'/book/info?bookId='..id,nil,access.credentials)
            assert(P.id(info.bookId)==id,'native_position/metadata');local version
            for _j,key in ipairs({'version','bookVersion'}) do if info[key]~=nil then
                assert(P.integer(info[key],0,2147483647) and (version==nil or version==info[key]),'native_position/version');version=info[key]
            end end
            assert(version~=nil,'native_position/version')
            local snapshot=P.snapshot(auth:_request('position_progress',BASE..'/book/getProgress?bookId='..id,nil,access.credentials),id)
            local value={point=snapshot.position,counts=snapshot.counts,version=version,shelf_sha256=Shelf.state_hash(auth:read_shelf(access.credentials))}
            assert(O.valid(value) and current(),'native_position/stale')
            out.readbacks=_i
            if previous and not O.same(value,previous) then out.kind='changed';return end
            previous=value
        end
        out.kind,out.observation='observed',previous
    end)
    auth:cancel()
    if not ok and require('weread.lib.native_position_task').expired(reason) then out.kind='login' end
    return out
end
return M
