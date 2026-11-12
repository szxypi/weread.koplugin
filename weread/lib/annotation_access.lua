-- One captured read channel per matching job; never mix a paused native batch
-- with a fallback route or refresh native authorization in a child process.
local Access = require("weread.lib.native_gateway_access")
local Auth = require("weread.lib.native_authorization")
local Data = require("weread.lib.native_annotation_data")
local M = { capture = Access.capture, matches = Access.matches }
local function fail(reason) error("annotation_source/" .. reason, 0) end

function M.kind(selected, book_id)
    if selected and selected.channel == "gateway" then return selected.api_key and "gateway" or nil end
    if selected and selected.channel == "native" then return selected.native and (book_id == nil or Data.book_id(book_id)) and "native" or nil end
    return selected and (selected.native and (book_id == nil or Data.book_id(book_id)) and "native" or selected.api_key and "gateway") or nil
end

function M.pin(selected, channel, book_id)
    if type(selected) ~= "table" or (selected.channel and selected.channel ~= channel) then fail("source_changed") end
    if M.kind(selected, book_id) == channel and selected.channel == channel then return selected end
    local copy = {}
    for key, value in pairs(selected) do copy[key] = value end
    copy.channel = channel
    if (channel ~= "native" and channel ~= "gateway") or M.kind(copy, book_id) ~= channel then fail("source_changed") end
    return copy
end

function M.fetch(client, kind, book_id, chapter_uid, batch, selected)
    if kind ~= "underlines" and kind ~= "thoughts" then fail("invalid_kind") end
    selected = selected or M.capture(client.settings)
    if not selected then fail("access_required") end
    local function current() if not M.matches(client.settings, selected) then fail("session_changed") end end
    current()
    if M.kind(selected, book_id) == "native" then
        local auth = Auth:new(client, { expected_vid = selected.native.scope.vid,
            is_current = function() return M.matches(client.settings, selected) end })
        local ok, result = pcall(auth.read_annotations, auth, selected.native.credentials, kind, book_id, chapter_uid, batch)
        auth:cancel(); current()
        if not ok then
            local reason = tostring(result)
            local fallback = reason:match("/http_40[13]$") or reason:match("/http_50%d$")
                or reason:match("/timeout$") or reason:match("/transport$")
            if kind == "underlines" and not selected.channel and selected.api_key and fallback then
                return M.fetch(client, kind, book_id, chapter_uid, batch, M.pin(selected, "gateway", book_id))
            end
            if reason:match("/http_401$") then fail("native_expired") end
            if reason:match("/http_429$") then fail("rate_limited") end
            if reason:match("/timeout$") or reason:match("/transport$") or reason:match("/http_50%d$") then fail("unavailable") end
            fail("rejected")
        end
        result = Data.project(client, kind, result, book_id, chapter_uid, batch)
        result._source_kind = "native"
        return result
    end
    if M.kind(selected, book_id) ~= "gateway" then fail("access_required") end
    local payload = { bookId = tostring(book_id), chapterUid = chapter_uid }
    if kind == "thoughts" then payload.reviews = batch end
    local result = client:gateway(kind == "underlines" and "/book/underlines" or "/book/readreviews", payload)
    current()
    if type(result) ~= "table" then fail("invalid_rows") end
    result._source_kind = "gateway"
    return result
end

function M.terminal(reason)
    return type(reason) == "string" and reason:match("^annotation_source/") ~= nil and reason ~= "annotation_source/unavailable"
end

return M
