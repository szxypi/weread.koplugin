-- One zero-time native position operation; source ownership is supplied by
-- the caller's captured document context. Never renew or repeat a POST.
local P=require('weread.lib.native_position_protocol')
local State=require('weread.lib.native_cloud_state')
local C=require('weread.lib.native_position_contract')
local Signing=require('weread.lib.readtime_protocol')
local Shelf=require('weread.lib.shelf_flag_change_contract')
local Auth=require('weread.lib.native_authorization')
local Access=require('weread.lib.native_read_access')
local BASE='https://i.weread.qq.com'
local M={}
function M.expired(reason)
    return reason=='native_auth/position_metadata/http_401' or reason=='native_auth/position_progress/http_401'
        or reason=='native_auth/position_feature/http_401' or reason=='native_auth/shelf/http_401'
end
local function same_snapshot(snapshot,point,counts) return State.equal(snapshot.position,point) and P.same_counts(snapshot.counts,counts) end
local function snapshot(auth,selected,metadata,info)
    if info then
        local value=auth:_request('position_metadata',BASE..'/book/info?bookId='..metadata.book_id,nil,selected.credentials)
        assert(P.id(value.bookId)==metadata.book_id,'native_position/metadata')
        local count=0
        for _i,key in ipairs({'bookVersion','version'}) do if value[key]~=nil then
            assert(P.integer(value[key],0,2147483647) and value[key]==metadata.version,'native_position/version');count=count+1
        end end
        assert(count>0,'native_position/version')
    end
    local raw=auth:_request('position_progress',BASE..'/book/getProgress?bookId='..metadata.book_id,nil,selected.credentials)
    local shelf=auth:read_shelf(selected.credentials)
    assert(Shelf.state_hash(shelf)==metadata.shelf_sha256,'native_position/shelf_changed')
    return State.snapshot(raw,metadata.book_id)
end
local function current(settings,selected,record,store,metadata,options,read_only)
    if type(options.is_current)~='function' or not selected or selected.renewal_pending or not P.credentials(selected.credentials)
        or record.account~=C.account_key(selected.scope.vid) or not read_only and selected.scope.epoch~=record.epoch
        or not Access.matches(settings,selected) or not store:owns(record) or not C.same(record.metadata,metadata) then return false end
    local ok,valid=pcall(options.is_current);return ok and valid==true
end
function M.run(client,settings,selected,record,store,options)
    options=options or {};local out={kind='unconfirmed',attempted=false,acknowledged=false,readbacks=0}
    local valid,metadata=pcall(function()
        assert(C.valid(record.metadata));return client:json_decode(client:json_encode(record.metadata))
    end)
    if not valid or not current(settings,selected,record,store,metadata,options) then out.kind='unavailable';return out end
    local function owns() return current(settings,selected,record,store,metadata,options) end
    local auth=Auth:new(client,{expected_vid=selected.scope.vid,is_current=owns})
    local ok,reason=pcall(function()
        assert(store:owns(record,'prepared'),'native_position/pending')
        assert(same_snapshot(snapshot(auth,selected,metadata,true),metadata.before,metadata.counts),'native_position/changed')
        if P.equal(metadata.before,metadata.desired) then out.kind='noop';return end
        local guest=Signing.guest_token(auth:_request('position_feature',BASE..'/feature?synckey=0',nil,selected.credentials))
        local now=options.now and options.now() or os.time()
        local random=options.random and options.random() or tonumber(auth.digits(3))
        local zone=options.zone or Signing.time_zone(now)
        local empty=client:json_decode('[]');assert(client:json_encode(empty)=='[]','native_position/array')
        local body=P.body(selected.credentials,metadata.desired,metadata.version,guest,now,random,zone,nil,empty)
        local ack=auth:_request('position_write',BASE..'/book/read',body,selected.credentials,nil,function()
            assert(owns(),'native_position/stale')
            local claimed=store:advance(record,'prepared','pending');assert(claimed,'native_position/claim')
            record=claimed;out.attempted=true
        end)
        out.acknowledged=P.confirmed(ack)
        if out.acknowledged then
            local saved=store:advance(record,'pending','acknowledged');assert(saved,'native_position/ack_save');record=saved
        end
        local sleep=options.sleep or function(seconds) require('socket').sleep(seconds) end
        for attempt=1,out.acknowledged and 4 or 1 do
            if attempt>1 then sleep(1) end
            assert(owns(),'native_position/stale');local observed=snapshot(auth,selected,metadata,false);out.readbacks=attempt
            if same_snapshot(observed,metadata.desired,metadata.counts) then
                if out.acknowledged then
                    local verified=store:advance(record,'acknowledged','verified');assert(verified,'native_position/verify_save')
                    record=verified;out.kind='confirmed'
                end
                return
            end
            assert(same_snapshot(observed,metadata.before,metadata.counts),'native_position/unknown_readback')
        end
    end)
    auth:cancel()
    if not ok and not out.attempted then
        out.kind=M.expired(reason) and 'login' or 'unavailable'
        if out.kind=='login' then out.authentication_expired=true end
    end
    return out
end
function M.resolve(client,settings,selected,record,store,options)
    options=options or {};local out={kind='unconfirmed',attempted=false,acknowledged=record and record.phase=='acknowledged',readbacks=0}
    if not record or not C.valid(record.metadata) or not current(settings,selected,record,store,record.metadata,options,true) then return out end
    if record.phase~='acknowledged' and record.phase~='verified' then return out end
    local auth=Auth:new(client,{expected_vid=selected.scope.vid,is_current=function() return current(settings,selected,record,store,record.metadata,options,true) end})
    pcall(function()
        for _i=1,2 do
            assert(same_snapshot(snapshot(auth,selected,record.metadata,true),record.metadata.desired,record.metadata.counts),'native_position/unconfirmed')
            out.readbacks=_i
        end
        if record.phase=='acknowledged' then
            local saved=store:advance(record,'acknowledged','verified');assert(saved,'native_position/verify_save');record=saved
        end
        out.acknowledged,out.kind=true,'confirmed'
    end)
    auth:cancel();return out
end
return M
