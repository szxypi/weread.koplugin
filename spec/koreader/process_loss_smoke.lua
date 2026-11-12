-- External Linux supervisor kills the actual reader and all its worker groups.
-- All data and HTTP here are synthetic; the pending journal is never fabricated.
local M = {}
local Json, Socket = require('json'), require('socket')
local UI = require('ui/uimanager')
local evidence = assert(os.getenv('WEREAD_EVIDENCE'))
local case = assert(os.getenv('WEREAD_TEST_PROCESS_LOSS'))
local kind = assert(os.getenv('WEREAD_TEST_PROCESS_LOSS_KIND'))
local function write(name, value)
    local path = evidence .. '/' .. name .. '.json'
    local file = assert(io.open(path .. '.tmp', 'wb'))
    assert(file:write(Json.encode(value))); assert(file:close())
    assert(os.rename(path .. '.tmp', path))
end
local function read(name)
    local file = assert(io.open(evidence .. '/' .. name .. '.json', 'rb'))
    local value = Json.decode(file:read('*a')); file:close(); return value
end
local function pump(predicate)
    local deadline = Socket.gettime() + 40
    while not predicate() do
        assert(Socket.gettime() < deadline, 'process-loss fixture deadline')
        UI:setInputTimeout(0); UI:handleInput(); Socket.sleep(.01)
    end
end
local function local_request(plugin, path, data)
    local body, chunks = Json.encode(data), {}
    local _, code = require('socket.http').request{url=plugin.settings.mock_endpoint .. '/__proxy?url=http%3A%2F%2F127.0.0.1' .. path,
        proxy=plugin.settings.mock_endpoint, method='POST', source=require('ltn12').source.string(body),
        headers={['Content-Type']='application/json',['Content-Length']=tostring(#body)}, sink=require('ltn12').sink.table(chunks)}
    assert(code == 200); return Json.decode(table.concat(chunks))
end
function M.prepare(reader, plugin)
    assert(plugin.settings.mock_endpoint:match('^http://127%.0%.0%.1:%d+$'))
    local sync, report = plugin.progress_sync, plugin.read_report
    assert(sync.verified and not plugin.source_dispatch:pending(assert(plugin:detectWeReadBook())))
    local config = plugin.settings:get('sync')
    config.pull_on_open, config.upload_on_close, config.upload_interval_minutes = true, kind == 'close', 1
    plugin.settings:set('sync', config)
    reader.rolling:onGotoPage(reader:getCurrentPage() == 1 and 2 or 1)
    pump(function() return plugin.source_position:current() ~= nil end)
    local position = assert(sync:capture_local())
    local point = assert(plugin.source_position:current())
    plugin:onFlushSettings(); reader:saveSettings()
    local id = assert(plugin:detectWeReadBook())
    assert(sync.dirty and plugin.settings:get_book(id).pending_upload_position)
    local config_report = plugin.settings:get('read_report')
    config_report.enabled, config_report.mode, config_report.interval_seconds = true, 'auto', 30
    plugin.settings:set('read_report', config_report); plugin.settings:flush()
    write('process-loss-checkpoint', {book_id=id,path=reader.document.file,xpointer=reader.document:getXPointer(),
        page=reader:getCurrentPage(),position=position,source=point})
    local_request(plugin, '/__process_loss_arm', {case=case,kind=kind})
    if case=='before-state-commit' then
        local patch=plugin.settings.patch_reading_state
        local rename=os.rename
        local journal
        function plugin.settings:patch_reading_state(book_id,changes)
            journal=type(changes.source_dispatch)=='table' and changes.source_dispatch or nil
            local result,err=patch(self,book_id,changes)
            journal=nil
            return result,err
        end
        rawset(os,'rename',function(from,to)
            if journal and from==to..'.tmp' and to==plugin.settings:get_book(id).cache_dir..'/reading_state.json' then
                -- The actual production file has been fully written/closed;
                -- hold before publishing it, without inventing a receipt.
                write('process-loss-ready',{case=case,kind=kind,dispatch_id=journal.id,parent_pid=tonumber(require('ffi').C.getpid())})
                while true do Socket.sleep(.05) end
            end
            return rename(from,to)
        end)
    end
    local begin = plugin.source_dispatch.begin
    function plugin.source_dispatch:begin(...)
        local receipt = assert(begin(self, ...), 'production dispatch journal was not saved')
        write('process-loss-ready', {case=case,kind=kind,dispatch_id=receipt.id,parent_pid=tonumber(require('ffi').C.getpid())})
        if case == 'before-dispatch' then
            -- Hold only after the real, durable begin completed, before forking
            -- the reporter. Do not call plugin shutdown or cancellation hooks.
            while true do Socket.sleep(.05) end
        end
        return receipt
    end
    if kind == 'periodic' then
        assert(report:maybe_start('process_loss_fixture') and report.task)
        report.task()
    elseif kind == 'manual' then
        assert(plugin:onWeReadSyncProgress())
        pump(function() return sync.state == 'awaiting_choice' end)
        local choice = assert(UI:getTopmostVisibleWidget())
        assert(choice.cancel_text == require('weread.lib.plugin_util').tr('Keep KOReader progress'))
        choice.cancel_callback(); UI:close(choice)
    else
        assert(kind == 'close'); reader:onClose(false)
    end
    local child_written
    pump(function()
        if report.job and not child_written then
            write('process-loss-child', {pid=report.job.pid}); child_written = true
        end
        return false -- The external supervisor must terminate this process.
    end)
end
function M.reopen(plugin, Reader, clean_popups)
    local expected = read('process-loss-checkpoint')
    local ready = read('process-loss-ready')
    local final = os.getenv('WEREAD_PROCESS_LOSS_REOPEN') == 'final'
    local committed = case ~= 'before-state-commit'
    local resolved = case ~= 'before-dispatch' and committed
    local online = false
    plugin.isNetworkOnline, plugin.isNetworkConnected = function() return online end, function() return online end
    local initial = plugin.settings:get_book(expected.book_id)
    -- Keep this observation read-only, including the final close of a fresh
    -- reader; an enabled close policy must not add a new test write.
    local config_sync = plugin.settings:get('sync')
    config_sync.upload_on_close = false; plugin.settings:set('sync', config_sync)
    local must_pending = committed and (not final or not resolved)
    assert((initial.source_dispatch ~= nil and initial.source_dispatch ~= false) == must_pending,
        'fresh process lost or recreated the dispatch journal')
    if must_pending then assert(initial.source_dispatch.id == ready.dispatch_id) end
    plugin:showHome()
    local view, selected = assert(plugin.shelf_view)
    for _i, book in ipairs(view.books) do
        if tostring(book.bookId or book.book_id) == expected.book_id then selected = book end
    end
    assert(selected and selected._cached)
    view.on_select(selected)
    pump(function() return Reader.instance and Reader.instance.weread and Reader.instance.document.file == expected.path end)
    local reader = Reader.instance
    local current, Mapper = reader.weread, require('weread.lib.position_mapper')
    current.isNetworkOnline, current.isNetworkConnected = function() return online end, function() return online end
    pump(function() return current.progress_sync.current_book_id == expected.book_id and current.source_position:current() ~= nil end)
    assert(reader.document:isXPointerInCurrentPage(expected.xpointer), 'whole-process loss lost the saved native page')
    local point = assert(current.source_position:current())
    assert(point.chapter_uid == expected.source.chapter_uid and point.chapter_offset == expected.source.chapter_offset
        and point.raw_sha256 == expected.source.raw_sha256, 'reopen changed the frozen original source point')
    local saved = current.settings:get_book(expected.book_id)
    if must_pending or not committed then
        assert(Mapper.same_position(saved.pending_upload_position, expected.position), 'reopen erased interrupted local intent')
        if committed then
            assert(current.source_dispatch:pending(expected.book_id) and saved.source_dispatch.id == ready.dispatch_id)
        else assert(not current.source_dispatch:pending(expected.book_id), 'temporary journal was loaded as committed state') end
        local position, why = current.progress_sync:position_for_report(expected.book_id)
        assert(not position and (not committed or why == 'progress_confirmation_pending'), 'reopen granted reporting before read-only comparison')
    else
        assert(not saved.pending_upload_position and not current.source_dispatch:pending(expected.book_id))
    end
    if not final then
        online = true
        -- Exercise scheduled reports before giving reconnection permission to
        -- compare remotely, including when the journal was not yet committed.
        assert(current.read_report:maybe_start('process_loss_reopen'))
        for _i=1,4 do assert(current.read_report.task); current.read_report.task() end
        assert(not current.read_report.job and current.source_dispatch:pending(expected.book_id)==committed)
        current:onNetworkConnected()
        pump(function() return not current.progress_sync.pulling
            and (current.progress_sync.verified or current.progress_sync.state == 'awaiting_choice') end)
        saved = current.settings:get_book(expected.book_id)
        if resolved then
            assert(current.progress_sync.verified and not saved.pending_upload_position
                and not current.source_dispatch:pending(expected.book_id), 'exact cloud comparison did not resolve accepted report')
        else
            assert(current.progress_sync.state == 'awaiting_choice' and not current.progress_sync.verified
                and (not committed or saved.source_dispatch.id == ready.dispatch_id)
                and Mapper.same_position(saved.pending_upload_position, expected.position), 'unsent intent was silently discarded')
            local choice = assert(UI:getTopmostVisibleWidget())
            assert(choice.cancel_text == require('weread.lib.plugin_util').tr('Keep KOReader progress'))
            for _i=1,4 do assert(current.read_report.task); current.read_report.task() end
            assert(not current.read_report.job, 'unresolved choice started another report')
        end
        write('process-loss-reopen', {native_page_restored=true,source_point_restored=true,
            pending_preserved_before_comparison=true,scheduled_reports_blocked_by_journal=committed,
            scheduled_reports_blocked_before_comparison=true,
            fresh_readonly_comparison=true,accepted_report_resolved=resolved,
            unsent_report_requires_choice=not resolved,original_dispatch_id_preserved=committed and not resolved,
            uncommitted_state_ignored=not committed})
    end
    -- Prevent a new, legitimate reporting interval after the case has finished.
    local config_report = current.settings:get('read_report')
    config_report.enabled = false; current.settings:set('read_report', config_report)
    current.read_report:stop('process_loss_fixture_complete')
    current.settings:flush(); clean_popups(reader); reader:onClose(false)
    print('PASS: fresh process-loss ' .. (final and 'offline persistence' or 'read-only reconciliation') .. ': ' .. case)
end
return M
