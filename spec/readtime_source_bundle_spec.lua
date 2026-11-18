package.path='./?.lua;'..package.path
local M=require('weread.lib.readtime_source_bundle')
local Identity=require('weread.lib.book_file_identity')
local Source=require('weread.lib.position_source')
local Crypto=require('weread.lib.crypto')
local Current=require('weread.lib.source_currentness')
local Reader=require('weread.lib.readtime_source')
local F=require('spec.helpers.thought_edit_fixture')
local n=0
local function expect(value,message) n=n+1;assert(value,message or ('check '..n)) end
local book={bookId='CB_Synthetic',bookVersion=0}
local chapters={{chapterUid=7,chapterIdx=0,wordCount=100},{chapterUid=8,chapterIdx=4,wordCount=100},
    {chapterUid=9,chapterIdx=8,wordCount=100}}
local root=Identity.encode(book,chapters,Identity.capture(book),Crypto.sha256_hex('synthetic book'),0)
local identity=assert(Identity.decode(root))
local selection={book_id=book.bookId,book_version=0,file_id=identity.file_id}
local original={[Identity.PATH]=root}
local names={}
for i,chapter in ipairs(chapters) do
    local raw='Synthetic TXT chapter '..i
    local rendered='<p>'..raw..'</p>'
    local path=string.format('OEBPS/text/chapter-%03d.xhtml',i)
    local captured=assert(Source.capture(book,chapter,raw,'web_txt'))
    local meta=assert(Source.bind(captured,identity,path,Crypto.sha256_hex(rendered)))
    local name=Source.meta_path(tostring(chapter.chapterUid))
    names[i]=name
    original[name],original[Source.path_meta_path(path)]=meta,meta
    original[Source.raw_path(captured.raw_sha256)],original[path]=raw,rendered
end
local function fixture()
    local members=F.clone(original)
    local options={}
    options.read_archive=function(_file,wanted)
        local out={}
        for name,limit in pairs(wanted) do
            local value=members[name];if not value or #value>limit then return nil end
            out[name]=value
        end
        return out
    end
    options.list_metadata=function()
        local out={}
        for _i,name in ipairs(names) do if members[name] then out[#out+1]={name=name,metadata=members[name]} end end
        return out
    end
    return members,options
end
local options=select(2,fixture())
local result=assert(M.inspect(selection,'/synthetic.epub',chapters,options))
expect(#result.entries==3 and result.entries[2].chapter_uid=='8' and result.entries[2].chapter_idx==4)
expect(Crypto.sha256_hex('Synthetic TXT chapter 2')==result.entries[2].raw_sha256)
expect(result.entries[2].raw==nil and result.entries[2].rendered==nil and #result.inventory_hash==64)
expect(M.inspect(selection,'/synthetic.epub',chapters,options).inventory_hash==result.inventory_hash)
for _i,change in ipairs({
    function(v) v[names[2]]=nil end,
    function(v) v[names[2]]=v[names[2]]..'bad' end,
    function(v) v[Source.path_meta_path('OEBPS/text/chapter-002.xhtml')]=nil end,
    function(v) v['OEBPS/text/chapter-002.xhtml']='different' end,
    function(v) v[Source.raw_path(Crypto.sha256_hex('Synthetic TXT chapter 2'))]='different' end,
    function(v) v[Identity.PATH]=root..'bad' end,
}) do
    local members;members,options=fixture();change(members)
    expect(M.inspect(selection,'/synthetic.epub',chapters,options)==nil,'damaged source accepted')
end
options=select(2,fixture())
for _i,change in ipairs({
    function(v) v[2].chapterIdx=0 end,
    function(v) v[2].chapterUid=7 end,
    function(v) v[2].chapterUid=10 end,
    function(v) v[2].chapterIdx=nil end,
    function(v) v[2],v[3]=v[3],v[2] end,
    function(v) v.extra=true end,
}) do
    local altered=F.clone(chapters);change(altered)
    expect(M.inspect(selection,'/synthetic.epub',altered,options)==nil,'ambiguous catalog accepted')
end
local other=F.clone(selection);other.file_id=string.rep('f',64)
expect(M.inspect(other,'/synthetic.epub',chapters,options)==nil)
other=F.clone(selection);other.book_id='42'
expect(M.inspect(other,'/synthetic.epub',chapters,options)==nil)
other=F.clone(selection);other.book_version=1
expect(M.inspect(other,'/synthetic.epub',chapters,options)==nil)
local old=options.list_metadata;local calls=0
options.list_metadata=function(...)
    calls=calls+1
    local output=old(...)
    if calls==2 then table.remove(output) end
    return output
end
expect(M.inspect(selection,'/synthetic.epub',chapters,options)==nil,'changed inventory accepted')
local function remote_fixture()
    local files,opts=fixture()
    local state={catalog={{bookId=book.bookId,book={bookId=book.bookId},updated=F.clone(chapters)}},calls=0}
    opts.fetch=function(_client,expected,_web,check)
        state.calls=state.calls+1
        local before=F.clone(state.catalog);check(before)
        local raw='Synthetic TXT chapter '..(expected.chapter_uid=='7' and 1 or expected.chapter_uid=='8' and 2 or 3)
        if state.changed_source and expected.chapter_uid=='8' then raw='changed remotely' end
        local after=F.clone(before)
        if state.changed_catalog and expected.chapter_uid=='8' then after[1].updated[3].chapterIdx=11 end
        if not state.missing_check then check(after) end
        if state.changed_archive and expected.chapter_uid=='8' then files['OEBPS/text/chapter-002.xhtml']='changed' end
        local proof=Current.project_cb(expected,before,{book_id=book.bookId,psvts='synthetic-session'},raw,after)
        proof.basis='raw_txt_utf16';return proof
    end
    return state,opts
end
local state,remote=remote_fixture()
local proof=M.verify({}, {},selection,'/synthetic.epub',chapters,nil,remote)
expect(proof.chapter_count==3 and proof.inventory_hash==result.inventory_hash and state.calls==3)
expect(proof.entries==nil and proof.format=='web_txt' and #proof.catalog_stamp==64)
expect(M.verify({}, {},selection,'/synthetic.epub',chapters,proof,remote).inventory_hash==proof.inventory_hash)
-- Full downloads contain only readable chapters, whereas the Web catalog and
-- older library records can also contain a cover and an empty section header.
state,remote=remote_fixture()
local cover={chapterUid=5,chapterIdx=15,wordCount=100,title='封面'}
local section={chapterUid=6,chapterIdx=16,wordCount=0,title='Synthetic section'}
local full_catalog={cover,chapters[1],section,chapters[2],chapters[3]}
state.catalog[1].updated=full_catalog
local filtered=M.verify({}, {},selection,'/synthetic.epub',chapters,nil,remote)
expect(filtered.chapter_count==3,'non-readable catalog rows blocked the archive')
local with_extra=M.verify({}, {},selection,'/synthetic.epub',full_catalog,nil,remote)
expect(with_extra.inventory_hash==filtered.inventory_hash,'older full catalog lost archive chapters')
local base_fetch=remote.fetch;local fetch_count=0
remote.fetch=function(...)
    fetch_count=fetch_count+1
    if fetch_count==2 then state.catalog[1].updated[1].chapterIdx=17 end
    return base_fetch(...)
end
expect(not pcall(M.verify,{}, {},selection,'/synthetic.epub',chapters,nil,remote),'changed cover metadata was ignored')
for _i,mode in ipairs({'changed_source','changed_catalog','missing_check','changed_archive'}) do
    state,remote=remote_fixture();state[mode]=true
    expect(not pcall(M.verify,{}, {},selection,'/synthetic.epub',chapters,nil,remote),'changed remote bundle accepted')
end
for _i,change in ipairs({
    function(c) c[1].book.version=0 end,
    function(c) table.remove(c[1].updated) end,
    function(c) c[1].updated[4]={chapterUid=10,chapterIdx=9,wordCount=100} end,
    function(c) c[1].updated[2],c[1].updated[3]=c[1].updated[3],c[1].updated[2] end,
}) do
    state,remote=remote_fixture();change(state.catalog)
    expect(not pcall(M.verify,{}, {},selection,'/synthetic.epub',chapters,nil,remote),'different catalog accepted')
end
remote=select(2,remote_fixture())
local wrong=F.clone(proof);wrong.catalog_stamp=string.rep('f',64)
expect(not pcall(M.verify,{}, {},selection,'/synthetic.epub',chapters,wrong,remote),'changed previous proof accepted')
state,remote=remote_fixture()
local fetch=remote.fetch
remote.fetch=function(client,expected,web,format,callbacks,cb)
    assert(format=='web_txt' and cb)
    return fetch(client,expected,web,callbacks.verify_catalog)
end
local book_ref={cached_full_book='/synthetic.epub'}
local refs=assert(Reader.references(book_ref,chapters,selection))
expect(#refs==1 and #refs[1].chapters==3,'full archive did not retain its chapter scope')
local observed=Reader.observe({}, {},selection,refs,nil,remote)
expect(observed.chapter_count==3 and observed.ref.file=='/synthetic.epub' and observed.ref.chapters==nil)
expect(Reader.observe({}, {},selection,refs,observed,remote).inventory_hash==observed.inventory_hash)
expect(Reader.scan_page(book_ref,chapters,selection,nil,1,remote).reference.chapters~=nil)
expect(Reader.scan_page(book_ref,chapters,selection,observed,1,remote).reference.chapters~=nil)
state.changed_source=true
expect(not pcall(Reader.observe,{}, {},selection,refs,observed,remote),'changed multi-chapter source accepted')
state,remote=remote_fixture();state.catalog[1].updated=full_catalog
fetch=remote.fetch
remote.fetch=function(client,expected,web,format,callbacks,cb)
    assert(format=='web_txt' and cb);return fetch(client,expected,web,callbacks.verify_catalog)
end
local full_refs=assert(Reader.references(book_ref,full_catalog,selection))
local full_observed=Reader.observe({}, {},selection,full_refs,nil,remote)
expect(full_observed.chapter_count==3 and full_observed.ref.chapter_uid=='7',
    'full catalog did not bind the first actual archive chapter')
expect(Reader.scan_page(book_ref,full_catalog,selection,full_observed,1,remote).kind=='found',
    'full catalog could not recover the previous proof')
local filtered_refs=assert(Reader.references(book_ref,chapters,selection))
expect(Reader.observe({}, {},selection,filtered_refs,full_observed,remote).inventory_hash==full_observed.inventory_hash,
    'filtered catalog could not resolve the previous full-catalog proof')
expect(Reader.scan_page(book_ref,chapters,selection,full_observed,1,remote).kind=='found',
    'filtered catalog could not discover the previous full-catalog proof')
-- The UI switches to background paging above 126 chapters. Its returned
-- reference must still carry the complete scope into the transfer worker.
local large_chapters={}
for i=1,127 do large_chapters[i]={chapterUid=i+100,chapterIdx=i-1,wordCount=100} end
local large_root=Identity.encode(book,large_chapters,Identity.capture(book),Crypto.sha256_hex('large synthetic book'),0)
local large_id=assert(Identity.decode(large_root));local large_members={[Identity.PATH]=large_root};local large_list={}
for i,chapter in ipairs(large_chapters) do
    local raw='same synthetic chapter body';local path=string.format('OEBPS/text/chapter-%03d.xhtml',i)
    local source=assert(Source.capture(book,chapter,raw,'web_txt'))
    local meta=assert(Source.bind(source,large_id,path,Crypto.sha256_hex(raw)))
    local name=Source.meta_path(tostring(chapter.chapterUid))
    large_members[name],large_members[Source.path_meta_path(path)]=meta,meta
    large_members[Source.raw_path(source.raw_sha256)],large_members[path]=raw,raw
    large_list[i]={name=name,metadata=meta}
end
local large_selection={book_id=book.bookId,book_version=0,file_id=large_id.file_id}
local large_options={read_archive=function(_file,wanted)
    local out={};for name,limit in pairs(wanted) do
        local value=large_members[name];if not value or #value>limit then return nil end;out[name]=value
    end;return out
end,list_metadata=function() return large_list end}
local page=Reader.scan_page({cached_full_book='/large.epub'},large_chapters,large_selection,nil,1,large_options)
expect(page.kind=='found' and #page.reference.chapters==127,'paged full archive lost chapter scope')
local large_catalog={{bookId=book.bookId,book={bookId=book.bookId},updated=large_chapters}}
local remote_calls=0
large_options.fetch=function(_client,expected,_web,format,callbacks,cb)
    assert(format=='web_txt' and cb);remote_calls=remote_calls+1
    callbacks.verify_catalog(large_catalog);callbacks.verify_catalog(large_catalog)
    local value=Current.project_cb(expected,large_catalog,{book_id=book.bookId,psvts='synthetic-session'},
        'same synthetic chapter body',large_catalog)
    value.basis='raw_txt_utf16';return value
end
local large_proof=Reader.observe({}, {},large_selection,{page.reference},nil,large_options)
expect(large_proof.chapter_count==127 and remote_calls==127 and large_proof.ref.chapters==nil,
    'paged transfer did not verify every chapter')
-- The offline search UI can only navigate 32-bit chapter IDs. Source
-- verification uses string IDs and must not inherit that UI limitation.
-- Two adjacent values above 2^53 also expose accidental numeric conversion.
local long_chapters={
    {chapterUid='2147483648',chapterIdx=0,wordCount=100},
    {chapterUid='9007199254740992',chapterIdx=1,wordCount=100},
    {chapterUid='9007199254740993',chapterIdx=2,wordCount=100},
    {chapterUid='99999999999999999999',chapterIdx=3,wordCount=100},
}
local long_root=Identity.encode(book,long_chapters,Identity.capture(book),Crypto.sha256_hex('long ids'),0)
local long_identity=assert(Identity.decode(long_root));local long_members={[Identity.PATH]=long_root};local long_list={}
for i,chapter in ipairs(long_chapters) do
    local raw='Synthetic long chapter '..i;local path=string.format('OEBPS/text/chapter-%03d.xhtml',i)
    local capture=assert(Source.capture(book,chapter,raw,'web_txt'))
    local meta=assert(Source.bind(capture,long_identity,path,Crypto.sha256_hex(raw)))
    local name=Source.meta_path(chapter.chapterUid)
    long_members[name],long_members[Source.path_meta_path(path)]=meta,meta
    long_members[Source.raw_path(capture.raw_sha256)],long_members[path]=raw,raw
    long_list[i]={name=name,metadata=meta}
end
local long_selection={book_id=book.bookId,book_version=0,file_id=long_identity.file_id}
local long_options={read_archive=function(_file,wanted)
    local out={};for name,limit in pairs(wanted) do
        local value=long_members[name];if not value or #value>limit then return nil end;out[name]=value
    end;return out
end,list_metadata=function() return long_list end}
local long_catalog={{bookId=book.bookId,book={bookId=book.bookId},updated=long_chapters}}
local long_calls=0
long_options.fetch=function(_client,expected,_web,format,callbacks,cb)
    assert(format=='web_txt' and cb);long_calls=long_calls+1
    expect(expected.chapter_uid==long_chapters[long_calls].chapterUid,'chapter ID lost precision')
    callbacks.verify_catalog(long_catalog);callbacks.verify_catalog(long_catalog)
    local value=Current.project_cb(expected,long_catalog,{book_id=book.bookId,psvts='synthetic-session'},
        'Synthetic long chapter '..long_calls,long_catalog)
    value.basis='raw_txt_utf16';return value
end
local long_page=Reader.scan_page({cached_full_book='/long.epub'},long_chapters,long_selection,nil,1,long_options)
expect(long_page.kind=='found' and #long_page.reference.chapters==4,'long IDs prevented bundle discovery')
local long_proof=Reader.observe({}, {},long_selection,{long_page.reference},nil,long_options)
expect(long_proof.chapter_count==4 and long_calls==4,'long IDs prevented source verification')
local found_for_search=require('weread.lib.cached_book_search').discover({book=book.bookId,file='/long.epub'},
    long_options.read_archive,long_options.list_metadata)
expect(found_for_search.incomplete and #found_for_search.entries==0,'search navigation limit changed')
if os.getenv('WEREAD_REAL_RUNTIME')=='1' then
    local ffi=require('ffi');require('ffi/posix_h')
    local path=os.tmpname();local fd=ffi.C.open(path,ffi.C.O_WRONLY+ffi.C.O_TRUNC);assert(fd>=0)
    local writer=require('weread.lib.epub_export_writer').new(fd)
    for name,value in pairs(original) do writer:add(name,value,#value,false) end
    assert(writer:close());assert(ffi.C.close(fd)==0)
    local real=assert(M.inspect(selection,path,chapters))
    expect(real.inventory_hash==result.inventory_hash and #real.entries==3,'real archive inventory differed')
    assert(os.remove(path))
    path=os.tmpname();fd=ffi.C.open(path,ffi.C.O_WRONLY+ffi.C.O_TRUNC);assert(fd>=0)
    writer=require('weread.lib.epub_export_writer').new(fd)
    for name,value in pairs(long_members) do writer:add(name,value,#value,false) end
    assert(writer:close());assert(ffi.C.close(fd)==0)
    local real_long=assert(M.inspect(long_selection,path,long_chapters))
    expect(#real_long.entries==4 and real_long.entries[3].chapter_uid=='9007199254740993',
        'real archive lost the precise long chapter ID')
    expect(real_long.inventory_hash==long_proof.inventory_hash,'bulk and individual archive proofs differed')
    local real_page=Reader.scan_page({cached_full_book=path},long_chapters,long_selection,nil,1)
    expect(real_page.kind=='found','real archive with long IDs could not be discovered')
    long_calls=0
    local real_proof=Reader.observe({}, {},long_selection,{real_page.reference},nil,{fetch=long_options.fetch})
    expect(real_proof.chapter_count==4 and long_calls==4,'real archive did not verify every long ID')
    assert(os.remove(path))
    local first_uid=long_chapters[1].chapterUid
    local first_meta=Source.meta_path(first_uid)
    local first_path='OEBPS/text/chapter-001.xhtml'
    local first_raw=Source.raw_path(Crypto.sha256_hex('Synthetic long chapter 1'))
    for _i,change in ipairs({
        function(v) v[Identity.PATH]=v[Identity.PATH]..'x' end,
        function(v) v[first_meta]=v[first_meta]..'x' end,
        function(v) v[Source.path_meta_path(first_path)]='different metadata' end,
        function(v) v[first_raw]='different raw' end,
        function(v) v[first_path]='different rendered chapter' end,
        function(v) v[first_path]=nil end,
    }) do
        local damaged=F.clone(long_members);change(damaged)
        path=os.tmpname();fd=ffi.C.open(path,ffi.C.O_WRONLY+ffi.C.O_TRUNC);assert(fd>=0)
        writer=require('weread.lib.epub_export_writer').new(fd)
        for name,value in pairs(damaged) do writer:add(name,value,#value,false) end
        assert(writer:close());assert(ffi.C.close(fd)==0)
        expect(M.inspect(long_selection,path,long_chapters)==nil,'bulk verification accepted damaged real archive')
        assert(os.remove(path))
    end
    path=os.tmpname();fd=ffi.C.open(path,ffi.C.O_WRONLY+ffi.C.O_TRUNC);assert(fd>=0)
    writer=require('weread.lib.epub_export_writer').new(fd)
    for name,value in pairs(long_members) do writer:add(name,value,#value,false) end
    writer:add(first_raw,long_members[first_raw],#long_members[first_raw],false)
    assert(writer:close());assert(ffi.C.close(fd)==0)
    expect(M.inspect(long_selection,path,long_chapters)==nil,'duplicate source member was accepted')
    assert(os.remove(path))
end
print('readtime_source_bundle_spec: '..n..' checks')
