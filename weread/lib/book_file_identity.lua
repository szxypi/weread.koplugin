-- Download provenance embedded in the EPUB, independent of mutable library
-- records. A positive version is an observed bookVersion, not an API receipt.
local Crypto = require("weread.lib.crypto")
local M = { PATH = "OEBPS/weread-source.txt", MAX_BYTES = 2048 }
local documents = setmetatable({}, { __mode = "k" })

function M.version(value)
    local n = tonumber(value)
    return n and n == n and n % 1 == 0 and n > 0 and n <= 2147483647 and n or 0
end

local function book_id(book)
    return tostring(type(book) == "table" and (book.book_id or book.bookId) or "")
end

function M.capture(book)
    return { book_id = book_id(book), book_version = M.version(book and book.bookVersion) }
end

function M.check(snapshot, book)
    if snapshot and (snapshot.book_id ~= book_id(book) or snapshot.book_version ~= M.version(book and book.bookVersion)) then
        snapshot.changed = true
    end
    return snapshot and not snapshot.changed and snapshot.book_version or 0
end

local function quote(value)
    return tostring(value):gsub("[^%w._~-]", function(c) return string.format("%%%02X", c:byte()) end)
end

local function unquote(value)
    if value:gsub("%%[0-9A-F][0-9A-F]", ""):find("%", 1, true) then return nil end
    return (value:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
end

function M.encode(book, chapters, snapshot, text_digest, checkpoint_version)
    local id, version = book_id(book), M.check(snapshot, book)
    if id == "" or #id > 256 then error("missing EPUB source book identity") end
    if checkpoint_version ~= nil and version ~= checkpoint_version then version = 0 end
    if type(text_digest) ~= "string" or #text_digest ~= 64 or not text_digest:match("^[0-9a-f]+$") then version = 0 text_digest = "" end
    local payload = table.concat({ "schema=1", "book_id=" .. quote(id), "book_version=" .. tostring(version),
        "chapter_count=" .. tostring(#chapters), "text_digest=" .. text_digest, "" }, "\n")
    return payload .. "source_id=" .. Crypto.sha256_hex(payload) .. "\n"
end

function M.decode(raw)
    if type(raw) ~= "string" or #raw > M.MAX_BYTES then return nil end
    local fields, count = {}, 0
    for line in raw:gmatch("([^\n]+)\n") do
        local key, value = line:match("^([a-z_]+)=(.*)$")
        if not key or fields[key] ~= nil then return nil end
        fields[key], count = value, count + 1
    end
    if count ~= 6 or fields.schema ~= "1" or not fields.book_id or not fields.book_version or not fields.chapter_count
        or not fields.text_digest or not fields.source_id or not raw:match("\n$") then return nil end
    local payload = raw:match("^(.-)source_id=[0-9a-f]+\n$")
    if not payload or #fields.source_id ~= 64 or Crypto.sha256_hex(payload) ~= fields.source_id then return nil end
    local id, version, chapters = unquote(fields.book_id), tonumber(fields.book_version), tonumber(fields.chapter_count)
    if not id or id == "" or #id > 256 or id:find("[%z%c]") or not version
        or version < 0 or version % 1 ~= 0 or version > 2147483647
        or not chapters or chapters % 1 ~= 0 or chapters < 1 or chapters > 100000 then return nil end
    if fields.text_digest ~= "" and (#fields.text_digest ~= 64 or not fields.text_digest:match("^[0-9a-f]+$")) then return nil end
    if version > 0 and fields.text_digest == "" then return nil end
    return { book_id = id, book_version = version, chapter_count = chapters,
        file_id = fields.source_id, version_source = version > 0 and "epub_snapshot" or "epub_unknown" }
end

-- Use the open engine's archive, then pin the result to that document object.
-- A background replacement of the same pathname must not rebind an old reader.
function M.read_document(document, expected_book)
    if type(document) ~= "table" then return { book_version = 0, version_source = "unavailable", file_id = "" } end
    local identity = documents[document]
    if not identity then
        local ok, raw = pcall(function() return document:getDocumentFileContent(M.PATH) end)
        identity = ok and M.decode(raw) or nil
        identity = identity or { book_version = 0, version_source = "unavailable", file_id = "" }
        documents[document] = identity
    end
    if identity.book_id and identity.book_id ~= tostring(expected_book) then
        return { book_version = 0, version_source = "book_mismatch", file_id = "" }
    end
    local result = {}
    for key, value in pairs(identity) do result[key] = value end
    return result
end

function M.forget(document)
    if document then documents[document] = nil end
end

return M
