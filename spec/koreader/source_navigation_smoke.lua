-- Called from the live ReaderUI fixture; all books/accounts are synthetic.
return function(reader,plugin,pump,evidence,check_candidate)
    local Source=require('weread.lib.position_source')
    local Dom=require('weread.lib.source_dom')
    local Context=require('weread.lib.source_context')
    local Worker=require('weread.lib.source_position_worker')
    local UIManager=require('ui/uimanager')
    local Event=require('ui/event')
    local socket=require('socket')
    local util=require('ffi/util')
    local doc=reader.document
    reader:handleEvent(Event:new('SetViewMode','page'))
    reader.rolling:onGotoPage(1)
    pump(function() return plugin.source_position:current()~=nil end)
    local reference=assert(Dom.open(doc,'900001','22'))
    local point=assert(reference.map:locate('第22章第8段：阅读状态必须来自当前文档，后台任务不能覆盖新的页面。'))
    local expected=assert(reference:locate(point.co))
    local snapshot=assert(Source.document_metadata(doc,'900001','22'))
    local target={book_id='900001',chapter_uid='22',chapter_offset=point.co,basis=Source.coordinate_basis(snapshot.record.format),upload_verified=false}
    for _,key in ipairs({'file_id','book_version','raw_sha256','render_path'}) do target[key]=snapshot.record[key] end
    local native_read=doc.getDocumentFileContent
    doc.getDocumentFileContent=function(self,name)
        assert(not name:find('/raw-',1,true) and not name:match('^OEBPS/text/'),
            'production navigation read raw/rendered source on UI thread')
        return native_read(self,name)
    end
    local result,reason,finished
    local native_ticks,child_observed=0,false
    local heartbeat
    heartbeat=function()
        if finished then return end
        if plugin.source_navigation.state=='locating' then native_ticks=native_ticks+1 end
        UIManager:scheduleIn(0.1,heartbeat)
    end
    UIManager:scheduleIn(0.1,heartbeat)
    local before_page=doc:getCurrentPage()
    local was_verified=plugin.progress_sync.verified
    assert(plugin:openSourcePosition(target,function(position,why) result,reason,finished=position,why,true end),
        'production source-navigation entry rejected bound target')
    pump(function()
        local job=plugin.source_navigation.worker and plugin.source_navigation.worker.job
        if job then
            assert(job.pid~=tonumber(require('ffi').C.getpid()),'navigation preparation did not run in a child')
            child_observed=true
        end
        return finished
    end,35)
    UIManager:unschedule(heartbeat)
    doc.getDocumentFileContent=native_read
    assert(result,reason)
    assert(child_observed and native_ticks>0,'navigation did not keep the parent event loop responsive')
    assert(result.chapter_offset==point.co and result.chapter_uid=='22','wrong original target applied')
    assert(doc:isXPointerInCurrentPage(expected.xpointer),'target is not visible after native navigation')
    assert(plugin.progress_sync.verified==was_verified and not result.upload_verified,'local source jump granted upload rights')
    local held=assert(plugin.source_position:current())
    assert(held.retained_source_target and held.chapter_offset==point.co,'page origin replaced exact source target')
    if check_candidate then check_candidate(held) end
    local viewport=assert(Context.location(doc,reader.view.view_mode))
    local page_origin=assert(reference:capture(viewport.xpointer))
    assert(page_origin.co~=point.co,'fixture did not exercise a mid-page target')
    plugin:showReadingPosition()
    pump(function() return plugin._source_position_message~=nil end)
    assert(plugin._source_position_message.text:find('第二章',1,true),'position dialog lost verified target chapter')
    UIManager:forceRePaint()
    require('device').screen:shot(evidence..'/source-navigation-target.png')
    plugin:closeReadingPositionMessage()
    local target_page=doc:getCurrentPage()
    local font=reader.font.configurable.font_size
    local pages=doc:getPageCount()
    reader:handleEvent(Event:new('SetFontSize',font+4))
    pump(function()
        local position=plugin.source_position:current()
        return position and not (plugin.progress_sync.source_anchor and plugin.progress_sync.source_anchor.reflow_pending)
    end)
    assert(doc:getPageCount()~=pages,'native font change did not repaginate')
    assert(assert(plugin.source_position:current()).chapter_offset==point.co,'reflow lost exact source target')
    if check_candidate then check_candidate(assert(plugin.source_position:current())) end
    local pages_after=doc:getPageCount()
    reader:handleEvent(Event:new('SetViewMode','scroll'))
    pump(function()
        local position=plugin.source_position:current()
        return position and not (plugin.progress_sync.source_anchor and plugin.progress_sync.source_anchor.reflow_pending)
    end)
    assert(assert(plugin.source_position:current()).chapter_offset==point.co,'mode switch lost exact source target')
    if check_candidate then check_candidate(assert(plugin.source_position:current())) end
    -- A same-line jump changes the native logical marker even if page and
    -- scroll coordinates remain unchanged. Never revive the retained target.
    local adjacent=assert(doc:getNextVisibleChar(expected.xpointer))
    reader.rolling:onGotoXPointer(adjacent)
    assert(not plugin.source_position:current(),'same-page explicit jump exposed stale retained source result')
    pump(function() return plugin.source_position:current()~=nil end)
    assert(not plugin.source_position:current().retained_source_target,'same-page jump revived a held target')

    -- Cancel a confirmed live worker through a real native page/position event.
    local original=Worker.prepare_target
    Worker.prepare_target=function(input) socket.sleep(0.8);return original(input) end
    local cancelled_callback=false
    assert(plugin:openSourcePosition(target,function() cancelled_callback=true end))
    pump(function() return plugin.source_navigation.worker and plugin.source_navigation.worker.job~=nil end)
    local old_pid=plugin.source_navigation.worker.job.pid
    reader.rolling:onGotoPage(1)
    Worker.prepare_target=original
    pump(function() return util.isSubProcessDone(old_pid) and plugin.source_position:current()~=nil end)
    assert(not cancelled_callback and not plugin.source_navigation.job,'cancelled target committed or left a native job')
    assert(not plugin.source_position:current().retained_source_target,'cancelled target revived old source position')
    -- Cancel after real native backward walking has started, not merely while
    -- the child prepares bytes or the native index is being opened.
    local previous_char=doc.getPrevVisibleChar
    local walk_steps=0
    doc.getPrevVisibleChar=function(self,xp) walk_steps=walk_steps+1;return previous_char(self,xp) end
    local native_callback=false
    assert(plugin:openSourcePosition(target,function() native_callback=true end))
    pump(function() return plugin.source_navigation.state=='locating' and walk_steps>=128 end,35)
    reader.rolling:onGotoPage(2)
    doc.getPrevVisibleChar=previous_char
    pump(function() return plugin.source_position:current()~=nil end)
    assert(not native_callback and not plugin.source_navigation.job,'cancelled native walk navigated or committed')
    reader:handleEvent(Event:new('SetViewMode','page'))
    reader:handleEvent(Event:new('SetFontSize',font))
    reader.rolling:onGotoPage(1)
    pump(function() return plugin.source_position:current()~=nil end)
    local report={status='PARTIAL',public_network_used=false,production_account_writes_attempted=0,
        precision_wire_sync_enabled=false,background_preparation=true,parent_native_dom=true,ui_raw_member_reads=0,
        navigation_child_observed=child_observed,native_phase_event_loop_ticks=native_ticks,
        target_chapter='22',target_co=point.co,native_page_origin_co=page_origin.co,
        page_before=before_page,target_page=target_page,pages_before_reflow=pages,pages_after_reflow=pages_after,
        source_target_retained=true,font_reflow=true,scroll=true,same_page_jump_invalidates=true,
        cancelled_live_worker_reaped=true,upload_verification_unchanged=true}
    report.cancelled_native_walk=true
    report.native_walk_steps_before_cancel=walk_steps
    local file=assert(io.open(evidence..'/source-navigation.json','wb'))
    file:write(require('rapidjson').encode(report));file:close()
    UIManager:forceRePaint()
    print('PASS: production source target -> independent archive worker -> cooperative native DOM -> visible jump; exact target retained until navigation')
    return report
end
