package.path='./?.lua;'..package.path
local Coordinates=require('weread.lib.source_coordinates')
local Worker=require('weread.lib.source_position_worker')
local Source=require('weread.lib.position_source')
local Identity=require('weread.lib.book_file_identity')
local Crypto=require('weread.lib.crypto')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message or ('check '..checks)) end
local function map(raw) return assert(Coordinates.build(raw,{format='web_txt'})) end
local raw='\239\187\191A\r\n　 <tag>&amp;😀é末尾'
local all=assert(map(raw):literal_excerpt(0))
expect(all.text==raw and all.basis=='raw_txt_utf16' and all.upload_verified==false)
expect(map(raw):literal_excerpt(2,4).text=='\r\n　 ','whitespace was normalized')
local literal=map(raw):literal_excerpt(6,11)
expect(literal.text=='<tag>&amp;😀' and literal.end_co==18,'literal markup was decoded')
local emoji=map('A😀中'):literal_excerpt(1,1)
expect(emoji.text=='😀' and emoji.end_co==3 and emoji.scalars==1,'UTF16/scalar units confused')
expect(not map('A😀中'):literal_excerpt(2),'surrogate midpoint accepted')
expect(map('abc'):literal_excerpt(2).text=='c')
for _i,offset in ipairs({-1,true,1.5,'1',0/0,math.huge,3,100}) do
    expect(not map('abc'):literal_excerpt(offset),'invalid source boundary accepted')
end
for _i,limit in ipairs({0,513,true,1.5,'1',0/0,math.huge}) do
    expect(not map('abc'):literal_excerpt(0,limit),'invalid limit accepted')
end
local max=map(string.rep('😀',600)):literal_excerpt(0,512)
expect(#max.text==2048 and max.end_co==1024 and max.scalars==512)
expect(not assert(Coordinates.build('<body>abc</body>')):literal_excerpt(6),'XHTML treated as TXT')
for _i,bad in ipairs({'','A\0B','A\237\160\128B',string.rep('x',2*1024*1024+1)}) do
    expect(not Coordinates.build(bad,{format='web_txt'}),'invalid raw source accepted')
end
-- Sparse checkpoints and trailing whitespace must preserve source widths.
local long=string.rep('甲😀乙 ',300)..'\r\n　尾'
local slice=map(long):literal_excerpt(1500,3)
expect(slice.text=='\r\n　' and slice.end_co==1503,'sparse checkpoint/tail failed')
expect(map(string.rep(' ',300)..'尾'):literal_excerpt(299,2).text==' 尾')
local book,chapter={book_id='900001',bookVersion=7},{chapterUid=11}
local path='OEBPS/text/chapter.xhtml'
local rendered=require('weread.lib.content').txt_to_xhtml(raw)
local source=assert(Source.capture(book,chapter,raw,'web_txt'))
local root=Identity.encode(book,{chapter},Identity.capture(book),Crypto.sha256_hex(rendered))
local identity=assert(Identity.decode(root))
local meta=assert(Source.bind(source,identity,path,Crypto.sha256_hex(rendered)))
local input={file='/synthetic/book.epub',book_id=book.book_id,chapter_uid='11',identity=identity,
    metadata=meta,render_path=path,request_id=81,target={book_id=book.book_id,chapter_uid='11',
        file_id=identity.file_id,book_version=7,raw_sha256=source.raw_sha256,render_path=path,
        basis='raw_txt_utf16',upload_verified=false,chapter_offset=6}}
local members={[Identity.PATH]=root,[Source.path_meta_path(path)]=meta,
    [Source.raw_path(source.raw_sha256)]=raw,[path]=rendered}
local function read(file,wanted)
    expect(file==input.file)
    local n=0;for key,limit in pairs(wanted) do n=n+1;expect(members[key] and #members[key]<=limit) end
    expect(n==4,'unexpected source member read');return members
end
local result=Worker.prepare_native_excerpt(input,read)
expect(result.request_id==81 and result.excerpt.text==raw:sub(11),'worker changed exact source slice')
expect(result.position.raw_sha256==source.raw_sha256 and result.position.book_version==7)
expect(result.position.upload_verified==false and result.excerpt.upload_verified==false)
expect(not result.raw and not result.metadata and not result.candidate and not result.position.summary,
    'excerpt became an upload DTO or leaked whole source')
expect(Worker.prepare_upload(input,read).error=='source_unsupported','legacy XHTML sender enabled TXT')
for _i,key in ipairs({'book_id','chapter_uid','file_id','book_version','raw_sha256','render_path','basis','upload_verified'}) do
    local original=input.target[key];input.target[key]=key=='upload_verified' and true or 'changed'
    expect(not Worker.prepare_native_excerpt(input,function() return members end).excerpt,'foreign source prepared')
    input.target[key]=original
end
for _i,key in ipairs({Identity.PATH,Source.path_meta_path(path),Source.raw_path(source.raw_sha256),path}) do
    local changed={};for k,v in pairs(members) do changed[k]=v end;changed[key]=changed[key]..'changed'
    expect(Worker.prepare_native_excerpt(input,function() return changed end).error=='source_changed','modified archive accepted')
end
expect(Worker.prepare_native_excerpt(input,function() error('private diagnostic') end).error=='position_unavailable')
print(('source_txt_excerpt_spec: %d checks'):format(checks))
