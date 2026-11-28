package.path='./?.lua;'..package.path
local Guard=dofile('spec/koreader/note_download_transport.lua')
local Protocol=require('weread.lib.protocol')
local F=require('spec.helpers.thought_edit_fixture');local client=F.codec()
local ffi=require('ffi');pcall(ffi.cdef,'int getpid(void);')
local counters=setmetatable({},{__index=function() return 0 end})
local cookies={wr_vid='900000',wr_skey='synthetic-note-cookie'}
client.settings={get=function() return cookies end}
local gate=Guard:new({book_id='900001',owner='900000',chapters={{chapter_uid='7'}}},'live',counters,0)
local checks=0;local function expect(v,label) checks=checks+1;assert(v,label) end
local valid={method='GET',url=Protocol.reader_url('900001','7'),headers={}}
expect(not gate:classify(client,valid),'unconfirmed window allowed network')
counters[5]=1;expect(gate:classify(client,valid)==1,'fixed same-chapter reader GET refused')
local function copy(value) local result={};for k,v in pairs(value) do result[k]=v end;return result end
for _i,headers in ipairs({{Cookie='wrong'},{cookie='wrong'},{Authorization='synthetic'},{authorization='synthetic'},{AccessToken='synthetic'},{accessToken='synthetic'},{VID='900000'}}) do
    local request=copy(valid);request.headers=headers;expect(not gate:classify(client,request),'foreign credential header allowed')
end
for _i,url in ipairs({Protocol.reader_url('900002','7'),Protocol.reader_url('900001','8'),valid.url..'?extra=1',
    'https://weread.qq.com/web/book/read','https://weread.qq.com/web/login/renewal','https://i.weread.qq.com/review/delete',
    'https://res.weread.qq.com/asset'}) do
    local request=copy(valid);request.url=url;expect(not gate:classify(client,request),'non-source URL allowed')
end
local catalog={method='POST',url='https://weread.qq.com/web/book/chapterInfos',headers={},body=client:json_encode({bookIds={'900001'}})}
expect(gate:classify(client,catalog)==2,'same-book catalog refused')
catalog.body=client:json_encode({bookIds={'900002'}});expect(not gate:classify(client,catalog),'foreign catalog allowed')
local body=Protocol.make_content_params('900001','7','synthetic-probe-only',{sc=1})
local shard={method='POST',url='https://weread.qq.com/web/book/chapter/e_0',headers={Referer=valid.url},body=client:json_encode(body)}
expect(gate:classify(client,shard)==3,'same-book source shard refused')
for _i,change in ipairs({{b=Protocol.e('900002')},{c=Protocol.e('8')},{extra=true},{sc=2},{prevChapter=true},{st=1}}) do
    local altered=copy(body);for k,v in pairs(change) do altered[k]=v end
    shard.body=client:json_encode(altered);expect(not gate:classify(client,shard),'foreign/unknown source body allowed')
end
gate.mode='reopen';expect(not gate:classify(client,valid),'offline reopen allowed network');gate.mode='live'
local calls=0;client.request=function() calls=calls+1;return 'synthetic',200 end
gate:install(client);client:request(valid)
expect(calls==1 and counters[0]==1 and counters[1]==1 and valid.sensitive==true,'allowed read not private/countable')
for _i=1,3 do client:request(valid) end
expect(not pcall(client.request,client,valid) and calls==4 and counters[4]==1,'per-route budget exceeded')
local current=setmetatable({[5]=1},{__index=function() return 0 end})
local parent=Guard:new(gate.input,'live',current,tonumber(ffi.C.getpid()));local C={request=function() error('must not reach transport') end}
parent:install(C);C.settings=client.settings;C.json_decode=client.json_decode
expect(not pcall(C.request,C,valid) and current[4]==1 and current[0]==0,'UI process performed a source read')
print('PASS: bounded note-download source-only transport ('..checks..' checks)')
