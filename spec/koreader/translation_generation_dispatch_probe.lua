-- Real KOReader JSON and SQLite, synthetic account and transport, no network.
require('setupkoenv')
G_reader_settings=require('luasettings'):wrap({})
G_defaults=require('luadefaults'):open()
package.path=assert(arg[1])..'/?.lua;'..package.path
local root=assert(os.getenv('WEREAD_TEST_DIR'))
local Wire=require('weread.lib.translation_generation_wire')
assert(Wire.decode('{"succ":1}'))
for _,raw in ipairs({'{"succ":1,"succ":1}',[[{"succ":1,"\u0073ucc":1}]],'{"succ":null,"succ":1}','{"succ":1,}',
    '{"data":{"a":1,"a":2}}','{"succ":true} trailing','[]',string.rep('[',33)..string.rep(']',33)}) do
    assert(not Wire.decode(raw),'invalid receipt accepted')
end
local credentials={vid='123',accessToken='synthetic-access',refreshToken='synthetic-refresh',
    deviceId='eink3346912251234567890123456789'}
local valid=true
local scope={vid='123',epoch=1}
local settings={data_dir=root,get=function(_self,key,default)
    if key=='account' then return {user_vid='123'} end
    return default
end,get_auth_scope=function() return scope end,auth_scope_matches=function(_self,value) return valid and value==scope end}
local native_store={read=function() return credentials,1,nil,false end}
local selected=assert(require('weread.lib.native_read_access').capture(settings,native_store))
local client=require('weread.lib.client'):new(settings)
local library=require('weread.lib.library_db'):new(settings)
local journal=require('weread.lib.translation_generation_journal'):new(library,client,scope)
local Dispatch=require('weread.lib.translation_generation_dispatch')
local h=string.rep('b',64)
local function plan(uid)
    return {owner='123',book_id=tostring(900000+uid),chapter_uid=uid,book_version=7,translate_version=0,
        grant_sha256=selected.fingerprint,catalog_sha256=h,source_sha256=h,baseline_sha256=h}
end
local function options(p)
    return {is_current=function() return valid end,recheck=function()
        return {kind='source_verified',book_id=p.book_id,chapter_uid=tostring(p.chapter_uid),version=7,translate_version=0,
            catalog_sha256=h,source_sha256=h,file_id=h},h
    end}
end
local requests,answer=0,'{"succ":1}'
client.request=function(self,request)
    requests=requests+1;assert(request.sensitive and request.skip_cookie and not request.persist_response_cookies)
    if request.method=='POST' then
        local body=self:json_decode(request.body)
        assert(request.url=='https://i.weread.qq.com/en/bookread' and body.freeTrial==0 and #body.read==1
            and body.read[1].uid==7 and body.reference.uid==7 and self:json_encode(body.reference.texts)=='[]')
    else assert(request.method=='GET' and not request.body) end
    assert(request.sink(answer));return nil,200
end
local p=plan(7);assert(journal:prepare(p))
local state=Dispatch.send_once(client,settings,selected,p,journal,'mode',options(p))
assert(state.kind=='mode_confirmed' and state.attempted)
answer='{"stopPoll":1,"curStatus":[{"uid":7,"translateVersion":1}]}'
state=Dispatch.send_once(client,settings,selected,p,journal,'generation',options(p))
assert(state.kind=='ready' and requests==2 and journal:state(p).result=='ready')
assert(not Dispatch.send_once(client,settings,selected,p,journal,'generation',options(p)).attempted and requests==2)
local second=plan(8);assert(journal:prepare(second));answer='{"succ":1,"succ":1}'
state=Dispatch.send_once(client,settings,selected,second,journal,'mode',options(second))
assert(state.kind=='unconfirmed' and state.attempted and journal:state(second).phase=='mode_claimed')
assert(not Dispatch.send_once(client,settings,selected,second,journal,'mode',options(second)).attempted)
local third=plan(9);assert(journal:prepare(third));answer='{"succ":1}'
local claim=journal.claim_mode
journal.claim_mode=function(self,value) local record=claim(self,value);valid=false;return record end
local before=requests
state=Dispatch.send_once(client,settings,selected,third,journal,'mode',options(third))
assert(not state.attempted and requests==before,'session change dispatched')
valid=true;journal.claim_mode=claim
assert(journal:state(third).phase=='mode_claimed' and not Dispatch.send_once(client,settings,selected,third,journal,'mode',options(third)).attempted,
    'committed claim was replayed after session change')
print('PASS: KOReader strict JSON, SQLite durability, request and no-replay flow')
