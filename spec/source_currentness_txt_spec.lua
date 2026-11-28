package.path='./?.lua;'..package.path
local C=require('weread.lib.source_currentness')
local Crypto=require('weread.lib.crypto')
local Content=require('weread.lib.content')
local checks=0
local function expect(v,why) checks=checks+1;assert(v,why or ('check '..checks)) end
local raw='\239\187\191Literal <tag>&amp;😀\r\n　 original source'
local expected={book_id='900001',chapter_uid='11',chapter_idx=0,raw_sha256=Crypto.sha256_hex(raw),raw_bytes=#raw}
local cookies={wr_vid='900000',wr_skey='synthetic-cookie-value'}
local scope={vid='900000',epoch=1}
local settings={get_auth_scope=function() return scope end,auth_scope_matches=function(_self,v) return v==scope end,
    get=function(_self,key,default) return key=='cookies' and cookies or default end}
local catalog={{bookId='900001',book={format='txt'},updated={{chapterUid=11,chapterIdx=0}}}}
local state={reader={bookInfo={bookId='900001'},currentChapter={chapterUid=11},psvts='synthetic-reader-session'}}
local marker={bookId='900001',chapterUid=11}
local requests,fail_route,fail_code={},nil,nil
local decoded={ACCOUNT={vid='900000'},CATALOG=catalog,MARKER=marker,['{"reader":{}}']=state}
local client={settings=settings,json_encode=function() return 'ENCODED' end,
    json_decode=function(_self,text) return assert(decoded[text]) end,
    decode_http_json=function(_self,text) return assert(decoded[text]) end}
function client:request(options)
    requests[#requests+1]=options.url
    expect(options.skip_cookie==true and options.persist_response_cookies==false and options.sensitive==true)
    expect(options.diagnostic_api=='source_currentness' and not options.headers.Authorization)
    if fail_route and options.url:find(fail_route,1,true) then return nil,fail_code end
    local body=options.url:find('/api/userInfo',1,true) and 'ACCOUNT'
        or options.url:find('/chapterInfos',1,true) and 'CATALOG'
        or options.url:find('/chapter/e_0',1,true) and 'MARKER'
        or options.url:find('/chapter/t_0',1,true) and 'T0'
        or options.url:find('/chapter/t_1',1,true) and 'T1'
        or 'window.__INITIAL_STATE__={"reader":{}};(function(){})();'
    options.sink(body);options.sink(nil);return nil,200,{}
end
local decoder=Content.decode_content_shards
Content.decode_content_shards=function(a,b,c) expect(a=='T0' and b=='T1' and c=='');return raw end
local result=C.run_txt(client,expected,C.capture(settings))
expect(C.packet_txt(result.check,expected) and result.check.basis=='raw_txt_utf16','TXT source was not checked')
expect(not C.packet(result.check,expected),'TXT proof accepted as XHTML')
expect(#requests==8,'TXT source check changed bounded read count')
for _i,url in ipairs(requests) do expect(not url:find('/book/read',1,true) and not url:find('/login/',1,true),'unexpected mutation/auth endpoint') end
for _i,value in ipairs({{bookId='900002'},{bookId='900001',chapterUid=22},{bookId='900001',errcode=false},
    {bookId='900001',succ=0},{bookId='900001',errCode=-1}}) do
    decoded.MARKER=value;requests={}
    expect(not C.run_txt(client,expected,C.capture(settings)).check,'foreign/failed marker accepted')
    expect(#requests==4,'bad marker reached TXT shard')
end
decoded.MARKER=marker
local loaded_json=package.loaded.json;local null={};package.loaded.json={null=null}
decoded.MARKER={bookId='900001',chapterUid=null}
expect(C.txt_marker(client,'MARKER','900001','11'),'optional null chapter marker rejected')
decoded.MARKER={bookId='900001',succ=null}
expect(not pcall(C.txt_marker,client,'MARKER','900001','11'),'null success marker accepted')
package.loaded.json=loaded_json;decoded.MARKER=marker
state.reader.currentChapter.chapterUid=22;requests={}
expect(not C.run_txt(client,expected,C.capture(settings)).check and #requests==3,'foreign reader chapter reached TXT')
state.reader.currentChapter.chapterUid=11
for _i,route in ipairs({'/api/userInfo','/chapterInfos','/chapter/e_0','/chapter/t_0','/chapter/t_1'}) do
    fail_route,fail_code=route,401;requests={}
    expect(C.run_txt(client,expected,C.capture(settings)).error=='source_web_expired','actual 401 was not classified')
    fail_code=500;expect(C.run_txt(client,expected,C.capture(settings)).error=='source_currentness_unavailable','non401 allowed renewal')
end
fail_route=nil;raw=raw..'changed'
expect(not C.run_txt(client,expected,C.capture(settings)).check,'changed raw TXT was accepted')
Content.decode_content_shards=decoder
print(('source_currentness_txt_spec: %d checks'):format(checks))
