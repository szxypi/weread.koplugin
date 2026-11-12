package.path='./?.lua;'..package.path
package.preload.util=function() return {htmlEntitiesToUtf8=function(s) return s:gsub('&amp;','&') end} end
local Ref=require('weread.lib.selection_reference');local Source=require('weread.lib.position_source')
local Identity=require('weread.lib.book_file_identity');local Crypto=require('weread.lib.crypto')
local Quote=require('weread.lib.selection_quote');local Contract=require('weread.lib.thought_edit_contract')
local F=assert(loadfile('spec/helpers/thought_edit_fixture.lua'))();local codec=F.codec()
local checks=0;local function expect(v,label) checks=checks+1;assert(v,label) end
local raw='<html><body><p>Unique selected quote and following context for a native boundary.</p></body></html>'
local chapters={{chapterUid=2,chapterIdx=3}};local book={book_id='900001',bookVersion=7,chapters=chapters,cached_file='/cached.epub'}
local identity_raw=Identity.encode(book,chapters,Identity.capture(book),Crypto.sha256_hex(raw));local identity=assert(Identity.decode(identity_raw))
local capture=assert(Source.capture(book,chapters[1],raw,'web_xhtml'));local path='OEBPS/text/chapter.xhtml'
local metadata=assert(Source.bind(capture,identity,path,Crypto.sha256_hex(raw)))
local members={[Identity.PATH]=identity_raw,[Source.meta_path('2')]=metadata,[Source.path_meta_path(path)]=metadata,
    [Source.raw_path(Crypto.sha256_hex(raw))]=raw,[path]=raw}
local function archive(file,wanted)
    assert(file=='/cached.epub');local out={}
    for key,limit in pairs(wanted) do if members[key] and #members[key]<=limit then out[key]=members[key] end end;return out
end
local value=assert(Quote.project(raw,15,36,'Unique selected quote'))
local row=assert(Ref.capture({file='/cached.epub',book_id='900001',chapter_uid='2',first=15,last=36,text='Unique selected quote',chapters=chapters},archive))
expect(Ref.valid(row,'900001') and row.range==value.range and row.markText==value.abstract,'source reference invalid')
expect(row.chapterIdx==3 and row.source.raw_sha256==value.raw_sha256 and row.source.raw_bytes==#raw,'source metadata changed')
expect(Ref.parse(row.bookmarkId).range==row.range,'draft reference does not retain range')
expect(Ref.same(row,assert(Ref.restore(book,nil,row.bookmarkId,archive))),'offline restore changed reference')
expect(Ref.verify(row,book,nil,archive)~=nil,'valid cached reference rejected')
local reference=F.clone(row);reference.markText='Different quote';expect(not Ref.verify(reference,book,nil,archive),'forged quote accepted')
reference=F.clone(row);reference.source.chapter_idx=4;expect(not Ref.verify(reference,book,nil,archive),'stale chapter index accepted')
reference=F.clone(row);reference.source.unknown=true;expect(not Ref.valid(reference,'900001'),'unknown source field accepted')
reference=F.clone(row);reference.markText='\255';expect(not Ref.valid(reference,'900001'),'invalid UTF-8 reference accepted')
for _i,key in ipairs({'selection:02:15-36:'..value.raw_sha256,'selection:2:015-36:'..value.raw_sha256,
    'selection:2:36-15:'..value.raw_sha256,'selection:2:15-36:bad','server-mark'}) do expect(not Ref.parse(key),'noncanonical draft key accepted') end
local original=members[Source.raw_path(value.raw_sha256)];members[Source.raw_path(value.raw_sha256)]='changed'
expect(not Ref.restore(book,nil,row.bookmarkId,archive),'changed original bytes restored')
members[Source.raw_path(value.raw_sha256)]=original
local plan=Contract.make(codec,F.snapshot(codec),'create',row,'Arbitrary user thought',nil,{bookId='900001',version=77},'900000')
expect(plan.body.range==value.range and plan.body.abstract==value.abstract and plan.body.chapterIdx==nil
    and plan.body.isPrivate==1 and plan.body.bookVersion==77 and plan.body.content=='Arbitrary user thought','selection request changed verified native payload')
expect(Contract.validate_body('create',plan.body) and Contract.validate_metadata(plan.metadata),'selection plan invalid')
local native={file='/cached.epub',book_id='900001',chapter_uid='2',identity=identity,metadata=metadata,render_path=path,
    text='Uniqueselectedquoteandfollowingcontextforanativeboundary.',point_offset=0}
local endpoint=F.clone(native);endpoint.point_offset=19
local result,why=Ref.capture_native({first=native,last=endpoint,text='Unique selected quote',chapters=chapters},archive)
expect(result and Ref.same(result,row),'native contexts did not map to same source: '..tostring(why))
endpoint.metadata='changed';expect(not Ref.capture_native({first=native,last=endpoint,text='Unique selected quote',chapters=chapters},archive),'foreign native endpoint accepted')
print('selection_reference_spec: '..checks..' checks')
