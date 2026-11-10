-- Exact wire-coordinate confirmation; never assigns source upload authority.
local Remote = require("weread.lib.remote_progress")
local M = {}
local function id(value)
    if type(value) == "number" then
        if value ~= value or value < 0 or value > 9007199254740991 or value % 1 ~= 0 then return end
        value = string.format("%.0f", value)
    end
    if type(value) == "string" and #value <= 128 and value:match("^[A-Za-z0-9][A-Za-z0-9_-]*$") then return value end
end
local function number(value, maximum, integer)
    if type(value) ~= "number" or value ~= value or value < 0 or value > maximum or integer and value % 1 ~= 0 then return end
    return value
end
function M.expected(book_id, position)
    book_id = id(book_id)
    if not book_id or type(position) ~= "table" or position.basis ~= nil or position.upload_verified == false
        or position.book_id ~= nil and id(position.book_id) ~= book_id then return nil, "upload_position_invalid" end
    local uid = id(position.chapter_uid)
    local index = number(position.chapter_idx, 1000000, true)
    local offset = number(position.chapter_offset, 2147483647, true)
    local percent = number(position.percent, 100)
    if not uid or not index or not offset or not percent then return nil, "upload_position_invalid" end
    return { book_id = book_id, chapter_uid = uid, chapter_idx = index, chapter_offset = offset, percent = math.floor(percent) }
end
function M.check(data, target)
    if type(target) ~= "table" then return { matches = false, reason = "upload_readback_invalid" } end
    local remote, reason, supplied = Remote.project(data, target.book_id, "web")
    if reason or not remote then return { matches = false, reason = "upload_readback_invalid" } end
    if not supplied.chapter_uid or not supplied.chapter_idx or not supplied.chapter_offset then
        return { matches = false, reason = "upload_readback_incomplete" }
    end
    local matches = id(remote.chapter_uid) == target.chapter_uid and remote.chapter_idx == target.chapter_idx
        and remote.chapter_offset == target.chapter_offset
    return { matches = matches, reason = matches and "confirmed_coordinate" or "upload_readback_differs" }, remote
end
function M.same_wire_position(left, right)
    if type(left) ~= "table" or type(right) ~= "table" then return false end
    local a = M.expected(left.book_id, left)
    local b = M.expected(right.book_id, right)
    if not a or not b then return false end
    for key, value in pairs(a) do if b[key] ~= value then return false end end
    return true
end
function M.same_intent(left, right)
    if not M.same_wire_position(left, right) then return false end
    local a, b = left.source_position, right.source_position
    if type(a) ~= type(b) then return false end
    if type(a) == "table" then
        for _i, key in ipairs({ "book_id", "chapter_uid", "chapter_offset", "basis", "file_id", "book_version", "raw_sha256", "render_path" }) do
            if a[key] ~= b[key] then return false end
        end
    end
    return true
end
function M.matches_normalized(position, remote)
    local target = type(position) == "table" and M.expected(position.book_id, position)
    return target and type(remote) == "table" and remote.book_id == target.book_id
        and remote.has_chapter_offset == true and remote.has_chapter_index == true
        and id(remote.chapter_uid) == target.chapter_uid and remote.chapter_idx == target.chapter_idx
        and remote.chapter_offset == target.chapter_offset or false
end
return M
