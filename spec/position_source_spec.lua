-- Exact-byte provenance and open-archive verification; no network or account.
package.path = './?.lua;' .. package.path
local Source = require('weread.lib.position_source')
local Identity = require('weread.lib.book_file_identity')
local Crypto = require('weread.lib.crypto')
local checks = 0
local function expect(value, message)
    checks = checks + 1
    assert(value, message or ('check ' .. checks))
end
local book = { book_id = 'synthetic/book', bookVersion = 7, token = 'not-captured', title = 'not-captured' }
local chapter = { chapterUid = 42 }
local raw = '\239\187\191<html><body><p>A &amp; B 中文😀</p><img src="https://example.invalid/long-image.jpg"/></body></html>'
local source = assert(Source.capture(book, chapter, raw, 'web_xhtml'))
expect(source.raw == raw and source.raw_bytes == #raw, 'original bytes changed')
expect(not source.token and not source.title and not source.bookVersion, 'unrelated data captured')
expect(source.capture_id == assert(Source.capture(book, chapter, raw, 'web_xhtml')).capture_id, 'unstable receipt')
expect(source.capture_id ~= assert(Source.capture(book, chapter, raw .. ' ', 'web_xhtml')).capture_id, 'changed raw has same receipt')
for _, input in ipairs({ '', string.rep('x', Source.MAX_BYTES + 1) }) do
    expect(not Source.capture(book, chapter, input, 'web_xhtml'), 'unsupported size accepted')
end
expect(not Source.capture({}, chapter, raw, 'web_xhtml'), 'missing book accepted')
expect(not Source.capture(book, {}, raw, 'web_xhtml'), 'missing UID accepted')
expect(not Source.capture(book, chapter, raw, 'rewritten'), 'invented format accepted')
local txt = assert(Source.capture(book, chapter, '\239\187\191plain\r\ntext  \r\n', 'web_txt'))
expect(txt.raw == '\239\187\191plain\r\ntext  \r\n' and txt.format == 'web_txt', 'TXT normalized before capture')
local rendered = '<html><body><p>A &amp; B 中文😀</p><img src="../images/local.jpg"/></body></html>'
local root = Identity.encode(book, {chapter}, Identity.capture(book), Crypto.sha256_hex(rendered))
local identity = assert(Identity.decode(root))
local path = 'OEBPS/text/chapter-001.xhtml'
local metadata = assert(Source.bind(source, identity, path, Crypto.sha256_hex(rendered)))
local decoded = assert(Source.decode_metadata(metadata))
expect(decoded.book_version == 7 and decoded.chapter_uid == '42' and decoded.render_path == path, 'scope lost')
expect(not metadata:find('not-captured', 1, true) and not metadata:find('https://', 1, true), 'raw/unrelated data in metadata')
expect(not Source.decode_metadata(metadata .. 'extra=1\n'), 'trailing field accepted')
expect(not Source.decode_metadata(metadata:gsub('raw_bytes=', 'other_bytes=')), 'tampered metadata accepted')
expect(not Source.decode_metadata(string.rep('x', Source.MAX_META_BYTES + 1)), 'oversized metadata accepted')
for _, invalid in ipairs({ '../text/chapter.xhtml', 'OEBPS/text/../chapter.xhtml', 'OEBPS/text/chapter-000.xhtml', 'OEBPS/text/chapter-100001.xhtml', 'https://example.invalid/chapter.xhtml' }) do
    expect(not Source.bind(source, identity, invalid, Crypto.sha256_hex(rendered)), 'invalid member path accepted')
end
local bad = {}
for key, value in pairs(source) do bad[key] = value end
bad.capture_id = string.rep('0', 64)
expect(not Source.bind(bad, identity, path, Crypto.sha256_hex(rendered)), 'invalid capture seal bound')
local archive = { [Identity.PATH] = root, [Source.meta_path(42)] = metadata,
    [Source.path_meta_path(path)] = metadata, [Source.raw_path(source.raw_sha256)] = raw, [path] = rendered }
local calls = 0
local doc = { getDocumentFileContent = function(_self, name) calls = calls + 1; return archive[name] end }
local snapshot = assert(Source.snapshot_document(doc, book.book_id, 42))
expect(calls == 4 and snapshot.raw == raw and snapshot.rendered == rendered, 'archive envelope incomplete')
expect(assert(Source.verify_snapshot(snapshot)).raw == raw, 'snapshot did not verify')
expect(assert(Source.read_document(doc, book.book_id, nil, path)).capture_id == source.capture_id, 'path alias failed')
expect(not Source.read_document(doc, 'other-book', 42), 'wrong book accepted')
expect(not Source.read_document(doc, book.book_id, 43), 'wrong chapter accepted')
expect(not Source.read_document(doc, book.book_id, 42, 'OEBPS/text/chapter-002.xhtml'), 'wrong rendered alias accepted')
expect(not Source.read_document({file='/never/read/this.epub'}, book.book_id, 42), 'disk fallback used')
local pinned = Identity.read_document(doc, book.book_id)
pinned.file_id = 'mutation'
expect(Identity.read_document(doc, book.book_id).file_id == identity.file_id, 'caller changed pinned identity')
book.bookVersion = 99
expect(assert(Source.read_document(doc, book.book_id, 42)).book_version == 7, 'library version rebound open EPUB')
archive[path] = rendered .. 'tamper'
expect(not Source.read_document(doc, book.book_id, 42), 'changed rendered content accepted')
archive[path] = rendered
archive[Source.raw_path(source.raw_sha256)] = raw .. 'tamper'
expect(not Source.read_document(doc, book.book_id, 42), 'changed raw accepted')
archive[Source.raw_path(source.raw_sha256)] = raw
snapshot.raw = raw .. 'tamper'
expect(not Source.verify_snapshot(snapshot), 'worker envelope corruption accepted')
-- A replaced archive cannot reuse the open document's pinned root.
local other = assert(Identity.decode(Identity.encode(book, {chapter}, Identity.capture(book), Crypto.sha256_hex(rendered))))
archive[Source.meta_path(42)] = assert(Source.bind(source, other, path, Crypto.sha256_hex(rendered)))
expect(not Source.read_document(doc, book.book_id, 42), 'replaced metadata rebound open document')
archive[Identity.PATH] = Identity.encode(book, {chapter}, Identity.capture(book), Crypto.sha256_hex(rendered))
local reopened = { getDocumentFileContent = doc.getDocumentFileContent }
expect(assert(Source.read_document(reopened, book.book_id, 42)).book_version == 99, 'reopened document did not bind new root')
archive[Source.meta_path(42)] = nil
expect(not Source.read_document(reopened, book.book_id, 42), 'legacy archive fabricated provenance')
print(('position_source_spec: %d checks'):format(checks))
