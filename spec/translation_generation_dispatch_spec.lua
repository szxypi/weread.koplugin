package.path='./?.lua;./?/init.lua;'..package.path
local helper=require('spec.helpers.annotation_test_store')
local json=require('json')
local Journal=require('weread.lib.translation_generation_journal')
local Hash=require('weread.lib.crypto')
local valid,network=true,0
package.loaded['weread.lib.native_read_access']={matches=function() return valid end}
package.loaded['weread.lib.native_position_protocol']={credentials=function(value) return value and value.vid=='123' end}
local responses={mode={succ=1},ready={stopPoll=1,curStatus={{uid=7,translateVersion=1}}},
    pending={stopPoll=0},rejected={succ=false},wrong={stopPoll=1,curStatus={{uid=8,translateVersion=1}}}}
package.loaded['weread.lib.translation_generation_wire']={MAX_BYTES=8192,decode=function(value) return responses[value] end}
local Dispatch=require('weread.lib.translation_generation_dispatch')
local path=os.tmpname()
local library={settings={auth_scope_matches=function(_self,scope) return valid and scope.vid=='123' end},
    accountKey=function() return 'account' end,open=function() return helper.connect(path) end}
local store=Journal:new(library,{json_encode=function(_self,v) return json.encode(v) end,json_decode=function(_self,v) return json.decode(v) end},{vid='123'})
local selected={scope={vid='123'},credentials={vid='123',accessToken='synthetic'},fingerprint=string.rep('a',64)}
local h=string.rep('a',64)
local function plan(uid)
    return {owner='123',book_id=tostring(456+uid),chapter_uid=uid,book_version=7,translate_version=0,
        grant_sha256=h,catalog_sha256=h,source_sha256=h,baseline_sha256=h}
end
local function witness(p)
    return {kind='source_verified',book_id=p.book_id,chapter_uid=tostring(p.chapter_uid),version=p.book_version,
        translate_version=p.translate_version,catalog_sha256=p.catalog_sha256,source_sha256=p.source_sha256,file_id=h}
end
local answer,code='mode',200
local array_mt={}
local client={json_decode=function(_self,v) assert(v=='[]');return setmetatable({},array_mt) end,
    json_encode=function(_self,value) if getmetatable(value)==array_mt then return '[]' end
        assert(value.freeTrial==0 and #value.read==1 and getmetatable(value.reference.texts)==array_mt)
        return '{"reference":{"texts":[]}}'
    end,
    request=function(_self,opts)
        network=network+1;assert(opts.skip_cookie and not opts.persist_response_cookies and opts.sensitive and opts.timeout[2]==20)
        if opts.method=='GET' then assert(opts.url:match('^https://i%.weread%.qq%.com/trans/pdfepub%?cbid=%d+&transFormat=epubTranslate&transType=epubTranslate$') and not opts.body)
        else assert(opts.url=='https://i.weread.qq.com/en/bookread' and opts.method=='POST' and opts.body:find('"texts":%[%]')) end
        if answer=='error' then error('synthetic') end
        opts.sink(answer);return nil,code
    end}
local function options(p) return {is_current=function() return valid end,recheck=function() return witness(p),h end} end
local p=plan(7);assert(store:prepare(p));local opts=options(p)
local result=Dispatch.send_once(client,library.settings,selected,p,store,'mode',opts)
assert(result.kind=='mode_confirmed' and result.attempted and network==1)
assert(not Dispatch.send_once(client,library.settings,selected,p,store,'mode',opts).attempted and network==1,'mode replayed')
answer='ready';result=Dispatch.send_once(client,library.settings,selected,p,store,'generation',opts)
assert(result.kind=='ready' and result.attempted and network==2 and store:state(p).result=='ready')
assert(not Dispatch.send_once(client,library.settings,selected,p,store,'generation',opts).attempted and network==2,'generation replayed')
local second=plan(8);assert(store:prepare(second));answer='error'
result=Dispatch.send_once(client,library.settings,selected,second,store,'mode',options(second))
assert(result.kind=='unconfirmed' and result.attempted and store:state(second).phase=='mode_claimed')
assert(not Dispatch.send_once(client,library.settings,selected,second,store,'mode',options(second)).attempted,'lost response retried')
local third=plan(9);assert(store:prepare(third));local changed=options(third)
changed.recheck=function() local value=witness(third);value.source_sha256=Hash.sha256_hex('changed');return value,h end
local before=network;assert(not Dispatch.send_once(client,library.settings,selected,third,store,'mode',changed).attempted
    and network==before and store:state(third).phase=='prepared','stale source dispatched or consumed claim')
changed=options(third);changed.recheck=function() return witness(third),Hash.sha256_hex('changed') end
assert(not Dispatch.send_once(client,library.settings,selected,third,store,'mode',changed).attempted and network==before,'changed baseline dispatched')
answer='mode';code=401;result=Dispatch.send_once(client,library.settings,selected,third,store,'mode',options(third))
assert(result.attempted and result.kind=='unconfirmed' and store:state(third).phase=='mode_claimed','HTTP error acknowledged')
local fourth=plan(10);assert(store:prepare(fourth));code=200;answer=string.rep('x',8193)
result=Dispatch.send_once(client,library.settings,selected,fourth,store,'mode',options(fourth))
assert(result.attempted and result.kind=='unconfirmed' and store:state(fourth).phase=='mode_claimed','oversized reply acknowledged')
local fifth=plan(11);assert(store:prepare(fifth));answer='rejected'
result=Dispatch.send_once(client,library.settings,selected,fifth,store,'mode',options(fifth))
assert(result.attempted and result.kind=='unconfirmed' and not Dispatch.send_once(client,library.settings,selected,fifth,store,'generation',options(fifth)).attempted,
    'rejected mode allowed generation')
local sixth=plan(12);assert(store:prepare(sixth));valid=false;before=network
assert(not Dispatch.send_once(client,library.settings,selected,sixth,store,'mode',options(sixth)).attempted and network==before,'stale account dispatched')
valid=true
local seventh=plan(13);assert(store:prepare(seventh));answer='mode';code=200
assert(Dispatch.send_once(client,library.settings,selected,seventh,store,'mode',options(seventh)).kind=='mode_confirmed')
answer='wrong';result=Dispatch.send_once(client,library.settings,selected,seventh,store,'generation',options(seventh))
assert(result.attempted and result.kind=='unconfirmed' and store:state(seventh).phase=='generation_claimed',
    'wrong chapter generation result was accepted')
assert(not Dispatch.send_once(client,library.settings,selected,seventh,store,'generation',options(seventh)).attempted,
    'wrong chapter response was retried')
local selected_other={scope={vid='123'},credentials=selected.credentials,fingerprint=Hash.sha256_hex('other')}
assert(not Dispatch.send_once(client,library.settings,selected_other,sixth,store,'mode',options(sixth)).attempted,'different grant dispatched')
for _,suffix in ipairs({'','-wal','-shm'}) do os.remove(path..suffix) end
print('PASS: one-shot translation dispatch, scope, fresh evidence, and failure handling')
