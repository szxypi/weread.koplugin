package.path='./?.lua;'..package.path
local M=require('weread.lib.readtime_source');local Source=require('weread.lib.position_source')
local Identity=require('weread.lib.book_file_identity');local Current=require('weread.lib.source_currentness')
local Crypto=require('weread.lib.crypto');local F=require('spec.helpers.thought_edit_fixture')
local n=0;local function expect(v) n=n+1;assert(v,'check '..n) end
local raw='<html><body><p>Synthetic captured source.</p></body></html>';local rendered=raw
local book={bookId='42',bookVersion=7};local chapters={{chapterUid=7,chapterIdx=0}}
local identity_raw=Identity.encode(book,chapters,Identity.capture(book),Crypto.sha256_hex(raw),7)
local identity=assert(Identity.decode(identity_raw));local captured=assert(Source.capture(book,chapters[1],raw,'web_xhtml'))
local metadata=assert(Source.bind(captured,identity,'OEBPS/text/chapter.xhtml',Crypto.sha256_hex(rendered)))
local members={[Identity.PATH]=identity_raw,[Source.meta_path('7')]=metadata,
    [Source.raw_path(captured.raw_sha256)]=raw,['OEBPS/text/chapter.xhtml']=rendered}
local selection={book_id='42',book_version=7,file_id=identity.file_id}
local refs=assert(M.references({cached_chapters={['7']='/synthetic.epub'},cached_full_book='/synthetic.epub'},chapters))
expect(#refs==1 and refs[1].chapter_idx==0)
local catalog={{bookId='42',book={bookVersion=7},updated=chapters}}
local function fixture()
    local f={members=F.clone(members),reads=0,fetches=0,version=7}
    f.options={read_archive=function(file,wanted)
        expect(file=='/synthetic.epub');f.reads=f.reads+1;local out={}
        for key,maximum in pairs(wanted) do
            local value=f.members[key];if not value or #value>maximum then return nil end;out[key]=value
        end
        return out
    end,fetch=function(_client,expected,_access,format,options)
        f.fetches=f.fetches+1;expect(format=='web_xhtml' and expected.raw_sha256==Crypto.sha256_hex(raw))
        local cat=F.clone(catalog);cat[1].book.bookVersion=f.version;options.verify_catalog(cat)
        if f.change_archive then f.members['OEBPS/text/chapter.xhtml']='changed rendered bytes' end
        options.verify_catalog(cat)
        return Current.project(expected,cat,{book_id='42',psvts='synthetic-session',current_chapter={chapterUid=7}},raw,cat)
    end}
    return f
end
local f=fixture();local result=M.observe({}, {},selection,refs,nil,f.options)
expect(result.metadata_hash==Crypto.sha256_hex(metadata) and result.expected.raw_bytes==#raw and f.reads==4 and f.fetches==1)
expect(result.raw==nil and result.expected.raw==nil,'source text escaped into durable metadata')
expect(M.observe({}, {},selection,refs,result,f.options).catalog_stamp==result.catalog_stamp)
for _i,mode in ipairs({'identity','raw','render','version','swap','metadata'}) do
    f=fixture()
    if mode=='identity' then f.members[Identity.PATH]=identity_raw..'changed' end
    if mode=='raw' then f.members[Source.raw_path(captured.raw_sha256)]='changed source' end
    if mode=='render' then f.members['OEBPS/text/chapter.xhtml']='changed rendered bytes' end
    if mode=='metadata' then f.members[Source.meta_path('7')]=metadata..'changed' end
    if mode=='version' then f.version=8 end
    if mode=='swap' then f.change_archive=true end
    expect(not pcall(M.observe,{},{},selection,refs,result,f.options))
end
expect(M.version(catalog,'42')==7)
for _i,change in ipairs({function(v) v[2]=F.clone(v[1]) end,function(v) v[1].book.bookVersion=true end,
    function(v) v[1].bookId='43' end,function(v) v[1].book.bookVersion='7' end}) do
    local value=F.clone(catalog);change(value);expect(M.version(value,'42')==nil)
end
expect(M.references({},chapters)==nil)
if os.getenv('WEREAD_REAL_RUNTIME')=='1' then
    local ffi=require('ffi');require('ffi/posix_h')
    local path=os.tmpname();local fd=ffi.C.open(path,ffi.C.O_WRONLY+ffi.C.O_TRUNC);assert(fd>=0)
    local writer=require('weread.lib.epub_export_writer').new(fd)
    for name,value in pairs(members) do writer:add(name,value,#value,false) end
    assert(writer:close());assert(ffi.C.close(fd)==0)
    local archive_case=fixture();archive_case.options.read_archive=nil
    local real_refs={{file=path,chapter_uid='7',chapter_idx=0}}
    local proof=M.observe({},{},selection,real_refs,nil,archive_case.options)
    expect(proof.metadata_hash==Crypto.sha256_hex(metadata))
    local lfs=require('libs/libkoreader-lfs')
    local function descriptors() local count=0;for name in lfs.dir('/proc/self/fd') do if name~='.' and name~='..' then count=count+1 end end;return count end
    collectgarbage('collect');local before=descriptors()
    for _i=1,5 do expect(M.observe({},{},selection,real_refs,proof,archive_case.options).catalog_stamp==proof.catalog_stamp) end
    collectgarbage('collect');expect(descriptors()==before,'archive descriptor leak');assert(os.remove(path))
end
print('readtime_source_spec: '..n..' checks')
