package.path='./?.lua;'..package.path
local Cloud=require('weread.lib.source_cloud');local Source=require('weread.lib.position_source')
local Crypto=require('weread.lib.crypto');local Identity=require('weread.lib.book_file_identity')
local F=require('spec.helpers.thought_edit_fixture')
local checks=0;local function expect(v,why) checks=checks+1;assert(v,why) end
local raw='Literal <tag>&amp; raw TXT source. A unique 中文😀 sentence.\r\nNext line.'
local id,uid='900001','2';local point={bookId=id,chapterUid=uid,chapterOffset=0,progress=32}
local before={book=point};local reader={bookInfo={bookId=id},currentChapter={chapterUid=uid},progress=before,psvts='synthetic-context'}
local target=Cloud.project(id,before,reader,raw,before,'web_txt')
expect(target.basis=='raw_txt_utf16' and target.chapter_offset==0 and target.raw_sha256==Crypto.sha256_hex(raw))
expect(not pcall(Cloud.project,id,before,reader,raw,before,'unknown'),'unknown source format accepted')
local book,chapter={book_id=id,bookVersion=7},{chapterUid=uid};local path='OEBPS/text/chapter.xhtml'
local capture=assert(Source.capture(book,chapter,raw,'web_txt'))
local root=Identity.encode(book,{chapter},Identity.capture(book),Crypto.sha256_hex(raw));local identity=Identity.decode(root)
local rendered='<html><body><p>Literal &lt;tag&gt;&amp;amp; raw TXT source.</p></body></html>'
local meta=assert(Source.bind(capture,identity,path,Crypto.sha256_hex(rendered)))
local members={[Identity.PATH]=root,[Source.meta_path(uid)]=meta,[Source.path_meta_path(path)]=meta,
    [Source.raw_path(Crypto.sha256_hex(raw))]=raw,[path]=rendered}
local input={file='synthetic.epub',book_id=id,identity=identity,request_id=4}
local function archive(_file,wanted)
    local out={};for key in pairs(wanted) do out[key]=assert(members[key]) end;return out
end
local bound=Cloud.bind(input,target,archive)
expect(bound.position and bound.position.basis=='raw_txt_utf16' and bound.remote.raw_sha256==target.raw_sha256,'raw source archive did not bind')
local wrong=F.clone(target);wrong.basis='filtered_xhtml_utf16';expect(not Cloud.bind(input,wrong,archive).position,'cross-format source binding')
package.preload['weread.lib.content']=function() return {decode_content_shards=function(a,b,c)
    assert(a=='txt0' and b=='txt1' and c=='');return raw
end} end
local function fixture()
    local state={requests={},valid=true}
    local settings={get_auth_scope=function() return {vid='900000',epoch=1} end,auth_scope_matches=function() return state.valid end,
        get=function(_self,key,default) return key=='cookies' and {wr_vid='900000',wr_skey='synthetic-cloud-cookie'} or default end}
    local values={progress=before,['{reader}']={reader=reader},['{marker}']={bookId=id,chapterUid=uid}}
    local client={settings=settings,json_encode=function() return 'read-only-body' end,json_decode=function(_self,s) return assert(values[s]) end,
        decode_http_json=function(_self,s) return assert(values[s]) end}
    function client:request(options)
        state.requests[#state.requests+1]=options;local n=#state.requests
        expect(options.sensitive and options.skip_cookie and options.persist_response_cookies==false,'source read shared session state')
        local text=n==1 and 'progress' or n==2 and '<script>window.__INITIAL_STATE__={reader};(function(){})();</script>'
            or n==3 and '{marker}' or n==4 and 'txt0' or n==5 and 'txt1' or 'progress'
        if state.foreign and n==3 then values['{marker}'].bookId='900099' end
        if state.move and n==4 then state.valid=false end
        options.sink(text);return 1,200,{}
    end
    return client,state
end
local client,state=fixture();local fetched=Cloud.fetch(client,id)
expect(fetched.basis=='raw_txt_utf16' and fetched.raw_sha256==target.raw_sha256 and #state.requests==6)
expect(state.requests[3].url:find('/e_0',1,true) and state.requests[4].url:find('/t_0',1,true)
    and state.requests[5].url:find('/t_1',1,true),'TXT selected filtered XHTML shards')
for _i,options in ipairs(state.requests) do expect(not options.url:find('/book/read',1,true),'read-only target wrote progress') end
client,state=fixture();state.foreign=true;expect(not pcall(Cloud.fetch,client,id) and #state.requests==3,'foreign TXT marker fetched raw source')
client,state=fixture();state.move=true;expect(not pcall(Cloud.fetch,client,id) and #state.requests==4,'changed authorization continued shards')
print('source_cloud_txt_spec: '..checks..' checks')
