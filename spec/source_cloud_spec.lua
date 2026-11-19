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
local rate_ok,rate_error=pcall(Cloud.fetch,client,id)
expect(not rate_ok and rate_error=='source_cloud/rate_limited' and #state.requests==1,'429 fanned out or retried')
for _,case in ipairs({{401,'source_cloud/web_expired'},{403,'source_cloud/unavailable'},{500,'source_cloud/unavailable'}}) do
    client,state=fixture();state.code=case[1]
    local accepted,reason=pcall(Cloud.fetch,client,id)
    expect(not accepted and reason==case[2] and #state.requests==1,'HTTP failure was misclassified or repeated')
end
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
local normalized=copy(target);normalized.book_id=tonumber(id);normalized.chapter_uid=tonumber(uid);normalized.raw='private'
local bounded=Cloud.remote(normalized)
expect(bounded.book_id==id and bounded.chapter_uid==uid and bounded.raw==nil,'remote packet did not normalize IDs/drop extra fields')
for _,change in ipairs({{raw_bytes=0},{raw_sha256=string.rep('Z',64)},{chapter_offset=1.5},{upload_verified=true},{percent=101}}) do
    local bad=copy(target);for key,value in pairs(change) do bad[key]=value end
    expect(not Cloud.remote(bad),'malformed transferable target accepted')
end
local standalone=Cloud.bind_file(input.file,target,41,archive)
expect(standalone.position and standalone.identity.file_id==identity.file_id and standalone.file==input.file
    and standalone.request_id==41,'independent cache binding lost archive identity')
expect(not Cloud.bind_file('/bad',target,41,function() error('bad archive') end).position,'corrupt archive escaped cache rejection')
local Content=require('weread.lib.content')
local saved,rows,network_rows={},{{chapterUid=uid,title='Target',wordCount=2500,private='omitted'}},nil
Content.load_catalog_cache=function() return rows end
Content.normalize_chapters=function(response,book_id) return response[book_id] or {} end
client,state=fixture()
client.settings.get_book=function(_self,book_id) assert(book_id==id);return saved end
local selected=Cloud.capture(client.settings)
local downloaded=Cloud.download_chapter(client,target,selected)
expect(downloaded.title=='Target' and downloaded.private==nil and #state.requests==0,'cached target chapter required network or leaked fields')
rows={{chapterUid=uid},{chapterUid=uid}}
client.request=function(_self,options)
    state.requests[#state.requests+1]=options;options.sink('catalog');return 1,state.code,{}
end
client.decode_http_json=function() return network_rows end
network_rows={[id]={{chapterUid=uid,title='Verified live chapter'}}}
downloaded=Cloud.download_chapter(client,target,selected)
expect(downloaded.title=='Verified live chapter' and #state.requests==1,'duplicate cached UID did not require fresh catalog')
local catalog_request=state.requests[1]
expect(catalog_request.url=='https://weread.qq.com/web/book/chapterInfos' and catalog_request.method=='POST'
    and catalog_request.sensitive and catalog_request.persist_response_cookies==false,'catalog escaped captured read-only transport')
rows=nil;network_rows={other={{chapterUid=uid}}}
expect(Cloud.download_chapter(client,target,selected)==nil,'foreign catalog became download target')
state.code=429
expect(not pcall(Cloud.download_chapter,client,target,selected),'catalog rate rejection became target')
state.code=200;state.valid=false;local requests=#state.requests
expect(not pcall(Cloud.download_chapter,client,target,selected) and #state.requests==requests,'stale authorization fetched catalog')
state.valid=true;rows={{chapterUid=uid,title='Target'}}
local attempts={}
local function candidates(file,wanted)
    attempts[#attempts+1]=file
    if file=='/bad' then error('corrupt zip') end
    if file==input.file then return {} end
    local out={};for key in pairs(wanted) do out[key]=members[key] end;return out
end
saved={cached_chapters={[uid]='/bad'},cached_full_book='/full',cached_file='/legacy'}
local resolved=Cloud.resolve(client,input,target,selected,candidates)
expect(resolved.file=='/full' and resolved.remote.chapter_uid==uid,'corrupt target cache prevented full-book fallback')
local saw_legacy=false;for _,file in ipairs(attempts) do if file=='/legacy' then saw_legacy=true end end
expect(not saw_legacy,'cache lookup scanned past first matching candidate')
saved={cached_chapters={[uid]='/single'},cached_full_book='/full'}
resolved=Cloud.resolve(client,input,target,selected,candidates)
expect(resolved.file=='/single','requested chapter cache did not take priority')
saved={cached_chapters={[uid]=input.file},cached_full_book='/bad',cached_file='/bad'};attempts={}
resolved=Cloud.resolve(client,input,target,selected,candidates)
local bad_count=0;for _,file in ipairs(attempts) do if file=='/bad' then bad_count=bad_count+1 end end
expect(not resolved.position and resolved.chapter.chapterUid==uid and resolved.request_id==input.request_id
    and bad_count==1,'missing matching cache did not yield bounded download target/deduplicate paths')
local txt_target={};for key,value in pairs(target) do txt_target[key]=value end
txt_target.basis='raw_txt_utf16'
expect(Cloud.remote(txt_target) and not Cloud.bind(input,txt_target,archive).position,'TXT basis matched an XHTML archive')
local cb_target=copy(target);cb_target.book_id='CB_SyntheticReading'
local cb_before=copy(before);cb_before.book.bookId=cb_target.book_id
local cb_reader=copy(reader);cb_reader.bookInfo.bookId=cb_target.book_id;cb_reader.progress=cb_before
local cb_projected=Cloud.project(cb_target.book_id,cb_before,cb_reader,raw,cb_before)
expect(Cloud.remote(cb_projected) and cb_projected.upload_verified==false and cb_projected.chapter_offset==21,
    'read-only imported XHTML position was not projected')
local nearby_before=copy(cb_before);nearby_before.book.chapterOffset=12
local nearby_reader=copy(cb_reader);nearby_reader.progress=nearby_before
local approximate=Cloud.project(cb_target.book_id,nearby_before,nearby_reader,raw,nearby_before)
expect(approximate.chapter_offset==15 and approximate.upload_verified==false,'imported markup gap did not select nearby text')
local far='<html><body><p data-padding="'..string.rep('a',1030)..'">unique distant source with enough context.</p></body></html>'
expect(not pcall(Cloud.project,cb_target.book_id,nearby_before,nearby_reader,far,nearby_before),
    'imported markup gap escaped maximum distance')
local repeated='<html><body><p>'..string.rep('x',500)..'</p></body></html>'
expect(not pcall(Cloud.project,cb_target.book_id,nearby_before,nearby_reader,repeated,nearby_before),
    'ambiguous nearby text was accepted')
local emoji='<html><body><p>unique before 😀 unique after sufficiently long text</p></body></html>'
local emoji_before=copy(cb_before);emoji_before.book.chapterOffset=30
local emoji_reader=copy(cb_reader);emoji_reader.progress=emoji_before
expect(not pcall(Cloud.project,cb_target.book_id,emoji_before,emoji_reader,emoji,emoji_before),
    'interior UTF-16 surrogate snapped to another source position')
local ambiguous='<html><body><p>'..string.rep('>',20)..'</p><p>abcdefghijklmnop unique trailing context</p></body></html>'
local ambiguity_before=copy(cb_before);ambiguity_before.book.chapterOffset=43
local ambiguity_reader=copy(cb_reader);ambiguity_reader.progress=ambiguity_before
expect(not pcall(Cloud.project,cb_target.book_id,ambiguity_before,ambiguity_reader,ambiguous,ambiguity_before),
    'ambiguous imported coordinate was snapped')
local numeric_gap=copy(before);numeric_gap.book.chapterOffset=12
local numeric_reader=copy(reader);numeric_reader.progress=numeric_gap
expect(not pcall(Cloud.project,id,numeric_gap,numeric_reader,raw,numeric_gap),
    'numeric book inherited imported provisional snapping')
local multi=raw..raw:gsub('Cloud original target','Entirely distinct other passage')
expect(Cloud.project(cb_target.book_id,cb_before,cb_reader,multi,cb_before).upload_verified==false,
    'read-only imported multi-body source was rejected')
local txt_raw='ABCD😀 unique imported raw TXT target with sufficient original context.'
local txt_before=copy(cb_before);txt_before.book.chapterOffset=7
local txt_reader=copy(cb_reader);txt_reader.progress=txt_before
local cb_txt=Cloud.project(cb_target.book_id,txt_before,txt_reader,txt_raw,txt_before,'web_txt')
expect(Cloud.remote(cb_txt) and cb_txt.basis=='raw_txt_utf16' and cb_txt.chapter_offset==7 and not cb_txt.upload_verified,
    'exact imported TXT source target was not projected')
expect(not Cloud.bind(input,cb_txt,archive).position,'imported TXT target matched an XHTML archive')
local txt_interior=copy(txt_before);txt_interior.book.chapterOffset=5
local txt_interior_reader=copy(txt_reader);txt_interior_reader.progress=txt_interior
expect(not pcall(Cloud.project,cb_target.book_id,txt_interior,txt_interior_reader,txt_raw,txt_interior,'web_txt'),
    'imported TXT interior surrogate was snapped')
local other=copy(cb_before);other.book.bookId='CB_Other'
expect(not pcall(Cloud.project,cb_target.book_id,other,cb_reader,raw,other),'foreign imported book was accepted')
expect(not pcall(Cloud.project,id,before,reader,raw..raw,before),
    'local concatenated-body support expanded the default cloud coordinate model')
print(('source_cloud_spec: %d checks'):format(checks))
