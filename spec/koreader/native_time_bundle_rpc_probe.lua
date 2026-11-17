-- Synthetic-only native selection/signing/RPC; network is unavailable.
require('ffi').log=function() end
require('setupkoenv')
local json=require('json')
local function deny() error('synthetic_rpc/network_disabled') end
package.loaded['socket.http']={request=deny};package.loaded['ssl.https']={request=deny}
local length=assert(io.stdin:read('*l'))
assert(length:match('^[1-9]%d*$') and tonumber(length)<=65536)
local input=json.decode(assert(io.stdin:read(tonumber(length))))
assert(input.owner=='900000' and input.book_id=='900001' and input.grant.vid=='900000'
    and input.grant.accessToken=='mock-native-access' and input.grant.refreshToken=='mock-native-refresh'
    and input.guest=='synthetic-guest' and input.config=='synthetic-config')
assert(input.mode=='success' or input.mode=='tamper' or input.mode=='drop' or input.mode=='duplicate')
assert(type(input.token)=='string' and #input.token==32 and input.token:match('^[a-f0-9]+$'))
assert(type(arg[1])=='string');package.path=arg[1]..'/?.lua;'..package.path
local function rpc(kind,extra)
    local value=extra or {};value.kind=kind
    io.stdout:write('\nWEREAD_NATIVE_THOUGHT_'..input.token..'_STEP='..json.encode(value)..'\n');io.stdout:flush()
    local reply=json.decode(assert(io.stdin:read('*l')))
    assert(reply.kind==kind and reply.ok==true,'synthetic_rpc/rejected')
end
local C=require('weread.lib.readtime_transfer_contract')
local selection=assert(C.select(input.rows,{parts=input.parts},input.now,input.book_id))
if input.mode=='tamper' then selection.file_id=string.rep('f',64) end
rpc('selection',{selection=selection})
local body=require('weread.lib.readtime_protocol').batch(input.grant,input.book_id,selection.protocol_rows,
    input.guest,input.config,input.now,123,{timestamp=input.now*1000,random=456,current_zone='+08:00'})
rpc('claim',{body=body,selection=selection})
if input.mode=='drop' then os.exit(0) end
if input.mode=='duplicate' then rpc('claim',{body=body,selection=selection}) end
rpc('ack',{response={succ=1}})
io.stdout:write('\nWEREAD_NATIVE_THOUGHT_'..input.token..'_RESULT='..json.encode({result='PASS'})..'\n');io.stdout:flush()
