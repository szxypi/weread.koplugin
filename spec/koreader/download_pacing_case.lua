-- Cancel a real paced source worker through the visible native dialog.
return function(host, reader, id, report, pump, tick, press, evidence)
    local ffi = require('ffi')
    local socket = require('socket')
    local UI = require('ui/uimanager')
    local Pacing = require('weread.lib.download_read_client')
    local Crypto = require('weread.lib.crypto')
    local json = require('json')
    pcall(ffi.cdef, 'void *mmap(void *, unsigned long, int, int, int, long); int munmap(void *, unsigned long);')
    local memory = ffi.C.mmap(nil, 4096, 3, 0x21, -1, 0)
    assert(memory ~= ffi.cast('void *', -1))
    local marker = ffi.cast('int *', memory)
    local full = reader.document.file
    local function digest()
        local file = assert(io.open(full, 'rb'));local raw = file:read('*a');file:close()
        return Crypto.sha256_hex(raw)
    end
    local expected_digest = digest()
    local before = assert(host.settings:get_book(id))
    local saved = json.decode(json.encode({ before.last_local_position, before.pending_upload_position }))
    local function same(left, right)
        if type(left) ~= type(right) then return false end
        if type(left) ~= 'table' then return left == right end
        for key, value in pairs(left) do if not same(value, right[key]) then return false end end
        for key in pairs(right) do if left[key] == nil then return false end end
        return true
    end
    local wrap = Pacing.wrap
    Pacing.wrap = function(client)
        local job = host.downloader._active_job
        local source_task = job and job.workspace ~= nil
        return wrap(client, function(seconds)
            assert(seconds == 1)
            if source_task then marker[0] = ffi.C.getpid() end
            socket.sleep(seconds)
        end)
    end
    host:showBookMenu(before)
    pump(function() return host._book_detail_view and not host.book_metadata_context end)
    press(host._book_detail_view, '⇩ Download full book')
    local heartbeats, cancelled, cancelled_at = 0, false, 0
    local monitor
    monitor = function()
        if marker[0] > 0 then
            heartbeats = heartbeats + 1
            if heartbeats >= 2 then
                local job = assert(host.downloader._active_job)
                local dialog = assert(job.progress_dialog)
                assert(UI:getTopmostVisibleWidget() == dialog and dialog.dismiss_callback)
                UI:forceRePaint()
                require('device').screen:shot(evidence .. '/download-pacing-cancel.png')
                cancelled_at = socket.gettime()
                dialog.buttons[1][1].callback()
                cancelled = true
                return
            end
        end
        UI:scheduleIn(0.1, monitor)
    end
    UI:scheduleIn(0.1, monitor)
    pump(function() return cancelled and not host.downloader._active_job end)
    Pacing.wrap = wrap
    local pid = tonumber(marker[0])
    assert(pid > 0 and pid ~= tonumber(ffi.C.getpid()))
    pump(function() return require('ffi/util').isSubProcessDone(pid) end)
    assert(socket.gettime() - cancelled_at < 2 and not host.downloader._standby_token)
    assert(require('apps/reader/readerui').instance == reader and reader.document.file == full and digest() == expected_digest)
    local after = assert(host.settings:get_book(id))
    assert(same(saved, json.decode(json.encode({ after.last_local_position, after.pending_upload_position }))))
    assert(after.cached_full_book == full)
    while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget() ~= reader do UI:close(UI:getTopmostVisibleWidget()) end
    host:closeWeReadUI();tick()
    assert(ffi.C.munmap(memory, 4096) == 0)
    report.paced_worker_cancelled = true
    report.paced_worker_reaped = true
    report.paced_ui_heartbeats = heartbeats
    report.paced_old_full_and_positions_preserved = true
end
