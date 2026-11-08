-- Real fork + SQLite + HTTP: persist coverage even when the receipt is lost.
return function(reader, request_count)
    local plugin = reader.weread
    local position = assert(plugin.progress_sync:capture_local())
    local book = assert(plugin.settings:get("books")[position.book_id])
    local Coverage = require("weread.lib.readtime_coverage")
    local account = assert(plugin.library_db:accountKey())
    local before = request_count("/web/book/read")
    local native = require("ffi/util")
    local pid, fd = native.runInSubProcess(function(_pid, child_fd)
        local checked = false
        local original = plugin.client.report_read
        plugin.client.report_read = function(client, payload, referer)
            if payload.rt and payload.rt > 0 then
                local plan = assert(Coverage:new(plugin.settings.data_dir):preview(account, {
                    { id = 1, start_time = payload.ct - payload.rt, duration = payload.rt },
                }))
                assert(plan.covered == payload.rt, "HTTP began before coverage committed")
                checked = true
                original(client, payload, referer) -- The local server accepts it.
                error("synthetic lost receipt")
            end
            return original(client, payload, referer)
        end
        local ok, err = pcall(plugin.read_report._send, plugin.read_report,
            position.book_id, book, position, 30)
        native.writeToFD(child_fd, not ok and tostring(err):find("synthetic lost receipt", 1, true)
            and checked and "PASS" or "FAIL", true)
    end, true)
    assert(pid, "coverage worker did not fork")
    local socket = require("socket")
    local deadline = socket.gettime() + 10
    while not native.isSubProcessDone(pid) do
        if socket.gettime() >= deadline then
            native.terminateSubProcess(pid)
            error("coverage worker timed out")
        end
        socket.sleep(0.05)
    end
    assert(native.readAllFromFD(fd) == "PASS", "coverage was not durable before HTTP")
    assert(request_count("/web/book/read") > before, "real local HTTP was not exercised")
    local rows = assert(plugin.offline_time.store:pending(account))
    local seconds = 0
    for _, row in ipairs(rows) do seconds = seconds + row.duration end
    local plan = assert(Coverage:new(plugin.settings.data_dir):preview(account, rows))
    assert(seconds >= 12 and plan.covered == seconds and plan.eligible == 0,
        "reopened journal failed to exclude offline overlap after lost receipt")
    assert(plugin.offline_time:status().pending == seconds, "preview mutated offline records")
    print("PASS: real worker commits coverage before HTTP; lost receipt survives exit; offline overlap excluded; seconds=" .. seconds)
end
