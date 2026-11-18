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
    function(v) v[1].bookId='43' end,function(v) v[1].book.bookVersion='7' end,
    function(v) v[1].book.version=8 end,function(v) v[1].bookVersion=8 end,
    function(v) v[1].version='7' end,function(v) v[1].book.bookVersion=nil end}) do
    local value=F.clone(catalog);change(value);expect(M.version(value,'42')==nil)
end
local same_versions=F.clone(catalog);same_versions[1].bookVersion=7;same_versions[1].book.version=7
expect(M.version(same_versions,'42')==7)
expect(M.references({},chapters)==nil)
-- More than 128 cached references are scanned in bounded background pages.
-- The matching file is deliberately after the old limit.
local many,cache={},{}
for i=1,160 do
    local uid=i==155 and 7 or i+100
    many[i]={chapterUid=uid,chapterIdx=i==155 and 0 or i}
    cache[tostring(uid)]=i==155 and '/synthetic.epub' or '/missing-'..i..'.epub'
end
local many_book={cached_chapters=cache}
local probe=fixture();local reads=probe.options.read_archive
probe.options.read_archive=function(file,wanted) if file~='/synthetic.epub' then return nil end;return reads(file,wanted) end
local cursor,found,pages=1,nil,0
repeat
    local page=M.scan_page(many_book,many,selection,nil,cursor,probe.options);pages=pages+1
    if page.kind=='found' then found=page.reference;break end
    expect(page.kind=='more' and page.cursor>cursor);cursor=page.cursor
until pages>10
expect(found and found.chapter_uid=='7' and found.chapter_idx==0 and pages==5)
expect(M.scan_page(many_book,many,selection,result,129,probe.options).kind=='found')
local wrong=F.clone(result);wrong.ref.file='/other.epub'
expect(M.scan_page(many_book,many,selection,wrong,129,probe.options).kind=='more')
local changed_selection=F.clone(selection);changed_selection.file_id=string.rep('f',64)
expect(M.scan_page(many_book,many,changed_selection,nil,129,probe.options).kind=='more')
local duplicate=F.clone(many);duplicate[156]=F.clone(duplicate[155])
expect(M.scan_page(many_book,duplicate,selection,nil,129,probe.options).kind=='more')
local invalid=F.clone(many);invalid[2].chapterId=99999
expect(M.scan_page(many_book,invalid,selection,nil,129,probe.options).kind=='unavailable')
expect(M.scan_page(many_book,many,selection,nil,0,probe.options).kind=='unavailable')
local largest={};for i=1,10000 do largest[i]={chapterUid=i==10000 and 7 or i+100,chapterIdx=i==10000 and 0 or i} end
local last_match=M.scan_page({cached_chapters={['7']='/synthetic.epub'}},largest,selection,nil,9985,probe.options)
expect(last_match.kind=='found' and last_match.reference.chapter_uid=='7','last supported catalog entry was skipped')
local first_full=M.scan_page({cached_full_book='/synthetic.epub'},chapters,selection,nil,1,probe.options)
expect(first_full.kind=='found' and first_full.reference.file=='/synthetic.epub','full-book source did not get priority')
-- Imported XHTML source is independently tied to its cached archive, owner
-- identity and both Web catalog versions. This proves source only, not dispatch.
local cb_book={bookId='CB_Synthetic',bookVersion=7}
local cb_identity_raw=Identity.encode(cb_book,chapters,Identity.capture(cb_book),Crypto.sha256_hex(raw),7)
local cb_identity=assert(Identity.decode(cb_identity_raw))
local cb_captured=assert(Source.capture(cb_book,chapters[1],raw,'web_xhtml'))
local cb_metadata=assert(Source.bind(cb_captured,cb_identity,'OEBPS/text/chapter.xhtml',Crypto.sha256_hex(rendered)))
local cb_members={[Identity.PATH]=cb_identity_raw,[Source.meta_path('7')]=cb_metadata,
    [Source.raw_path(cb_captured.raw_sha256)]=raw,['OEBPS/text/chapter.xhtml']=rendered}
local cb_selection={book_id='CB_Synthetic',book_version=7,file_id=cb_identity.file_id}
local cb_catalog={{bookId='CB_Synthetic',book={bookVersion=7},updated=chapters}}
local cb_options={read_archive=function(_file,wanted)
    local out={} for key,maximum in pairs(wanted) do
        local value=cb_members[key];if not value or #value>maximum then return nil end;out[key]=value
    end
    return out
end}
local checks=0
cb_options.fetch=function(_client,expected,_access,format,options,cb)
    expect(cb and format=='web_xhtml');checks=checks+1
    options.verify_catalog(cb_catalog);options.verify_catalog(cb_catalog)
    return Current.project_cb(expected,cb_catalog,{book_id='CB_Synthetic',psvts='synthetic-session'},raw,cb_catalog)
end
local cb_ref={{file='/synthetic.epub',chapter_uid='7',chapter_idx=0}}
local cb_page=M.scan_page({cached_full_book='/synthetic.epub'},chapters,cb_selection,nil,1,cb_options)
expect(cb_page.kind=='found' and cb_page.reference.chapter_uid=='7')
local cb_proof=M.observe({},{},cb_selection,cb_ref,nil,cb_options)
expect(checks==1 and cb_proof.expected.book_id=='CB_Synthetic' and cb_proof.raw==nil)
expect(M.observe({},{},cb_selection,cb_ref,cb_proof,cb_options).catalog_stamp==cb_proof.catalog_stamp)
cb_catalog[1].book.bookVersion=8
expect(not pcall(M.observe,{},{},cb_selection,cb_ref,cb_proof,cb_options))
cb_catalog[1].book.bookVersion=7
cb_members['OEBPS/text/chapter.xhtml']='changed'
expect(not pcall(M.observe,{},{},cb_selection,cb_ref,cb_proof,cb_options))
cb_members['OEBPS/text/chapter.xhtml']=rendered
local cb_invalid=F.clone(cb_selection);cb_invalid.book_id='CB_invalid/'
expect(M.scan_page({cached_full_book='/synthetic.epub'},chapters,cb_invalid,nil,1,cb_options).kind=='unavailable')
expect(not pcall(M.observe,{},{},cb_invalid,cb_ref,nil,cb_options))
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
    local cb_path=os.tmpname();local cb_fd=ffi.C.open(cb_path,ffi.C.O_WRONLY+ffi.C.O_TRUNC);assert(cb_fd>=0)
    local cb_writer=require('weread.lib.epub_export_writer').new(cb_fd)
    for name,value in pairs(cb_members) do cb_writer:add(name,value,#value,false) end
    assert(cb_writer:close());assert(ffi.C.close(cb_fd)==0)
    local cb_real_refs={{file=cb_path,chapter_uid='7',chapter_idx=0}}
    local cb_runtime_options={fetch=cb_options.fetch}
    local real_cb_proof=M.observe({},{},cb_selection,cb_real_refs,nil,cb_runtime_options)
    expect(real_cb_proof.metadata_hash==Crypto.sha256_hex(cb_metadata))
    expect(M.observe({},{},cb_selection,cb_real_refs,real_cb_proof,cb_runtime_options).catalog_stamp==real_cb_proof.catalog_stamp)
    assert(os.remove(cb_path))
end
print('readtime_source_spec: '..n..' checks')
