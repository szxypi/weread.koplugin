package.path='./?.lua;'..package.path
package.preload.util=function() return {htmlEntitiesToUtf8=function(value) return value end} end
local Content=require('weread.lib.content')
local Search=require('weread.lib.cached_book_search')
local Target=require('weread.lib.cached_search_target')
local Source=require('weread.lib.position_source')
local Identity=require('weread.lib.book_file_identity')
local Crypto=require('weread.lib.crypto')
local Cloud=require('weread.lib.source_cloud')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local book={book_id='CB_Synthetic',bookVersion=7}
local chapter={chapterUid='2',chapterIdx=1}
local raw='First synthetic passage.\r\n\r\n    Unique needle for local TXT navigation.\r\nLast synthetic passage.'
local rendered=Content.txt_to_xhtml(raw)
local captured=assert(Source.capture(book,chapter,raw,'web_txt'))
local root=Identity.encode(book,{chapter},Identity.capture(book),Crypto.sha256_hex(rendered))
local identity=assert(Identity.decode(root));local render='OEBPS/text/chapter.xhtml'
local metadata=assert(Source.bind(captured,identity,render,Crypto.sha256_hex(rendered)))
local files={[Identity.PATH]=root,[Source.meta_path('2')]=metadata,[Source.path_meta_path(render)]=metadata,
    [Source.raw_path(captured.raw_sha256)]=raw,[render]=rendered}
local function archive(_,wanted)
    local result={};for name,limit in pairs(wanted) do if not files[name] or #files[name]>limit then return end;result[name]=files[name] end
    return result
end
local query={book=book.book_id,chapter='2',paths={'/fixture.epub'},keyword='needle',from=1}
local found=Search.scan(query,archive)
expect(#found.hits==1,'personal TXT local search did not find the source')
local row=assert(Target.row(book.book_id,query.keyword,found.hits[1]))
local bound=Target.bind_file('/fixture.epub',book.book_id,row,9,archive)
expect(bound.position and bound.position.basis=='raw_txt_utf16' and bound.position.upload_verified==false,
    'local personal TXT search could not bind an unsendable target')
expect(bound.position.chapter_offset==found.hits[1].offset and bound.request_id==9,'target changed local source position')
local remote={book_id=book.book_id,chapter_uid='2',chapter_offset=found.hits[1].offset,raw_sha256=captured.raw_sha256,
    raw_bytes=#raw,basis='raw_txt_utf16',upload_verified=false,percent=1}
expect(not Cloud.remote(remote) and not Cloud.bind({file='/fixture.epub',identity=identity,book_id=book.book_id},remote,archive).position,
    'local search changed the CB TXT cloud-coordinate restriction')
files[render]=rendered..'changed'
expect(not Target.bind_file('/fixture.epub',book.book_id,row,9,archive).position,'changed rendered text was accepted')
files[render]=rendered
local reads=0
local function changed_uid_metadata(file,wanted)
    reads=reads+1
    local result=archive(file,wanted)
    if reads==3 and result and wanted[Source.meta_path('2')] then result[Source.meta_path('2')]='changed' end
    return result
end
expect(not Target.bind_file('/fixture.epub',book.book_id,row,9,changed_uid_metadata).position,
    'changed chapter identity mapping was accepted between reads')
files[Source.path_meta_path(render)]='invalid'
expect(not Target.bind_file('/fixture.epub',book.book_id,row,9,archive).position,'changed source metadata was accepted')
print(('cached_search_txt_cb_spec: %d checks'):format(checks))
