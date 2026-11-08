-- Original Web chapter bytes, captured before image/footnote transformations.
-- Content-addressed download receipts bind raw data to checkpointed chapters;
-- EPUB metadata binds those bytes to the actual rendered member and file ID.
-- This is local provenance, not a server signature or permission to upload.
local Crypto = require("weread.lib.crypto")
local FileIdentity = require("weread.lib.book_file_identity")
local M = { PREFIX = "OEBPS/weread-position", MAX_BYTES = 2 * 1024 * 1024,
    MAX_META_BYTES = 4096, MAX_RENDERED_BYTES = 8 * 1024 * 1024 }
local RECEIPT_KEYS = { "schema", "book_id", "chapter_uid", "format", "raw_bytes", "raw_sha256" }
local META_KEYS = { "schema", "book_id", "chapter_uid", "format", "raw_bytes", "raw_sha256", "capture_id",
    "book_version", "file_id", "render_path", "render_sha256" }

local function hash(value)
    return type(value) == "string" and #value == 64 and value:match("^[0-9a-f]+$") ~= nil
end
local function id(value)
    return type(value) == "string" and #value > 0 and #value <= 256 and not value:find("[%z%c]")
end
local function quote(value)
    return (tostring(value):gsub("[^%w._~-]", function(c) return string.format("%%%02X", c:byte()) end))
end
local function unquote(value)
    if type(value) ~= "string" or value:gsub("%%[0-9A-F][0-9A-F]", ""):find("%", 1, true) then return nil end
    return (value:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end
local function payload(fields, keys)
    local lines = {}
    for _, key in ipairs(keys) do lines[#lines + 1] = key .. "=" .. tostring(fields[key]) end
    return table.concat(lines, "\n") .. "\n"
end
local function parse(raw, keys, seal)
    if type(raw) ~= "string" or #raw > M.MAX_META_BYTES then return nil end
    local values, count = {}, 0
    for key, value in raw:gmatch("([a-z_][a-z0-9_]*)=([^\n]*)\n") do
        if values[key] ~= nil then return nil end
        values[key], count = value, count + 1
    end
    if count ~= #keys + 1 or not hash(values[seal]) then return nil end
    for _, key in ipairs(keys) do if values[key] == nil then return nil end end
    local body = payload(values, keys)
    if raw ~= body .. seal .. "=" .. values[seal] .. "\n" or Crypto.sha256_hex(body) ~= values[seal] then return nil end
    return values
end
local function receipt_values(source)
    return { schema = "1", book_id = quote(source.book_id), chapter_uid = quote(source.chapter_uid),
        format = source.format, raw_bytes = tostring(source.raw_bytes), raw_sha256 = source.raw_sha256 }
end
local function decode_receipt(raw)
    local fields = parse(raw, RECEIPT_KEYS, "capture_id")
    if not fields or fields.schema ~= "1" then return nil end
    local book, uid, bytes = unquote(fields.book_id), unquote(fields.chapter_uid), tonumber(fields.raw_bytes)
    if not id(book) or not id(uid) or not bytes or bytes % 1 ~= 0 or bytes < 1 or bytes > M.MAX_BYTES
        or not hash(fields.raw_sha256) or (fields.format ~= "web_xhtml" and fields.format ~= "web_txt") then return nil end
    return { book_id = book, chapter_uid = uid, format = fields.format, raw_bytes = bytes,
        raw_sha256 = fields.raw_sha256, capture_id = fields.capture_id }
end
local function encode_receipt(source)
    local body = payload(receipt_values(source), RECEIPT_KEYS)
    return body .. "capture_id=" .. Crypto.sha256_hex(body) .. "\n"
end

function M.capture(book, chapter, raw, format)
    local book_id = tostring(type(book) == "table" and (book.book_id or book.bookId) or "")
    local uid = tostring(type(chapter) == "table" and (chapter.chapterUid or chapter.chapterId) or "")
    if not id(book_id) or not id(uid) or type(raw) ~= "string" or #raw == 0 or #raw > M.MAX_BYTES
        or (format ~= "web_xhtml" and format ~= "web_txt") then return nil, "position_source/unsupported" end
    local source = { book_id = book_id, chapter_uid = uid, raw = raw, format = format,
        raw_bytes = #raw, raw_sha256 = Crypto.sha256_hex(raw) }
    source.capture_id = Crypto.sha256_hex(payload(receipt_values(source), RECEIPT_KEYS))
    return source
end

local function verify_source(source, book_id, uid)
    if type(source) ~= "table" or not id(source.book_id) or not id(source.chapter_uid)
        or type(source.raw) ~= "string" or #source.raw < 1 or #source.raw > M.MAX_BYTES
        or type(source.raw_bytes) ~= "number" or not hash(source.raw_sha256) or not hash(source.capture_id)
        or (source.format ~= "web_xhtml" and source.format ~= "web_txt") then return nil end
    local parsed = decode_receipt(encode_receipt(source))
    if not parsed or parsed.book_id ~= tostring(book_id) or parsed.chapter_uid ~= tostring(uid)
        or source.capture_id ~= parsed.capture_id or #source.raw ~= parsed.raw_bytes
        or Crypto.sha256_hex(source.raw) ~= parsed.raw_sha256 then return nil end
    return parsed
end

local function directory(workspace)
    return type(workspace) == "table" and type(workspace.path) == "string" and workspace.path .. "/position-source" or nil
end
local function read_file(path, maximum)
    local file = path and io.open(path, "rb")
    if not file then return nil end
    local raw = file:read(maximum + 1)
    local closed = file:close()
    if not closed or not raw or #raw > maximum then return nil end
    return raw
end
local function write_file(path, raw)
    local file = io.open(path .. ".part", "wb")
    if not file then return false end
    local wrote, closed
    wrote = file:write(raw)
    closed = file:close()
    if not wrote or not closed then os.remove(path .. ".part") return false end
    if not os.rename(path .. ".part", path) then os.remove(path .. ".part") return false end
    return true
end

function M.store(workspace, source, expected_book, expected_uid)
    local root = directory(workspace)
    local fields = type(source) == "table" and source or {}
    local parsed = root and verify_source(source, expected_book or fields.book_id,
        expected_uid or fields.chapter_uid)
    if not parsed then return nil, "position_source/invalid" end
    local ok, lfs = pcall(require, "lfs")
    if not ok then ok, lfs = pcall(require, "libs/libkoreader-lfs") end
    if not ok then return nil, "position_source/save_failed" end
    if lfs.attributes(root, "mode") ~= "directory" then
        if type(lfs.mkdir) ~= "function" then return nil, "position_source/save_failed" end
        lfs.mkdir(root)
        if lfs.attributes(root, "mode") ~= "directory" then return nil, "position_source/save_failed" end
    end
    -- Paths contain content hashes. A cancelled/older worker cannot replace a
    -- different generation's raw bytes or receipt under the same name.
    if not write_file(root .. "/raw-" .. parsed.raw_sha256 .. ".txt", source.raw)
        or not write_file(root .. "/receipt-" .. parsed.capture_id .. ".txt", encode_receipt(source)) then
        return nil, "position_source/save_failed"
    end
    return parsed.capture_id
end

function M.resolve(reference, book_id, uid)
    if type(reference) ~= "table" then return nil, "position_source/unavailable" end
    if reference.raw then
        local parsed = verify_source(reference, book_id, uid)
        if not parsed then return nil, "position_source/invalid" end
        parsed.data = reference.raw
        return parsed
    end
    local root = directory(reference.workspace)
    if not root or not hash(reference.receipt) then return nil, "position_source/invalid" end
    local parsed = decode_receipt(read_file(root .. "/receipt-" .. reference.receipt .. ".txt", M.MAX_META_BYTES))
    if not parsed or parsed.capture_id ~= reference.receipt or parsed.book_id ~= tostring(book_id)
        or parsed.chapter_uid ~= tostring(uid) then return nil, "position_source/invalid" end
    local path = root .. "/raw-" .. parsed.raw_sha256 .. ".txt"
    local raw = read_file(path, M.MAX_BYTES)
    if not raw or #raw ~= parsed.raw_bytes or Crypto.sha256_hex(raw) ~= parsed.raw_sha256 then
        return nil, "position_source/invalid"
    end
    parsed.path = path
    return parsed
end

local function render_path(path)
    if path == "OEBPS/text/chapter.xhtml" then return true end
    local index = type(path) == "string" and path:match("^OEBPS/text/chapter%-(%d+)%.xhtml$")
    return index and #index >= 3 and #index <= 6 and tonumber(index) >= 1 and tonumber(index) <= 100000 or false
end
function M.meta_path(uid) return M.PREFIX .. "/uid-" .. Crypto.sha256_hex(tostring(uid)) .. ".meta" end
function M.path_meta_path(path) return M.PREFIX .. "/path-" .. Crypto.sha256_hex(tostring(path)) .. ".meta" end
function M.raw_path(digest) return hash(digest) and M.PREFIX .. "/raw-" .. digest .. ".txt" or nil end

function M.bind(source, identity, path, rendered_sha256)
    if type(source) ~= "table" or type(identity) ~= "table" or identity.book_id ~= source.book_id
        or not hash(identity.file_id) or not render_path(path) or not hash(rendered_sha256)
        or type(identity.book_version) ~= "number" or identity.book_version < 0 or identity.book_version % 1 ~= 0
        or identity.book_version > 2147483647 then return nil end
    local receipt = decode_receipt(encode_receipt(source))
    if not receipt or receipt.capture_id ~= source.capture_id then return nil end
    local fields = receipt_values(source)
    fields.capture_id, fields.book_version, fields.file_id = source.capture_id, identity.book_version, identity.file_id
    fields.render_path, fields.render_sha256 = quote(path), rendered_sha256
    local body = payload(fields, META_KEYS)
    return body .. "metadata_sha256=" .. Crypto.sha256_hex(body) .. "\n"
end

function M.decode_metadata(raw)
    local fields = parse(raw, META_KEYS, "metadata_sha256")
    if not fields then return nil end
    local receipt = decode_receipt(payload(fields, RECEIPT_KEYS) .. "capture_id=" .. fields.capture_id .. "\n")
    local version, path = tonumber(fields.book_version), unquote(fields.render_path)
    if not receipt or not hash(fields.file_id) or not render_path(path) or not hash(fields.render_sha256)
        or not version or version < 0 or version % 1 ~= 0 or version > 2147483647 then return nil end
    receipt.book_version, receipt.file_id = version, fields.file_id
    receipt.render_path, receipt.render_sha256 = path, fields.render_sha256
    return receipt
end

-- Parent-side archive reads only. Pure hash verification and coordinate-map
-- preparation can run in a worker using this bounded byte-string envelope.
function M.document_metadata(document, expected_book, uid, path)
    local identity = FileIdentity.read_document(document, expected_book)
    if not identity.book_id or identity.book_id ~= tostring(expected_book) or not hash(identity.file_id) then
        return nil, "position_source/file_unavailable"
    end
    if (uid == nil and not render_path(path)) or (uid ~= nil and not id(tostring(uid))) then
        return nil, "position_source/invalid"
    end
    local ok, snapshot = pcall(function()
        local meta = document:getDocumentFileContent(uid ~= nil and M.meta_path(uid) or M.path_meta_path(path))
        local record = M.decode_metadata(meta)
        if not record or record.book_id ~= identity.book_id or record.file_id ~= identity.file_id
            or record.book_version ~= identity.book_version or (uid ~= nil and record.chapter_uid ~= tostring(uid))
            or (path ~= nil and record.render_path ~= path) then return nil end
        return { metadata = meta, record = record, identity = identity,
            book_id = record.book_id, chapter_uid = record.chapter_uid }
    end)
    if not ok or not snapshot then return nil, "position_source/unavailable" end
    return snapshot
end

-- A small metadata peek can stay on the UI loop; large member reads and all
-- body hashes can instead run against an independently opened worker archive.
function M.snapshot_document(document, expected_book, uid, path)
    local snapshot, err = M.document_metadata(document, expected_book, uid, path)
    if not snapshot then return nil, err end
    local ok = pcall(function()
        snapshot.raw = document:getDocumentFileContent(M.raw_path(snapshot.record.raw_sha256))
        snapshot.rendered = document:getDocumentFileContent(snapshot.record.render_path)
    end)
    snapshot.record = nil
    if not ok or type(snapshot.raw) ~= "string" or #snapshot.raw > M.MAX_BYTES
        or type(snapshot.rendered) ~= "string" or #snapshot.rendered > M.MAX_RENDERED_BYTES then
        return nil, "position_source/unavailable"
    end
    return snapshot
end

function M.verify_snapshot(snapshot)
    if type(snapshot) ~= "table" or type(snapshot.identity) ~= "table" then return nil, "position_source/invalid" end
    local record = M.decode_metadata(snapshot.metadata)
    if not record or record.book_id ~= snapshot.book_id or record.chapter_uid ~= snapshot.chapter_uid
        or record.file_id ~= snapshot.identity.file_id or record.book_id ~= snapshot.identity.book_id
        or record.book_version ~= snapshot.identity.book_version or type(snapshot.raw) ~= "string"
        or #snapshot.raw ~= record.raw_bytes or #snapshot.raw > M.MAX_BYTES or type(snapshot.rendered) ~= "string"
        or #snapshot.rendered > M.MAX_RENDERED_BYTES or Crypto.sha256_hex(snapshot.raw) ~= record.raw_sha256
        or Crypto.sha256_hex(snapshot.rendered) ~= record.render_sha256 then return nil, "position_source/invalid" end
    record.raw = snapshot.raw
    -- book_version describes the file's observed metadata. It is not evidence
    -- that a currently connected service still serves this chapter version.
    return record
end

function M.read_document(document, expected_book, uid, path)
    local snapshot, err = M.snapshot_document(document, expected_book, uid, path)
    if not snapshot then return nil, err end
    return M.verify_snapshot(snapshot)
end

return M
