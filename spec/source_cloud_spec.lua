package.path='./?.lua;'..package.path
local Cloud=require('weread.lib.source_cloud')
local Crypto=require('weread.lib.crypto')
local Source=require('weread.lib.position_source')
local Identity=require('weread.lib.book_file_identity')
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local function copy(value)
    if type(value)~='table' then return value end
    local out={};for key,item in pairs(value) do out[key]=copy(item) end;return out
end
local id,uid='900001','2'
local raw='<html><body><p>Cloud original target: unique ASCII and 中文😀 content.</p></body></html>'
local point={bookId=id,chapterUid=uid,chapterOffset=21,progress=32}
local before={book=point}
local reader={bookInfo={bookId=id},currentChapter={chapterUid=uid},progress=before,psvts='synthetic-context'}
local target=Cloud.project(id,before,reader,raw,before)
expect(target.chapter_offset==21 and target.raw_sha256==Crypto.sha256_hex(raw) and target.raw_bytes==#raw
    and target.upload_verified==false,'cloud projection lost exact source binding')
expect(not target.raw and not target.token and target.basis=='filtered_xhtml_utf16','private reader state escaped projection')
for _,change in ipairs({{bookId='other'},{chapterUid=0},{chapterOffset=0/0},{chapterOffset=1.5},
    {progress=101},{progress='32'},{chapterOffset=0}}) do
    local bad=copy(point);for key,value in pairs(change) do bad[key]=value end
    local page=copy(reader);page.progress={book=bad}
    expect(not pcall(Cloud.project,id,{book=bad},page,raw,{book=bad}),'invalid cloud position accepted')
end
local whitespace=copy(point);whitespace.chapterOffset=20
local whitespace_reader=copy(reader);whitespace_reader.progress={book=whitespace}
expect(not pcall(Cloud.project,id,{book=whitespace},whitespace_reader,raw,{book=whitespace}),'whitespace offset snapped to next visible character')
local changed=copy(before);changed.book.chapterOffset=22
expect(not pcall(Cloud.project,id,before,reader,raw,changed),'cloud movement during read accepted')
for _,field in ipairs({'bookInfo','currentChapter','progress'}) do
    local page=copy(reader);page[field]={}
    expect(not pcall(Cloud.project,id,before,page,raw,before),'wrong reader scope accepted')
end
expect(not pcall(Cloud.project,id,{errcode=-1,book=point},reader,raw,before),'API rejection became a target')
expect(not pcall(Cloud.project,id,before,reader,string.rep('x',Source.MAX_BYTES+1),before),'oversized source accepted')

package.preload['weread.lib.content']=function() return {decode_content_shards=function(a,b,c)
    assert(a=='part0' and b=='part1' and c=='part3');return raw
end} end
local function fixture()
    local state={valid=true,requests={},code=200,move=false,bad_reader=false,oversized=false}
    local scope={vid='900000',epoch=1}
    local settings={get_auth_scope=function() return scope end,auth_scope_matches=function() return state.valid end,
        get=function(_self,key,default) return key=='cookies' and {wr_vid='900000',wr_skey='synthetic-cloud-cookie'} or default end}
    local values={before=before,after=before,['{reader}']={reader=reader}}
    local client={settings=settings,json_encode=function() return 'signed-read-body' end,
        json_decode=function(_self,text) return assert(values[text]) end,
        decode_http_json=function(_self,text) return assert(values[text]) end}
    function client:request(options)
        state.requests[#state.requests+1]=options
        local count=#state.requests
        local text=count==1 and 'before' or count==2 and '<script>window.__INITIAL_STATE__={reader};(function(){})();</script>'
            or count==3 and 'part0' or count==4 and 'part1' or count==5 and 'part3' or 'after'
        if state.bad_reader and count==2 then values['{reader}']={reader={bookInfo={bookId='900002'},psvts='synthetic-context'}} end
        if state.oversized then text=string.rep('x',65537) end
        options.sink(text);options.sink(nil)
        if state.move and count==3 then state.valid=false end
        return 1,state.code,{}
    end
    return client,state
end
local client,state=fixture()
local fetched=Cloud.fetch(client,id)
expect(fetched.raw_sha256==target.raw_sha256 and #state.requests==6,'six fixed reads did not produce same target')
for index,options in ipairs(state.requests) do
    expect(options.sensitive and options.skip_cookie and options.persist_response_cookies==false
        and options.headers.Cookie:find('synthetic-cloud-cookie',1,true) and not options.headers.Authorization,'read leaked or persisted credentials')
    expect(options.method==(index>=3 and index<=5 and 'POST' or 'GET'),'unexpected HTTP method')
end
expect(state.requests[1].url==state.requests[6].url and not state.requests[1].body,'progress snapshots used different endpoints')
client,state=fixture();state.code=429
expect(not pcall(Cloud.fetch,client,id) and #state.requests==1,'429 fanned out or retried')
client,state=fixture();state.move=true
expect(not pcall(Cloud.fetch,client,id) and #state.requests==3,'changed credentials continued source reads')
client,state=fixture();state.bad_reader=true
expect(not pcall(Cloud.fetch,client,id) and #state.requests==2,'foreign reader context fetched shards')
client,state=fixture();state.oversized=true
expect(not pcall(Cloud.fetch,client,id) and #state.requests==1,'oversized progress continued requests')

local book,chapter={book_id=id,bookVersion=7},{chapterUid=uid}
local path='OEBPS/text/chapter.xhtml'
local capture=assert(Source.capture(book,chapter,raw,'web_xhtml'))
local root=Identity.encode(book,{chapter},Identity.capture(book),Crypto.sha256_hex(raw))
local identity=assert(Identity.decode(root))
local metadata=assert(Source.bind(capture,identity,path,Crypto.sha256_hex(raw)))
local members={[Identity.PATH]=root,[Source.meta_path(uid)]=metadata,[Source.path_meta_path(path)]=metadata,
    [Source.raw_path(Crypto.sha256_hex(raw))]=raw,[path]=raw}
local input={file='/synthetic.epub',identity=identity,book_id=id,request_id=19}
local reads=0
local function archive(file,wanted)
    assert(file==input.file);reads=reads+1
    local out={};for key,limit in pairs(wanted) do assert(members[key] and #members[key]<=limit);out[key]=members[key] end
    return out
end
local bound=Cloud.bind(input,target,archive)
expect(bound.position and bound.position.file_id==identity.file_id and bound.position.chapter_offset==21
    and bound.metadata==metadata and bound.request_id==19 and reads==2,'matching EPUB source did not bind')
expect(not bound.raw and not bound.anchor and not bound.position.percent and not bound.position.upload_verified,'bound packet exported body or upload rights')
for _,change in ipairs({{raw_sha256=string.rep('a',64)},{raw_bytes=#raw+1},{book_id='900002'},
    {chapter_offset=0},{upload_verified=true}}) do
    local bad=copy(target);for key,value in pairs(change) do bad[key]=value end
    expect(not Cloud.bind(input,bad,archive).position,'wrong EPUB source or target accepted')
end
local swapped=copy(input);swapped.identity.file_id=string.rep('b',64)
expect(not Cloud.bind(swapped,target,archive).position,'same-path replacement retained cloud target')
print(('source_cloud_spec: %d checks'):format(checks))
