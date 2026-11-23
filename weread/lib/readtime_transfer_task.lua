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
local Point=require('weread.lib.readtime_point')
local CBGuard=require('weread.lib.cb_readtime_guard')
local Source=require('weread.lib.readtime_source')
local Shelf=require('weread.lib.shelf_flag_change_contract')
local Auth=require('weread.lib.native_authorization')
local BASE='https://i.weread.qq.com'
local M={}
local function observer(settings,native,current,account,override)
    if override then return override end
    return function(client,web,selection,references,previous)
        local direct=selection.native_direct==true or type(previous)=='table' and previous.kind=='native_direct'
        if not direct then return Source.observe(client,web,selection,references,previous) end
        assert(C.array(references,1,1),'readtime_transfer/native_reference')
        local ref=references[1]
        assert(type(ref)=='table' and ref.kind=='native_direct' and type(ref.file)=='string'
            and C.id(ref.chapter_uid) and C.hash(ref.source_sha256),'readtime_transfer/native_reference')
        local proof=assert(require('weread.lib.native_direct_readtime_source').observe(
            client,settings,account,selection,ref.file,native,web,current,previous),'readtime_transfer/native_source')
        assert(C.digest(proof.ref)==C.digest(ref),'readtime_transfer/native_reference')
        return proof
    end
end
local function web_point(raw,book)
    local point,reason,provided=Remote.project(raw,book,'web');local node=Remote.node(raw,book)
    assert(not reason and point and node and provided.chapter_uid and provided.chapter_idx and provided.chapter_offset and provided.summary,'readtime_transfer/web_position')
    point.summary=node.summary;return P.point_hash(point)
end
local function snapshotter(client,auth,selected,web,book,expected_version,expected_months,current,now,day_guard,point_contract,reject_unstarted)
    local cb=C.cb_id(book)
    return function()
        assert(current(),'readtime_transfer/stale')
        assert(not day_guard or day_guard(),'readtime_transfer/day_changed')
        local info=auth:_request('time_metadata',BASE..'/book/info?bookId='..book,nil,selected.credentials)
        assert(cb and info.bookId==book or not cb and P.id(info.bookId)==book,'readtime_transfer/book')
        local version=info.bookVersion;if version==nil then version=info.version end
        if cb and expected_version==0 then
            assert(C.integer(version,0,0) and (info.bookVersion==nil or C.integer(info.bookVersion,0,0))
                and (info.version==nil or C.integer(info.version,0,0)),'readtime_transfer/version')
        else assert(C.integer(version,1,2147483647) and version==expected_version,'readtime_transfer/version') end
        local raw=auth:_request('time_progress',BASE..'/book/getProgress?bookId='..book,nil,selected.credentials)
        assert(C.integer(raw.timestamp,1,4102444800) and math.abs(raw.timestamp-now())<=60,'readtime_transfer/clock')
        local fetch=cb and client.get_shelf_display_progress or client.get_progress_snapshot
        local remote=fetch(client,book,web.web,{classify_auth=true,fresh=true})
        if reject_unstarted then
            local state=require('weread.lib.native_cloud_state')
            if state.from(raw,book) and state.from(remote,book)
                and state.initial_counts(P.counts(assert(Remote.node(raw,book)))) then
                error('readtime_transfer/position_required',0)
            end
        end
        local native_hash,wp,counts,summary,web_counts
        if point_contract==Point.CONTRACT then
            if cb then
                local observed=assert(CBGuard.observe(raw,remote,book),'readtime_transfer/cb_position')
                native_hash,wp,summary=observed.native_hash,observed.web_hash,observed.summary
                web_counts=P.counts(assert(Remote.node(remote,book)))
            else native_hash,wp=Point.hash(raw,book,'native'),Point.hash(remote,book,'web') end
            counts=P.counts(assert(Remote.node(raw,book)))
        else
            local native=P.snapshot(raw,book);native_hash=P.point_hash(native.position);counts=native.counts
            wp=web_point(remote,book)
        end
        local shelf=Shelf.state_hash(auth:read_shelf(selected.credentials));local months={}
        for month in pairs(expected_months) do
            local value=Stats.project(auth:_request('time_statistics',BASE..'/readdata/detail?mode=monthly&baseTime='..month,nil,selected.credentials),'monthly',tonumber(month))
            months[month]={baseTime=value.baseTime,readTimes=value.readTimes,totalReadTime=value.totalReadTime,readDays=value.readDays}
        end
        assert(current(),'readtime_transfer/stale')
        return {native_hash=native_hash,web_hash=wp,counts=counts,web_counts=web_counts,shelf_hash=shelf,months=months},summary
    end
end
local function verify(client,web,selection,references,journal,record,metadata,snapshot,current,now,sleep,observe,out)
    local source=metadata.source
    local previous
    for attempt=1,4 do
        if attempt>1 then sleep(2) end
        local seen=snapshot();out.readbacks=attempt
        assert(seen.native_hash==metadata.native_hash and seen.web_hash==metadata.web_hash and seen.shelf_hash==metadata.shelf_hash,'readtime_transfer/position_changed')
        local checked=assert(Accounting.check(metadata,seen.counts,seen.months),'readtime_transfer/accounting')
        local target=checked.kind=='target'
        if metadata.protocol=='native-historical-time-cst-cb-v1' then
            local web_checked=assert(Accounting.check(metadata,seen.web_counts,seen.months),'readtime_transfer/web_accounting')
            target=target and web_checked.kind=='target'
        end
        if target then
            local hash=C.digest(seen)
            out.stable_reads=previous==hash and out.stable_reads+1 or 1;previous=hash
            if out.stable_reads==2 then
                assert(C.digest(observe(client,web,selection,references,source))==C.digest(source),'readtime_transfer/source_changed')
                assert(C.digest(snapshot())==hash,'readtime_transfer/final_changed')
                assert(current(),'readtime_transfer/stale')
                local audit={readbacks=2,seconds=metadata.seconds,observations_hash=hash,removed_zero_buckets=checked.removed_zero_buckets,
                    read_days_delta=checked.read_days_delta,checked_at=now(),source_unchanged=true,positions_unchanged=true}
                if checked.added_zero_buckets~=nil then audit.added_zero_buckets=checked.added_zero_buckets end
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
    local observe=observer(settings,selected,current,options.account,options.observe_source)
    local ok,reason=pcall(function()
        assert(type(selection)=='table' and selection.rows_hash==C.digest(selection.rows) and selection.parts_hash==C.digest(selection.parts),'readtime_transfer/selection')
        local cb=C.cb_id(selection.book_id)
        assert(not cb or options.experimental_cb==true,'readtime_transfer/cb_disabled')
        local current_day=selection.current_day==true
        assert(selection.current_day==nil or current_day and selection.native_direct==true
            and options.allow_current_native==true,'readtime_transfer/current_disabled')
        local account=Account(selected.scope.vid);assert(C.account(account),'readtime_transfer/account')
        assert(options.account==account,'readtime_transfer/account')
        local pending,why=journal:pending(account);assert(not pending and not why,'readtime_transfer/pending')
        local rebuilt=assert(C.select(selection.rows,{parts=selection.parts},now(),selection.book_id,cb,
            selection.native_direct==true),'readtime_transfer/selection')
        assert(rebuilt.native_direct==selection.native_direct,'readtime_transfer/source')
        for _i,key in ipairs({'book_id','file_id','book_version','time_zone','seconds','rows_hash','parts_hash'}) do
            assert(rebuilt[key]==selection[key],'readtime_transfer/selection')
        end
        assert(C.digest(rebuilt.protocol_rows)==C.digest(selection.protocol_rows),'readtime_transfer/intervals')
        local selection_hash=C.digest(selection)
        local window=Accounting.window(selection.protocol_rows,selection.book_id,now(),current_day)
        assert(window.seconds==selection.seconds and window.version==selection.book_version and C.hash(selection.file_id),'readtime_transfer/source')
        local source=observe(client,web,selection,references)
        assert(window.version~=0 or cb and type(source)=='table' and source.format=='web_txt','readtime_transfer/source')
        assert(C.digest(selection)==selection_hash,'readtime_transfer/selection_changed')
        local snapshot=snapshotter(client,auth,selected,web,selection.book_id,window.version,window.months,current,now,function()
            return not metadata or Accounting.day(now())==Accounting.day(metadata.created_at)
        end,Point.CONTRACT,selection.native_direct==true)
        local before,summary=snapshot()
        assert(not cb or P.same_counts(before.counts,before.web_counts),'readtime_transfer/cb_counts')
        local config=auth:_request('time_config',BASE..'/config?token=1',nil,selected.credentials)
        local guest=Signing.guest_token(auth:_request('time_feature',BASE..'/feature?synckey=0',nil,selected.credentials))
        local again,latest_summary=snapshot()
        assert(C.digest(again)==C.digest(before) and (not cb or summary==latest_summary),'readtime_transfer/concurrent_before')
        if selection.native_direct then
            assert(C.digest(observe(client,web,selection,references,source))==C.digest(source),'readtime_transfer/source_changed')
            local final,final_summary=snapshot()
            assert(C.digest(final)==C.digest(before) and (not cb or summary==final_summary),'readtime_transfer/concurrent_before')
        end
        local stamp=now();assert(Signing.time_zone(stamp)=='+08:00','readtime_transfer/zone')
        local random=options.random or function() return tonumber(auth.digits(3)) end
        assert(C.digest(selection)==selection_hash,'readtime_transfer/selection_changed')
        local inner_random=random();local envelope={timestamp=stamp*1000,random=random(),current_zone='+08:00'}
        if cb then body=Signing.cb_batch(selected.credentials,selection.book_id,selection.protocol_rows,guest,config.token,stamp,inner_random,envelope,summary)
        else body=Signing.batch(selected.credentials,selection.book_id,selection.protocol_rows,guest,config.token,stamp,inner_random,envelope) end
        metadata={protocol=current_day and 'native-current-time-cst-v1' or cb and 'native-historical-time-cst-cb-v1' or 'native-historical-time-cst-v1',position_contract=Point.CONTRACT,book_id=selection.book_id,file_id=selection.file_id,book_version=window.version,
            seconds=window.seconds,day=window.day,created_at=stamp,device_hash=C.digest(selected.credentials.deviceId),source=source,native_hash=before.native_hash,web_hash=before.web_hash,
            counts=before.counts,shelf_hash=before.shelf_hash,months=before.months,request_hash=C.digest(body)}
        Accounting.validate(metadata)
        assert(current() and now()>=stamp and now()-stamp<30 and Accounting.day(now())==Accounting.day(stamp),'readtime_transfer/stale')
        record=assert(journal:begin(account,selection,metadata),'readtime_transfer/storage')
        out.attempt=record.attempt
        local ack=auth:_request('time_write',BASE..'/book/batchUploadProgress',body,selected.credentials,nil,function()
            assert(current() and C.digest(selection)==selection_hash and now()>=stamp and now()-stamp<30 and Accounting.day(now())==Accounting.day(stamp)
                and Signing.time_zone(now())=='+08:00' and C.digest(body)==metadata.request_hash,'readtime_transfer/stale')
            assert(journal:claim(record),'readtime_transfer/claim');out.attempted=true
        end)
        out.acknowledged=P.confirmed(ack)
        if not out.acknowledged then journal:outcome(record,false);out.kind='unconfirmed';return end
        assert(journal:acknowledge(record),'readtime_transfer/ack_save')
        verify(client,web,selection,references,journal,record,metadata,snapshot,current,now,sleep,observe,out)
    end)
    auth:cancel()
    if not ok then
        if out.attempted then out.kind='unconfirmed'
        else
            out.kind=reason=='readtime_transfer/position_required' and 'position_required'
                or type(reason)=='string' and reason:find('/http_401',1,true) and 'login'
                or type(reason)=='string' and reason:find('readtime_source/format',1,true) and 'unsupported_source'
                or 'unavailable'
            if record and journal:owns(record,'prepared') then journal:cancel_prepared(record) end
        end
    end
    return out
end
-- An ACK can be inspected again, but this path never requests signing tokens
-- and never calls batchUploadProgress. Original baseline and request stay sealed.
function M.resolve(client,settings,selected,web,record,references,journal,options)
    options=options or {};local now=options.now or os.time
    local sleep=options.sleep or function(s) require('socket').sleep(s) end
    local out={kind='unavailable',attempted=false,acknowledged=false,readbacks=0,stable_reads=0,removed_zero_buckets=0}
    local function current()
        if not selected or selected.renewal_pending or not P.credentials(selected.credentials) or not web or not web.web
            or type(options.is_current)~='function' or not Native.matches(settings,selected) or not Web.matches(settings,web) then return false end
        local ok,v=pcall(options.is_current)
        return ok and v==true and journal:owns(record,'acknowledged')==true
    end
    if not current() then return out end
    out.attempt=record.attempt
    local auth=Auth:new(client,{expected_vid=selected.scope.vid,is_current=current})
    local ok=pcall(function()
        local m=record.metadata
        assert(options.account==Account(selected.scope.vid) and record.account==options.account,'readtime_transfer/account')
        local identity=(m.protocol=='native-historical-time-cst-v1' or m.protocol=='native-current-time-cst-v1') and C.id(m.book_id)
            or m.protocol=='native-historical-time-cst-cb-v1' and C.cb_id(m.book_id)
        assert(m.protocol~='native-current-time-cst-v1' or type(m.source)=='table' and m.source.kind=='native_direct',
            'readtime_transfer/metadata')
        local zero= C.cb_id(m.book_id) and m.book_version==0 and type(m.source)=='table' and m.source.format=='web_txt'
        assert(identity and C.hash(m.file_id)
            and (zero or C.integer(m.book_version,1,2147483647)) and C.integer(m.created_at,1,now())
            and m.device_hash==C.digest(selected.credentials.deviceId),'readtime_transfer/metadata')
        assert(C.hash(m.native_hash) and C.hash(m.web_hash) and C.hash(m.shelf_hash),'readtime_transfer/metadata')
        Accounting.validate(m)
        assert(m.position_contract==nil or m.position_contract==Point.CONTRACT,'readtime_transfer/position_contract')
        assert(not C.cb_id(m.book_id) or m.position_contract==Point.CONTRACT,'readtime_transfer/position_contract')
        assert(type(record.evidence)=='table' and record.evidence.request_hash==record.request_hash,'readtime_transfer/ack')
        local selection={book_id=m.book_id,file_id=m.file_id,book_version=m.book_version}
        local observe=observer(settings,selected,current,options.account,options.observe_source)
        assert(C.digest(observe(client,web,selection,references,m.source))==C.digest(m.source),'readtime_transfer/source_changed')
        out.acknowledged=true
        local snapshot=snapshotter(client,auth,selected,web,m.book_id,m.book_version,m.months,current,now,nil,m.position_contract)
        verify(client,web,selection,references,journal,record,m,snapshot,current,now,sleep,observe,out)
    end)
    auth:cancel()
    if not ok then out.kind=out.acknowledged and 'unconfirmed' or 'unavailable' end
    return out
end
return M
