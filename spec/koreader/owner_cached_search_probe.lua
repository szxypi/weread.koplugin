-- Real source remains in a private pipe and in-memory archive; output counts only.
require('setupkoenv')
package.path='/source/?.lua;'..package.path
local result={result='UNVERIFIED',checked=0}
local ok=pcall(function()
    local raw=io.stdin:read(8*1024*1024+1);assert(#raw<=8*1024*1024)
    local input=require('json').decode(raw)
    local Search=require('weread.lib.cached_book_search')
    local Target=require('weread.lib.cached_search_target')
    local Source=require('weread.lib.position_source')
    local Identity=require('weread.lib.book_file_identity')
    local Crypto=require('weread.lib.crypto')
    local book={book_id=input.book,bookVersion=0};local chapter={chapterUid=input.chapter}
    local capture=assert(Source.capture(book,chapter,input.source,input.format))
    local root=Identity.encode(book,{chapter},Identity.capture(book),Crypto.sha256_hex(input.source))
    local identity=assert(Identity.decode(root));local render='OEBPS/text/chapter.xhtml'
    local metadata=assert(Source.bind(capture,identity,render,Crypto.sha256_hex(input.source)))
    local members={[Identity.PATH]=root,[Source.meta_path(input.chapter)]=metadata,[Source.path_meta_path(render)]=metadata,
        [Source.raw_path(Crypto.sha256_hex(input.source))]=input.source,[render]=input.source}
    local function archive(_file,wanted)
        local out={};for name,limit in pairs(wanted) do
            if not members[name] or #members[name]>limit then return nil end
            out[name]=members[name]
        end
        return out
    end
    local found=Search.scan({book=input.book,chapter=input.chapter,paths={'/memory.epub'},keyword=input.keyword,from=1},archive)
    assert(found.complete and #found.hits==1 and found.hits[1].offset==input.offset)
    local row=assert(Target.row(input.book,input.keyword,found.hits[1]))
    local bound=Target.bind_file('/memory.epub',input.book,row,1,archive)
    assert(bound.position and bound.position.chapter_offset==input.offset and bound.position.upload_verified==false)
    result={result='PASS',checked=1}
end)
if not ok then result.result='UNVERIFIED' end
print('\nWEREAD_OWNER_CACHED_SEARCH='..require('json').encode(result))
os.exit(result.result=='PASS' and 0 or 1)
