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
expect(select(3,Ref.restore(book,nil,row.bookmarkId,archive))=='/cached.epub','restored draft lost its source archive')
expect(Ref.verify(row,book,nil,archive)~=nil,'valid cached reference rejected')
expect(select(2,Ref.verify(row,book,nil,archive))=='web_xhtml','verified XHTML source format missing')
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
local direct_entry={book_id='900001',chapter_uid='2',chapter_idx=3,book_version=7,file_id=identity.file_id,
    source_sha256=Crypto.sha256_hex(raw)}
local direct_first=F.clone(native);direct_first.metadata=direct_entry.file_id..direct_entry.source_sha256
local direct_last=F.clone(direct_first);direct_last.point_offset=19
local direct_input={first=direct_first,last=direct_last,text='Unique selected quote'}
local direct=assert(Ref.capture_direct(direct_input,direct_entry,'/cached.epub',raw))
expect(Ref.same(direct,row) and Ref.same(assert(Ref.verify_direct(direct,direct_entry,'/cached.epub',raw)),row),
    'direct chapter selection differed from independently cached source')
expect(Ref.same(assert(Ref.restore_direct(direct_entry,'/cached.epub',direct.bookmarkId,raw)),direct),
    'direct chapter draft did not restore its exact quote')
expect(not Ref.restore_direct(direct_entry,'/cached.epub',direct.bookmarkId,raw..'changed'),'changed direct draft source was accepted')
expect(not Ref.capture_direct(direct_input,direct_entry,'/cached.epub',raw..'changed'),'changed direct source was accepted')
local foreign=F.clone(direct_input);foreign.last.identity.file_id=string.rep('e',64)
expect(not Ref.capture_direct(foreign,direct_entry,'/cached.epub',raw),'foreign direct endpoint was accepted')
foreign=F.clone(direct_input);foreign.text='Unique selected changes'
expect(not Ref.capture_direct(foreign,direct_entry,'/cached.epub',raw),'different direct selection was accepted')
local duplicate=raw:gsub('</body>','<p>Unique selected quote and following context for a native boundary.</p></body>')
local duplicate_entry=F.clone(direct_entry);duplicate_entry.source_sha256=Crypto.sha256_hex(duplicate)
local ambiguous=F.clone(direct_input);ambiguous.first.metadata=duplicate_entry.file_id..duplicate_entry.source_sha256
ambiguous.last.metadata=ambiguous.first.metadata
expect(not Ref.capture_direct(ambiguous,duplicate_entry,'/cached.epub',duplicate),'ambiguous repeated direct selection was accepted')
local forged_direct=F.clone(direct);forged_direct.markText='Different quote'
expect(not Ref.verify_direct(forged_direct,direct_entry,'/cached.epub',raw),'forged direct quote was accepted')
endpoint.metadata='changed';expect(not Ref.capture_native({first=native,last=endpoint,text='Unique selected quote',chapters=chapters},archive),'foreign native endpoint accepted')
local imported_book={book_id='CB_Synthetic',bookVersion=7,chapters=chapters,cached_file='/cached.epub'}
local imported_identity_raw=Identity.encode(imported_book,chapters,Identity.capture(imported_book),Crypto.sha256_hex(raw))
local imported_identity=assert(Identity.decode(imported_identity_raw))
local imported_metadata=assert(Source.bind(assert(Source.capture(imported_book,chapters[1],raw,'web_xhtml')),
    imported_identity,path,Crypto.sha256_hex(raw)))
members[Identity.PATH]=imported_identity_raw;members[Source.meta_path('2')]=imported_metadata;members[Source.path_meta_path(path)]=imported_metadata
local imported=assert(Ref.capture({file='/cached.epub',book_id='CB_Synthetic',chapter_uid='2',first=15,last=36,
    text='Unique selected quote',chapters=chapters},archive))
expect(Ref.valid(imported,'CB_Synthetic') and Ref.verify(imported,imported_book,nil,archive),'imported source did not bind and restore')
expect(not Ref.valid(imported,'CB_Other') and not Ref.verify(imported,book,nil,archive),'foreign imported reference was accepted')
native.book_id='CB_Synthetic';native.identity=imported_identity;native.metadata=imported_metadata
endpoint=F.clone(native);endpoint.point_offset=19
local imported_native=assert(Ref.capture_native({first=native,last=endpoint,text='Unique selected quote',chapters=chapters},archive))
expect(Ref.same(imported_native,imported),'imported native endpoints mapped to another selection')
local cb_snapshot=F.snapshot(codec);cb_snapshot.book_id='CB_Synthetic'
local cb_plan=Contract.make(codec,cb_snapshot,'create',imported,'Thought',nil,{bookId='CB_Synthetic',version=77},'900000')
expect(Contract.validate_body('create',cb_plan.body) and cb_plan.body.chapterIdx==nil and cb_plan.body.isPrivate==1
    and cb_plan.body.abstract==imported.markText,'imported selection did not preserve verified private context')
local prefix='A self-authored test begins with one emoji: 😀.\n'
local txt_quote='A unique synthetic passage for testing a plain text highlight.'
local txt=prefix..txt_quote..'\nA separate following sentence provides context.'
local txt_render='<html><body><p>Synthetic TXT rendering.</p></body></html>'
local txt_identity_raw=Identity.encode(imported_book,chapters,Identity.capture(imported_book),Crypto.sha256_hex(txt_render))
local txt_identity=assert(Identity.decode(txt_identity_raw))
local txt_metadata=assert(Source.bind(assert(Source.capture(imported_book,chapters[1],txt,'web_txt')),
    txt_identity,path,Crypto.sha256_hex(txt_render)))
members={[Identity.PATH]=txt_identity_raw,[Source.meta_path('2')]=txt_metadata,[Source.path_meta_path(path)]=txt_metadata,
    [Source.raw_path(Crypto.sha256_hex(txt))]=txt,[path]=txt_render}
local txt_row=assert(Ref.capture({file='/cached.epub',book_id='CB_Synthetic',chapter_uid='2',first=48,last=110,
    text=txt_quote,chapters=chapters},archive))
expect(txt_row.range=='48-110' and txt_row.markText==txt_quote,'TXT selection range was not UTF-16')
expect(Ref.same(txt_row,assert(Ref.restore(imported_book,nil,txt_row.bookmarkId,archive))),'TXT draft did not restore')
local verified,format=Ref.verify(txt_row,imported_book,nil,archive)
expect(verified and Ref.same(verified,txt_row) and format=='web_txt','verified TXT identity or format missing')
local function scalar_count(text) local n=0;for _char in text:gmatch('[%z\1-\127\194-\244][\128-\191]*') do n=n+1 end;return n end
local Dom=require('weread.lib.source_dom');local context=assert(Dom.normalize(txt))
local before=scalar_count(assert(Dom.normalize(prefix)));local selected=scalar_count(assert(Dom.normalize(txt_quote)))
local first={file='/cached.epub',book_id='CB_Synthetic',chapter_uid='2',identity=txt_identity,metadata=txt_metadata,
    render_path=path,text=context,point_offset=before}
local last=F.clone(first);last.point_offset=before+selected
local txt_native=assert(Ref.capture_native({first=first,last=last,text=txt_quote,chapters=chapters},archive))
expect(Ref.same(txt_native,txt_row),'TXT native selection did not bind to source')
last.metadata='changed';expect(not Ref.capture_native({first=first,last=last,text=txt_quote,chapters=chapters},archive),'foreign TXT metadata accepted')
local forged=F.clone(txt_row);forged.markText='Changed';expect(not Ref.verify(forged,imported_book,nil,archive),'changed TXT quotation accepted')
members[Source.raw_path(Crypto.sha256_hex(txt))]='changed'
expect(not Ref.verify(txt_row,imported_book,nil,archive),'changed TXT source accepted')
print('selection_reference_spec: '..checks..' checks')
