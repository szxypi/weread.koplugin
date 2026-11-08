package.path='./?.lua;'..package.path
local Worker=require('weread.lib.source_position_worker')
local Source=require('weread.lib.position_source')
local Identity=require('weread.lib.book_file_identity')
local Crypto=require('weread.lib.crypto')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message or ('check '..checks)) end
local book,chapter={book_id='synthetic',bookVersion=7},{chapterUid=11}
local raw='<html><body><p>ABCDE😀&amp;中文FGHIJKLMNOPQRST</p></body></html>'
local rendered='<html><head><title>Original &amp; title</title></head><body>local rendered text</body></html>'
local path='OEBPS/text/chapter.xhtml'
local source=assert(Source.capture(book,chapter,raw,'web_xhtml'))
local root=Identity.encode(book,{chapter},Identity.capture(book),Crypto.sha256_hex(rendered))
local identity=assert(Identity.decode(root))
local metadata=assert(Source.bind(source,identity,path,Crypto.sha256_hex(rendered)))
local input={file='/test/book.epub',book_id='synthetic',chapter_uid='11',render_path=path,metadata=metadata,
    identity=identity,text='ABCDE😀&中文FGHIJKLMNOPQRST',point_offset=12,request_id=9}
local members={[Identity.PATH]=root,[Source.path_meta_path(path)]=metadata,[Source.raw_path(source.raw_sha256)]=raw,[path]=rendered}
local function read(file,wanted)
    expect(file==input.file,'worker changed source pathname')
    local count=0
    for key,limit in pairs(wanted) do
        count=count+1;expect(members[key] and #members[key]<=limit,'unbounded/unexpected archive member')
    end
    expect(count==4,'worker read more than four source resources')
    return members
end
local result=Worker.capture(input,read)
expect(result.position and result.position.chapter_offset==32,'UTF16/entity scalar point changed')
expect(result.position.chapter_title=='Original & title','chapter label was not taken from the verified rendered member')
expect(result.request_id==9 and result.position.upload_verified==false,'worker activated writes or lost request ownership')
expect(result.position.file_id==identity.file_id and result.position.raw_sha256==source.raw_sha256,'file provenance lost')
expect(not result.position.text and not result.position.raw and not result.position.metadata,'body returned through result pipe')
local function copy(value)
    local out={};for k,v in pairs(value) do out[k]=v end;return out
end
for _,change in ipairs({{text='not present in original text'},{point_offset=1000},{point_offset=-1},{point_offset=0.5},
    {point_offset='12'},{text='AB CD'},{book_id='other'},{chapter_uid='22'},{render_path='other.xhtml'},
    {metadata=metadata..'bad'},{text='\237\160\128'}}) do
    local frame=copy(input)
    for key,value in pairs(change) do frame[key]=value end
    expect(not Worker.capture(frame,function() return members end).position,'invalid context accepted')
end
local function corrupt(key,value)
    local changed=copy(members);changed[key]=value
    local outcome=Worker.capture(input,function() return changed end)
    expect(not outcome.position and outcome.error=='source_changed','changed archive accepted')
end
corrupt(Source.raw_path(source.raw_sha256),raw..'changed')
corrupt(path,rendered..'changed')
corrupt(Source.path_meta_path(path),metadata..'changed')
corrupt(Identity.PATH,root:gsub('book_version=7','book_version=8'))
local failed=Worker.capture(input,function() error('private archive diagnostic') end)
expect(failed.error=='position_unavailable','archive diagnostic escaped worker')
expect(not Worker.capture(input,function() return nil end).position,'missing archive accepted')
-- Repeated text must not silently choose its first occurrence.
local repeated_raw='<html><body><p>'..input.text..'</p><p>'..input.text..'</p></body></html>'
local repeated_source=assert(Source.capture(book,chapter,repeated_raw,'web_xhtml'))
local repeated_meta=assert(Source.bind(repeated_source,identity,path,Crypto.sha256_hex(rendered)))
local repeated_input=copy(input);repeated_input.metadata=repeated_meta
local repeated_members={[Identity.PATH]=root,[Source.path_meta_path(path)]=repeated_meta,
    [Source.raw_path(repeated_source.raw_sha256)]=repeated_raw,[path]=rendered}
expect(Worker.capture(repeated_input,function() return repeated_members end).error=='context_unmatched','repeated source was guessed')
local txt=assert(Source.capture(book,chapter,'original TXT bytes','web_txt'))
local txt_input=copy(input)
txt_input.metadata=assert(Source.bind(txt,identity,path,Crypto.sha256_hex(rendered)))
expect(Worker.capture(txt_input,function() error('TXT must not be parsed as XHTML') end).error=='source_unsupported',
    'TXT failure suggested re-downloading rather than unsupported mapping')
local jump_input=copy(input);jump_input.target=copy(result.position)
local prepared=Worker.prepare_target(jump_input,read)
expect(prepared.position.chapter_offset==32 and prepared.request_id==9,'target preparation changed position or request')
expect(prepared.anchor.co==32 and prepared.anchor.point_unit=='unicode_scalars' and #prepared.anchor.text<=8192,
    'prepared anchor lost exact scalar point or exceeded memory-pipe bound')
expect(not prepared.raw and not prepared.metadata and not prepared.position.text and not prepared.anchor.raw,
    'target result included more than one bounded quote')
for _,change in ipairs({{book_id='other'},{chapter_uid='22'},{file_id=string.rep('a',64)},
    {book_version=8},{raw_sha256=string.rep('b',64)},{render_path='other.xhtml'},
    {basis='catalog_words'},{upload_verified=true},{chapter_offset=21},{chapter_offset=0/0}}) do
    local target_input=copy(jump_input);target_input.target=copy(jump_input.target)
    for key,value in pairs(change) do target_input.target[key]=value end
    expect(not Worker.prepare_target(target_input,function() return members end).position,'invalid/foreign source target was prepared')
end
expect(Worker.prepare_target(jump_input,function() error('private archive diagnostic') end).error=='position_unavailable',
    'private target-preparation diagnostic escaped worker')
print(('source_position_worker_spec: %d checks'):format(checks))
