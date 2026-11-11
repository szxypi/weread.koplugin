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
print('bookmark_reference_spec: '..checks..' checks')
