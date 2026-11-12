-- Normal plugin uploads and periodic source preparation against mock HTTP only.
return function(reader,plugin,pump,clean_popups)
    assert(plugin.settings.mock_endpoint and plugin.settings.mock_endpoint:match('^http://127%.0%.0%.1:%d+$'))
    local Json,HTTP,LTN=require('json'),require('socket.http'),require('ltn12')
    local UI,ffi=require('ui/uimanager'),require('ffi')
    local SourceDom=require('weread.lib.source_dom')
    local Readback=require('weread.lib.progress_readback')
    local Protocol=require('weread.lib.protocol')
    local id=assert(plugin:detectWeReadBook())
    local point=assert(plugin.source_position:current())
    local saved=plugin.settings:get_book(id)
    local uploaded=assert(saved.last_uploaded_position)
    assert(uploaded.wire_basis=='filtered_xhtml_utf16' and uploaded.chapter_offset==point.chapter_offset
        and uploaded.chapter_uid==point.chapter_uid and not uploaded.summary)
    local index=assert(SourceDom.open(reader.document,id,point.chapter_uid))
    local target=assert(index:locate(point.chapter_offset))
    assert(reader.document:isXPointerInCurrentPage(target.xpointer) and assert(index:capture(target.xpointer)).co==point.chapter_offset)
    local ending=target.xpointer
    for _i=1,80 do
        local next_point=reader.document:getNextVisibleChar(ending)
        if not next_point or SourceDom.fragment(next_point)~=SourceDom.fragment(target.xpointer) then break end
        ending=next_point
    end
    local text=assert(SourceDom.normalize(reader.document:getTextFromXPointers(target.xpointer,ending)))
    reader.document:clearSelection()
    local chars={};for char in text:gmatch('[%z\1-\127\194-\244][\128-\191]*') do if #chars==20 then break end;chars[#chars+1]=char end
    local summary=table.concat(chars)
    local raw=plugin.client:get_web_progress(id)
    assert(Readback.check(raw,assert(Readback.expected(id,uploaded))).matches,'ordinary source upload readback differs')
    assert(raw.book.summary==summary,'actual source wire summary differs from native DOM')
    assert(not saved.last_local_position.summary and not saved.last_remote_position.summary
        and not saved.last_local_position.source_position.summary,'source summary entered a position checkpoint')
    local parent=tonumber(ffi.C.getpid())
    local original_methods={}
    for _i,name in ipairs({'getDocumentFileContent','getHTMLFromXPointers','getTextFromXPointers','getNextVisibleChar','getPrevVisibleChar'}) do
        original_methods[name]=reader.document[name]
        reader.document[name]=function(document,...)
            assert(tonumber(ffi.C.getpid())==parent,'source report child touched inherited native document')
            return original_methods[name](document,...)
        end
    end
    pcall(ffi.cdef,'void *mmap(void *, unsigned long, int, int, int, long);')
    local memory=ffi.C.mmap(nil,4096,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1))
    local counters=ffi.cast('int *',memory)
    local request=plugin.client.request
    function plugin.client:request(options)
        if options.url=='https://weread.qq.com/web/book/read' then
            local body=Json.decode(options.body)
            assert(tonumber(ffi.C.getpid())~=parent,'periodic source report did not use its production subprocess')
            assert(plugin.source_dispatch:pending(id),'source report dispatched before its durable journal')
            if counters[1]==1 then counters[2]=1;ffi.C.usleep(5000000) end
            assert(body.c==Protocol.e(point.chapter_uid) and body.ci==uploaded.chapter_idx and body.co==point.chapter_offset
                and body.pr==uploaded.percent and body.sm==summary,'periodic source body used projected words')
            assert(body.rt==30,'periodic source duration changed')
            counters[0]=counters[0]+1
        end
        return request(self,options)
    end
    local report=plugin.read_report
    local config=plugin.settings:get('read_report');config.enabled=true;config.mode='auto';config.interval_seconds=30
    plugin.settings:set('read_report',config)
    local count=report.count or 0
    local saw_prepare,saw_report=false,false
    report:maybe_start('source_upload_fixture')
    pump(function()
        local worker=plugin.source_position.preview_worker and plugin.source_position.preview_worker.job
        if worker then assert(worker.pid~=parent);saw_prepare=true end
        if report.job then assert(report.job.pid~=parent);saw_report=true end
        return (report.count or 0)>count
    end)
    assert(counters[0]==1 and saw_prepare and saw_report,'periodic source preparation or single dispatch was not observed')
    report:stop('source_fixture_first_complete')
    assert(not plugin.source_dispatch:pending(id),'exact periodic readback did not clear dispatch journal')
    counters[1]=1
    report:maybe_start('source_upload_interrupted_fixture')
    pump(function() return counters[2]==1 end)
    local interrupted=assert(report.job).pid
    report:stop('source_fixture_interrupted')
    pump(function() return require('ffi/util').isSubProcessDone(interrupted) end)
    assert(require('weread.lib.source_dispatch'):new{settings=plugin.settings}:pending(id),
        'fresh journal instance lost an interrupted subprocess')
    local position,why=plugin.progress_sync:position_for_report(id)
    assert(not position and why=='progress_confirmation_pending' and counters[0]==1,
        'interrupted dispatch was replayed or did not block reporting')
    counters[1]=0
    clean_popups(reader);assert(plugin:onWeReadSyncProgress())
    pump(function() return not plugin.progress_sync.pulling end)
    assert(plugin.progress_sync.verified and not plugin.source_dispatch:pending(id),'read-only comparison did not resolve interruption')
    local function control(mode)
        local chunks,body={},Json.encode{progress_confirmation=mode}
        local _,code=HTTP.request{url=plugin.settings.mock_endpoint..'/__control',proxy=plugin.settings.mock_endpoint,
            method='POST',headers={['Content-Type']='application/json',['Content-Length']=tostring(#body)},
            source=LTN.source.string(body),sink=LTN.sink.table(chunks)}
        assert(code==200)
    end
    control('noack')
    local failures=report.failure_count or 0
    report:maybe_start('source_upload_unconfirmed_fixture')
    pump(function() return (report.failure_count or 0)>failures end)
    assert(counters[0]==2 and not plugin.progress_sync.verified,'unknown periodic source write retained authority or retried')
    saved=plugin.settings:get_book(id)
    assert(saved.pending_upload_position and saved.pending_upload_reason=='upload_readback_unconfirmed',
        'unknown periodic source write lost local intent')
    assert(saved.source_dispatch and plugin.source_dispatch:pending(id),'unknown periodic write lost its dispatch journal')
    for _i=1,5 do UI:shiftScheduledTasksBy(-1e9);UI:setInputTimeout(0);UI:handleInput() end
    assert(counters[0]==2,'unknown periodic source write was automatically replayed')
    config.enabled=false;plugin.settings:set('read_report',config);report:stop('source_fixture_complete')
    plugin.client.request=request
    for name,method in pairs(original_methods) do reader.document[name]=method end
    control('plain')
    clean_popups(reader)
    assert(plugin:onWeReadSyncProgress())
    pump(function() return not plugin.progress_sync.pulling end)
    assert(plugin.progress_sync.verified and not plugin.settings:get_book(id).pending_upload_position,
        'exact explicit source comparison did not resolve an observed unknown write')
    local file=assert(io.open(assert(os.getenv('WEREAD_EVIDENCE'))..'/source-upload-result.json','wb'))
    file:write(Json.encode{result='PASS',synthetic_only=true,native_source_wire_and_summary=true,
        source_summary_not_in_checkpoints=true,background_preparation_observed=true,background_report_observed=true,
        no_inherited_native_document_calls=true,periodic_posts=2,periodic_duration_seconds=30,
        dispatch_persisted_before_fork_and_http=true,interrupted_child_retained_journal=true,interrupted_child_reaped=true,
        unknown_ack_paused_reporting=true,no_automatic_write_retry=true,explicit_readonly_recheck_resolved=true,
        real_account_data_writes_attempted=0});file:close()
end
