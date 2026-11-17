-- Worker-owned one-shot transfer. No UI or inherited native-document calls.
-- ACK is saved before readbacks; only two stable accounting observations settle.
local C=require('weread.lib.readtime_transfer_contract')
local P=require('weread.lib.native_position_protocol')
local Account=require('weread.lib.native_position_contract').account_key
local Signing=require('weread.lib.readtime_protocol')
local Accounting=require('weread.lib.readtime_accounting')
local Stats=require('weread.lib.statistics_data')
local Native=require('weread.lib.native_read_access')
local Web=require('weread.lib.read_access')
local Remote=require('weread.lib.remote_progress')
local Source=require('weread.lib.readtime_source')
local Shelf=require('weread.lib.shelf_flag_change_contract')
local Auth=require('weread.lib.native_authorization')
local BASE='https://i.weread.qq.com'
local M={}
local function web_point(raw,book)
    local point,reason,provided=Remote.project(raw,book,'web');local node=Remote.node(raw,book)
    assert(not reason and point and node and provided.chapter_uid and provided.chapter_idx and provided.chapter_offset and provided.summary,'readtime_transfer/web_position')
    point.summary=node.summary;return P.point_hash(point)
end
function M.run(client,settings,selected,web,selection,references,journal,options)
    options=options or {};local now=options.now or os.time;local sleep=options.sleep or function(s) require('socket').sleep(s) end
    local out={kind='unavailable',attempted=false,acknowledged=false,readbacks=0,stable_reads=0,removed_zero_buckets=0}
    local record,metadata,body,auth
    local function current()
        if not selected or selected.renewal_pending or not P.credentials(selected.credentials) or not web or not web.web
            or type(options.is_current)~='function' or not Native.matches(settings,selected) or not Web.matches(settings,web) then return false end
        local ok,v=pcall(options.is_current)
        return ok and v==true and (not record or journal:owns(record)==true)
    end
    if not current() then return out end
    auth=Auth:new(client,{expected_vid=selected.scope.vid,is_current=current})
    local observe=options.observe_source or Source.observe
    local ok,reason=pcall(function()
        assert(type(selection)=='table' and selection.rows_hash==C.digest(selection.rows) and selection.parts_hash==C.digest(selection.parts),'readtime_transfer/selection')
        local account=Account(selected.scope.vid);assert(C.account(account),'readtime_transfer/account')
        assert(options.account==account,'readtime_transfer/account')
        local pending,why=journal:pending(account);assert(not pending and not why,'readtime_transfer/pending')
        local rebuilt=assert(C.select(selection.rows,{parts=selection.parts},now(),selection.book_id),'readtime_transfer/selection')
        for _i,key in ipairs({'book_id','file_id','book_version','time_zone','seconds','rows_hash','parts_hash'}) do
            assert(rebuilt[key]==selection[key],'readtime_transfer/selection')
        end
        assert(C.digest(rebuilt.protocol_rows)==C.digest(selection.protocol_rows),'readtime_transfer/intervals')
        local selection_hash=C.digest(selection)
        local window=Accounting.window(selection.protocol_rows,selection.book_id,now())
        assert(window.seconds==selection.seconds and window.version==selection.book_version and C.hash(selection.file_id),'readtime_transfer/source')
        local source=observe(client,web,selection,references)
        assert(C.digest(selection)==selection_hash,'readtime_transfer/selection_changed')
        local function snapshot()
            assert(current(),'readtime_transfer/stale')
            assert(not metadata or Accounting.day(now())==Accounting.day(metadata.created_at),'readtime_transfer/day_changed')
            local info=auth:_request('time_metadata',BASE..'/book/info?bookId='..selection.book_id,nil,selected.credentials)
            assert(P.id(info.bookId)==selection.book_id,'readtime_transfer/book')
            local version=info.bookVersion;if version==nil then version=info.version end
            assert(C.integer(version,1,2147483647) and version==window.version,'readtime_transfer/version')
            local raw=auth:_request('time_progress',BASE..'/book/getProgress?bookId='..selection.book_id,nil,selected.credentials)
            assert(C.integer(raw.timestamp,1,4102444800) and math.abs(raw.timestamp-now())<=60,'readtime_transfer/clock')
            local native=P.snapshot(raw,selection.book_id)
            local wp=web_point(client:get_progress_snapshot(selection.book_id,web.web,{classify_auth=true,fresh=true}),selection.book_id)
            local shelf=Shelf.state_hash(auth:read_shelf(selected.credentials));local months={}
            for month in pairs(window.months) do
                local value=Stats.project(auth:_request('time_statistics',BASE..'/readdata/detail?mode=monthly&baseTime='..month,nil,selected.credentials),'monthly',tonumber(month))
                months[month]={baseTime=value.baseTime,readTimes=value.readTimes,totalReadTime=value.totalReadTime,readDays=value.readDays}
            end
            assert(current(),'readtime_transfer/stale')
            return {native_hash=P.point_hash(native.position),web_hash=wp,counts=native.counts,shelf_hash=shelf,months=months}
        end
        local before=snapshot()
        local config=auth:_request('time_config',BASE..'/config?token=1',nil,selected.credentials)
        local guest=Signing.guest_token(auth:_request('time_feature',BASE..'/feature?synckey=0',nil,selected.credentials))
        assert(C.digest(snapshot())==C.digest(before),'readtime_transfer/concurrent_before')
        local stamp=now();assert(Signing.time_zone(stamp)=='+08:00','readtime_transfer/zone')
        local random=options.random or function() return tonumber(auth.digits(3)) end
        assert(C.digest(selection)==selection_hash,'readtime_transfer/selection_changed')
        body=Signing.batch(selected.credentials,selection.book_id,selection.protocol_rows,guest,config.token,stamp,random(),
            {timestamp=stamp*1000,random=random(),current_zone='+08:00'})
        metadata={protocol='native-historical-time-cst-v1',book_id=selection.book_id,file_id=selection.file_id,book_version=window.version,
            seconds=window.seconds,day=window.day,created_at=stamp,source=source,native_hash=before.native_hash,web_hash=before.web_hash,
            counts=before.counts,shelf_hash=before.shelf_hash,months=before.months,request_hash=C.digest(body)}
        Accounting.validate(metadata)
        assert(current() and now()>=stamp and now()-stamp<30 and Accounting.day(now())==Accounting.day(stamp),'readtime_transfer/stale')
        record=assert(journal:begin(account,selection,metadata),'readtime_transfer/storage')
        local ack=auth:_request('time_write',BASE..'/book/batchUploadProgress',body,selected.credentials,nil,function()
            assert(current() and C.digest(selection)==selection_hash and now()>=stamp and now()-stamp<30 and Accounting.day(now())==Accounting.day(stamp)
                and Signing.time_zone(now())=='+08:00' and C.digest(body)==metadata.request_hash,'readtime_transfer/stale')
            assert(journal:claim(record),'readtime_transfer/claim');out.attempted=true
        end)
        out.acknowledged=P.confirmed(ack)
        if not out.acknowledged then journal:outcome(record,false);out.kind='unconfirmed';return end
        assert(journal:acknowledge(record),'readtime_transfer/ack_save')
        local previous
        for attempt=1,4 do
            if attempt>1 then sleep(2) end
            local seen=snapshot();out.readbacks=attempt
            assert(seen.native_hash==metadata.native_hash and seen.web_hash==metadata.web_hash and seen.shelf_hash==metadata.shelf_hash,'readtime_transfer/position_changed')
            local checked=assert(Accounting.check(metadata,seen.counts,seen.months),'readtime_transfer/accounting')
            if checked.kind=='target' then
                local hash=C.digest(seen)
                out.stable_reads=previous==hash and out.stable_reads+1 or 1;previous=hash
                if out.stable_reads==2 then
                    assert(C.digest(observe(client,web,selection,references,source))==C.digest(source),'readtime_transfer/source_changed')
                    assert(C.digest(snapshot())==hash,'readtime_transfer/final_changed')
                    assert(current(),'readtime_transfer/stale')
                    local audit={readbacks=2,seconds=metadata.seconds,observations_hash=hash,removed_zero_buckets=checked.removed_zero_buckets,
                        read_days_delta=checked.read_days_delta,checked_at=now(),source_unchanged=true,positions_unchanged=true}
                    assert(journal:outcome(record,true,audit),'readtime_transfer/confirm_save')
                    out.removed_zero_buckets=checked.removed_zero_buckets
                    out.kind=journal:settle(record) and 'confirmed' or 'saved_confirmation';return
                end
            else
                assert(not previous,'readtime_transfer/regressed_readback')
                out.stable_reads=0
            end
        end
        out.kind='unconfirmed'
    end)
    auth:cancel()
    if not ok then
        if out.attempted then out.kind='unconfirmed'
        else
            out.kind=type(reason)=='string' and reason:find('/http_401',1,true) and 'login' or 'unavailable'
            if record and journal:owns(record,'prepared') then journal:cancel_prepared(record) end
        end
    end
    return out
end
return M
