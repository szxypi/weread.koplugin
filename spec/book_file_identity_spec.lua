package.path = "./?.lua;./?/init.lua;" .. package.path
local Identity = require("weread.lib.book_file_identity")
local Crypto = require("weread.lib.crypto")
local checks = 0
local function eq(value, expected, label)
    checks = checks + 1
    assert(value == expected, label .. ": got " .. tostring(value) .. ", expected " .. tostring(expected))
end
local book = { book_id = "book/with spaces", bookVersion = 7, token = "private-session", title = "private-title" }
local source = Identity.capture(book)
local chapters = { { chapterUid = 1 }, { chapterUid = 2 } }
local digest = Crypto.sha256_hex("source text")
local raw = Identity.encode(book, chapters, source, digest)
local parsed = assert(Identity.decode(raw))
eq(parsed.book_version, 7, "explicit download version bound")
eq(parsed.book_id, book.book_id, "book identifier round-trips safely")
eq(parsed.chapter_count, 2, "packaged chapter count")
eq(parsed.version_source, "epub_snapshot", "version origin explicit")
eq(#parsed.file_id, 64, "source fingerprint stored")
eq(raw:find("private-", 1, true), nil, "reading-session fields and title excluded")
local unsafe = { book_id = "book\ninjected", bookVersion = 7 }
eq(Identity.decode(Identity.encode(unsafe, chapters, Identity.capture(unsafe), digest)), nil, "control characters rejected")
for _, corrupt in ipairs({ raw:gsub("book_version=7", "book_version=8"), raw .. "schema=1\n", raw:sub(1, -2),
    raw:gsub("schema=1", "schema=2"), string.rep("x", 2049) }) do
    eq(Identity.decode(corrupt), nil, "damaged metadata not trusted")
end
local generic = { book_id = "book", version = 99 }
eq(Identity.decode(Identity.encode(generic, chapters, Identity.capture(generic), digest)).book_version, 0,
    "generic library version is not a source version")
book.bookVersion = 8
eq(Identity.decode(Identity.encode(book, chapters, source, digest)).book_version, 0, "mid-download metadata change marked unknown")
book.bookVersion = 7
eq(Identity.check(source, book), 0, "reverting metadata does not clear an observed change")
source = Identity.capture(book)
eq(Identity.decode(Identity.encode(book, chapters, nil, digest)).book_version, 0, "manual packaging cannot borrow current version")
eq(Identity.decode(Identity.encode(book, chapters, source, digest, 0)).book_version, 0, "legacy checkpoint cannot acquire current version")
eq(Identity.decode(Identity.encode(book, chapters, source, digest, 7)).book_version, 7, "matching checkpoints preserve version")
local reads = 0
local current = raw
local document = { getDocumentFileContent = function(_self, path)
    eq(path, Identity.PATH, "only the dedicated EPUB metadata member is read")
    reads = reads + 1
    return current
end }
local pinned = Identity.read_document(document, book.book_id)
book.bookVersion = 8
current = Identity.encode(book, chapters, Identity.capture(book), Crypto.sha256_hex("new source text"))
eq(Identity.read_document(document, book.book_id).book_version, 7, "open document remains bound to original version")
eq(reads, 1, "pause/resume does not reread a replaced pathname")
pinned.book_version = 999
eq(Identity.read_document(document, book.book_id).book_version, 7, "callers cannot mutate pinned identity")
eq(Identity.read_document(document, "other").book_version, 0, "another book's metadata not reused")
eq(Identity.read_document(document, "other").version_source, "book_mismatch", "mismatch remains explicit")
Identity.forget(document)
eq(Identity.read_document(document, book.book_id).book_version, 8, "new document session can read replacement version")
eq(Identity.read_document({}, "book").book_version, 0, "legacy reader without metadata remains unknown")
eq(Identity.read_document(nil, "book").file_id, "", "no disk-path fallback guesses open file identity")
print("book_file_identity_spec: " .. checks .. " checks")
