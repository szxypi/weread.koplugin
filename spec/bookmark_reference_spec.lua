package.path='./?.lua;'..package.path
package.preload.util=function() return {htmlEntitiesToUtf8=function(s) return s:gsub('&amp;','&') end} end
local Ref=require('weread.lib.bookmark_reference');local Target=require('weread.lib.my_bookmark_target')
local Source=require('weread.lib.position_source');local Identity=require('weread.lib.book_file_identity')
local Crypto=require('weread.lib.crypto');local Clone=require('spec.helpers.thought_edit_fixture').clone
local checks=0;local function expect(v,label) checks=checks+1;assert(v,label) end
local raw='<html><body><p>Unique bookmark source\r\nwith enough context to locate exactly.</p></body></html>'
local chapters={{chapterUid=2,chapterIdx=3}};local book={book_id='900001',bookVersion=7,chapters=chapters,cached_file='/cached.epub'}
local root=Identity.encode(book,chapters,Identity.capture(book),Crypto.sha256_hex(raw));local identity=assert(Identity.decode(root))
local capture=assert(Source.capture(book,chapters[1],raw,'web_xhtml'));local path='OEBPS/text/chapter.xhtml'
local meta=assert(Source.bind(capture,identity,path,Crypto.sha256_hex(raw)))
local members={[Identity.PATH]=root,[Source.meta_path('2')]=meta,[Source.path_meta_path(path)]=meta,
    [Source.raw_path(Crypto.sha256_hex(raw))]=raw,[path]=raw}
local function archive(file,wanted)
    assert(file=='/cached.epub');local out={}
    for key,limit in pairs(wanted) do if members[key] and #members[key]<=limit then out[key]=members[key] end end;return out
end
local input={file='/cached.epub',book_id='900001',chapter_uid='2',identity=identity,metadata=meta,render_path=path,
    text='Uniquebookmarksourcewithenoughcontexttolocateexactly.',point_offset=0,chapters=chapters}
local row,why=Ref.capture_native(input,archive);assert(row,why)
expect(Ref.valid(row,'900001') and row.range=='15' and row.chapterIdx==3,'native reference invalid')
expect(row.markText:find('\r\n',1,true) and row.source.raw_sha256==Crypto.sha256_hex(raw),'preview/source lost')
expect(Ref.verify(row,book,nil,archive)~=nil,'valid offline reference refused')
expect(select(2,Ref.verify(row,book,nil,archive))=='web_xhtml','verified XHTML source format missing')
local server={type=0,chapterUid=2,range=row.range,bookmarkId='synthetic-point'}
expect(Target.can_locate(server),'server bookmark without text refused')
local bound=Target.bind_file('/cached.epub','900001',server,17,archive)
expect(bound.position and bound.position.chapter_offset==15 and bound.position.upload_verified==false,'bookmark archive binding failed')
expect(bound.request_id==17 and bound.position.file_id==identity.file_id and not bound.raw,'bound source identity lost')
expect(Target.resolve(book,'/wrong.epub',server,18,archive).position~=nil,'cached fallback failed')
for _i,change in ipairs({{markText='Other preview'},{markText='\255'},{chapterIdx=4},{range='015'},{type=1},{bookmarkId='server-id'}}) do
    local bad=Clone(row);for key,value in pairs(change) do bad[key]=value end
    expect(not Ref.verify(bad,book,nil,archive),'changed reference accepted')
end
local bad=Clone(row);bad.source.unknown=true;expect(not Ref.valid(bad,'900001'),'unknown source field accepted')
for _i,key in ipairs({Identity.PATH,Source.meta_path('2'),Source.path_meta_path(path),Source.raw_path(row.source.raw_sha256),path}) do
    local old=members[key];members[key]='changed'
    expect(not Ref.capture_native(input,archive),'changed archive captured')
    expect(not Ref.verify(row,book,nil,archive),'changed archive verified')
    expect(not Target.bind_file('/cached.epub','900001',server,19,archive).position,'changed source navigated')
    members[key]=old
end
bad=Clone(input);bad.metadata='stale';expect(not Ref.capture_native(bad,archive),'stale native metadata accepted')
bad=Clone(input);bad.chapters={};expect(not Ref.capture_native(bad,archive),'guessed chapter index accepted')
expect(not Ref.valid(row,'900002'),'foreign account book accepted')
local entry={book_id='900001',chapter_uid='2',chapter_idx=3,book_version=7,file_id=identity.file_id,
    source_sha256=Crypto.sha256_hex(raw)}
local direct_input=Clone(input);direct_input.metadata=entry.file_id..entry.source_sha256
local direct,direct_why=Ref.capture_direct(direct_input,entry,'/cached.epub',raw);assert(direct,direct_why)
expect(Ref.valid(direct,'900001') and direct.range==row.range and direct.markText==row.markText,'direct point changed reference')
expect(Ref.verify_direct(direct,entry,'/cached.epub',raw)~=nil,'direct source failed re-verification')
local altered=Clone(direct);altered.markText='Different preview';expect(not Ref.verify_direct(altered,entry,'/cached.epub',raw),'changed direct preview accepted')
altered=Clone(direct_input);altered.metadata='stale';expect(not Ref.capture_direct(altered,entry,'/cached.epub',raw),'stale direct metadata accepted')
altered=Clone(direct_input);altered.identity.book_version=8;expect(not Ref.capture_direct(altered,entry,'/cached.epub',raw),'different direct version accepted')
expect(not Ref.capture_direct(direct_input,entry,'/cached.epub',raw..'changed'),'different direct source accepted')
altered=Clone(entry);altered.chapter_idx=4;expect(not Ref.verify_direct(direct,altered,'/cached.epub',raw),'different direct chapter index accepted')
local cb_book={book_id='CB_Synthetic',bookVersion=7,chapters=chapters,cached_file='/cached.epub'}
local cb_root=Identity.encode(cb_book,chapters,Identity.capture(cb_book),Crypto.sha256_hex(raw));local cb_identity=assert(Identity.decode(cb_root))
local cb_meta=assert(Source.bind(assert(Source.capture(cb_book,chapters[1],raw,'web_xhtml')),cb_identity,path,Crypto.sha256_hex(raw)))
members[Identity.PATH]=cb_root;members[Source.meta_path('2')]=cb_meta;members[Source.path_meta_path(path)]=cb_meta
local cb_input=Clone(input);cb_input.book_id='CB_Synthetic';cb_input.identity=cb_identity;cb_input.metadata=cb_meta
local cb_row,cb_why=Ref.capture_native(cb_input,archive);assert(cb_row,cb_why)
expect(Ref.valid(cb_row,'CB_Synthetic') and Ref.verify(cb_row,cb_book,nil,archive),'imported bookmark reference rejected')
expect(not Ref.valid(cb_row,'CB_Other') and not Ref.verify(cb_row,book,nil,archive),'foreign imported bookmark reference accepted')
local cb_bad=Clone(cb_row);cb_bad.markText='Too short'
expect(not Ref.verify(cb_bad,cb_book,nil,archive),'short imported preview accepted')
local prefix='A self-authored test begins with one emoji: 😀.\n'
local text='A unique synthetic passage for testing a plain text bookmark.'
local txt=prefix..text..'\nA separate sentence provides sufficient extra context.'
local rendered='<html><body><p>Synthetic rendered TXT.</p></body></html>'
local txt_root=Identity.encode(cb_book,chapters,Identity.capture(cb_book),Crypto.sha256_hex(rendered))
local txt_identity=assert(Identity.decode(txt_root))
local txt_meta=assert(Source.bind(assert(Source.capture(cb_book,chapters[1],txt,'web_txt')),txt_identity,path,Crypto.sha256_hex(rendered)))
members={[Identity.PATH]=txt_root,[Source.meta_path('2')]=txt_meta,[Source.path_meta_path(path)]=txt_meta,
    [Source.raw_path(Crypto.sha256_hex(txt))]=txt,[path]=rendered}
local Dom=require('weread.lib.source_dom')
local function scalars(value) local n=0;for _char in value:gmatch('[%z\1-\127\194-\244][\128-\191]*') do n=n+1 end;return n end
local txt_input={file='/cached.epub',book_id='CB_Synthetic',chapter_uid='2',identity=txt_identity,metadata=txt_meta,render_path=path,
    text=assert(Dom.normalize(txt)),point_offset=scalars(assert(Dom.normalize(prefix))),chapters=chapters}
local txt_row,txt_why=Ref.capture_native(txt_input,archive);assert(txt_row,txt_why)
expect(txt_row.range=='48' and txt_row.markText:find(text,1,true)==1,'TXT source bookmark capture shifted')
local txt_verified,txt_format=Ref.verify(txt_row,cb_book,nil,archive)
expect(txt_verified and txt_format=='web_txt' and txt_verified.range=='48','TXT bookmark verification lost source format')
local txt_server={type=0,chapterUid=2,range=txt_row.range,bookmarkId='synthetic-txt-point',markText=txt_row.markText}
local txt_bound=Target.bind_file('/cached.epub','CB_Synthetic',txt_server,20,archive)
expect(txt_bound.position and txt_bound.position.chapter_offset==48 and txt_bound.position.basis=='raw_txt_utf16',
    'TXT bookmark did not bind to exact local source')
local txt_bad=Clone(txt_row);txt_bad.markText='Changed preview with enough words'
expect(not Ref.verify(txt_bad,cb_book,nil,archive),'changed TXT bookmark preview accepted')
members[Source.raw_path(Crypto.sha256_hex(txt))]='changed'
expect(not Ref.verify(txt_row,cb_book,nil,archive),'changed TXT bookmark source accepted')
print('bookmark_reference_spec: '..checks..' checks')
