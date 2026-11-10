-- Captured private pipe only: no credentials, native document or HTTP client.
require('setupkoenv')
package.path=assert(arg[1])..'/?.lua;'..package.path
local json=require('json')
local Source=require('weread.lib.position_source')
local Identity=require('weread.lib.book_file_identity')
local Crypto=require('weread.lib.crypto')
local Worker=require('weread.lib.source_position_worker')
local input=json.decode(io.read('*a'))
local first=input.cases[1].point
local book,chapter={book_id=first.book_id,bookVersion=1},{chapterUid=first.chapter_uid}
local identity=Identity.capture(book)
local root=Identity.encode(book,{chapter},identity,Crypto.sha256_hex(input.raw))
identity=assert(Identity.decode(root))
local captured=assert(Source.capture(book,chapter,input.raw,'web_xhtml'))
local path='OEBPS/text/chapter.xhtml'
local metadata=assert(Source.bind(captured,identity,path,Crypto.sha256_hex(input.raw)))
local members={[Identity.PATH]=root,[Source.path_meta_path(path)]=metadata,
    [Source.raw_path(captured.raw_sha256)]=input.raw,[path]=input.raw}
local results={}
for _i,case in ipairs(input.cases) do
    local target={book_id=book.book_id,chapter_uid=tostring(chapter.chapterUid),chapter_offset=case.point.chapter_offset,
        file_id=identity.file_id,book_version=identity.book_version,raw_sha256=captured.raw_sha256,
        render_path=path,basis='filtered_xhtml_utf16',upload_verified=false}
    local result=Worker.prepare_upload({file='/private-memory-fixture.epub',book_id=target.book_id,chapter_uid=target.chapter_uid,
        identity=identity,metadata=metadata,render_path=path,target=target,chapters=input.chapters,percent=case.percent},
        function() return members end)
    assert(result.candidate)
    results[#results+1]=result.candidate
end
io.write('\nSOURCE_UPLOAD_CANDIDATES=',json.encode(results))
