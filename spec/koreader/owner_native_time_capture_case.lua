-- Read-only real owner input; dwell is collected by the statistics plugin.
return function(input)
    local cfg=assert(input.native_time_capture);local C=require('weread.lib.readtime_transfer_contract')
    local socket=require('socket');local Crypto=require('weread.lib.crypto')
    assert(C.hash(cfg.baseline_sha256) and C.hash(cfg.device_sha256) and C.integer(cfg.book_version,1,2147483647))
    local case={report={phase='init',real_statistics=false,actual_clock=false,exact_source=false,ledger_reopened=false,
        same_day_deferred=false,seconds=0,rows=0,archive_bytes=0,failed_line=0}}
    function case:run(plugin,reader,pump)
        local stats=assert(reader.statistics);assert(stats:isEnabledAndNotFrozen())
        local identity=require('weread.lib.book_file_identity').read_document(reader.document,input.book_id)
        assert(identity.book_version==cfg.book_version and identity.version_source=='epub_snapshot')
        local index=require('weread.lib.source_upload_candidate').chapter_index
        local chapters=plugin.library_db:getChapters(input.book_id)
        local chapter_idx=assert(index(chapters,input.chapter_uid))
        local connected=plugin.isNetworkConnected;plugin.isNetworkConnected=function() return false end
        local collector=plugin.offline_time;local account=assert(plugin.library_db:accountKey())
        assert(assert(collector.store:summary(account)).pending==0)
        local coverage=plugin.readtime_coverage or require('weread.lib.readtime_coverage'):new(plugin.settings.data_dir)
        assert(coverage:initialize())
        local UI=require('ui/uimanager')
        for _i=1,12 do
            local top=UI:getTopmostVisibleWidget();if top==reader then break end
            assert(top and top.name~='filemanager','capture reader is not visible');UI:close(top)
        end
        reader:handleEvent(require('ui/event'):new('ReadingResumed'))
        assert(not stats._reading_paused_ts and require('ui/uimanager'):getTopmostVisibleWidget()==reader)
        plugin.settings:set('offline_time',{enabled=true});plugin.settings:flush()
        assert(collector:start() and collector.active and collector.active.clock.zone=='+08:00')
        local start=collector.active.last_seen;local Time=require('ui/time');local monotonic=Time.to_s(Time.monotonic())
        local page=reader:getCurrentPage();local xp=reader.document:getXPointer()
        -- No tuple, clock, file identity, source receipt or ledger timestamp edits.
        socket.sleep(6.05)
        reader:handleEvent(require('ui/event'):new('ReadingPaused'))
        local elapsed=Time.to_s(Time.monotonic())-monotonic
        assert(not collector.active and not collector.task)
        local rows=assert(collector.store:pending(account));assert(#rows>=1 and #rows<=12)
        local total,last=0,start
        for _i,row in ipairs(rows) do
            assert(row.start_time==last and row.book_id==input.book_id and row.file_id==identity.file_id
                and row.book_version==identity.book_version and row.version_source=='epub_snapshot' and row.time_zone=='+08:00')
            total=total+row.duration;last=row.start_time+row.duration
        end
        assert(total>=5 and total<=12 and total==last-start and math.abs(total-elapsed)<1.25)
        assert(reader:getCurrentPage()==page and reader.document:getXPointer()==xp)
        local restored=require('weread.lib.offline_time_store'):new(plugin.settings.data_dir)
        assert(C.digest(assert(restored:pending(account)))==C.digest(rows))
        local queued=assert(require('weread.lib.readtime_transfer_queue'):new{ledger=restored,coverage=coverage}:select(account,nil,{historical=true}))
        assert(queued.selection==false,'capture unexpectedly historical on its actual day')
        local file=assert(io.open(reader.document.file,'rb'));local archive=file:read(32769);file:close()
        assert(archive and #archive>0 and #archive<=32768)
        self.captured={protocol='native-statistics-epub-historical-window-v1',owner=input.vid,device_sha256=cfg.device_sha256,baseline_sha256=cfg.baseline_sha256,
            book_id=input.book_id,chapter_uid=input.chapter_uid,chapter_idx=chapter_idx,book_version=identity.book_version,
            file_id=identity.file_id,raw_sha256=input.source_raw_sha256,rows=rows,start_time=start,ended_at=last,
            seconds=total,monotonic_elapsed_ms=math.floor(elapsed*1000+.5),
            not_before=require('weread.lib.readtime_accounting').day(start)+86401,
            archive_base64=require('mime').b64(archive),archive_sha256=Crypto.sha256_hex(archive)}
        for key,value in pairs({phase='complete',real_statistics=true,actual_clock=true,exact_source=true,ledger_reopened=true,
            same_day_deferred=true,seconds=total,rows=#rows,archive_bytes=#archive,failed_line=0}) do self.report[key]=value end
        collector:stop('disabled');plugin.settings:set('offline_time',{enabled=false});plugin.settings:flush()
        plugin.isNetworkConnected=connected
        pump(function() return not plugin.offline_time.active end)
    end
    function case:audit() end
    function case:finish(reason)
        self.report.failed_line=tonumber(type(reason)=='string' and reason:match('owner_native_time_capture_case%.lua:(%d+):')) or 0
    end
    function case:private() return self.captured end
    return case
end
