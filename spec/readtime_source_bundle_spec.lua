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
local chapters={{chapterUid=7,chapterIdx=0},{chapterUid=8,chapterIdx=4},{chapterUid=9,chapterIdx=8}}
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
for _i,mode in ipairs({'changed_source','changed_catalog','missing_check','changed_archive'}) do
    state,remote=remote_fixture();state[mode]=true
    expect(not pcall(M.verify,{}, {},selection,'/synthetic.epub',chapters,nil,remote),'changed remote bundle accepted')
end
for _i,change in ipairs({
    function(c) c[1].book.version=0 end,
    function(c) table.remove(c[1].updated) end,
    function(c) c[1].updated[4]={chapterUid=10,chapterIdx=9} end,
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
-- The UI switches to background paging above 126 chapters. Its returned
-- reference must still carry the complete scope into the transfer worker.
local large_chapters={}
for i=1,127 do large_chapters[i]={chapterUid=i+100,chapterIdx=i-1} end
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
if os.getenv('WEREAD_REAL_RUNTIME')=='1' then
    local ffi=require('ffi');require('ffi/posix_h')
    local path=os.tmpname();local fd=ffi.C.open(path,ffi.C.O_WRONLY+ffi.C.O_TRUNC);assert(fd>=0)
    local writer=require('weread.lib.epub_export_writer').new(fd)
    for name,value in pairs(original) do writer:add(name,value,#value,false) end
    assert(writer:close());assert(ffi.C.close(fd)==0)
    local real=assert(M.inspect(selection,path,chapters))
    expect(real.inventory_hash==result.inventory_hash and #real.entries==3,'real archive inventory differed')
    assert(os.remove(path))
end
print('readtime_source_bundle_spec: '..n..' checks')
