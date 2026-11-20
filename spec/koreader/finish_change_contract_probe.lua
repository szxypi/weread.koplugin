-- Captured real snapshots; no credentials, HTTP, persistence or UI movement.
require('ffi').log=function() end
require('setupkoenv');package.path='/source/?.lua;'..package.path
local json=require('json');local raw=assert(io.stdin:read(8*1024*1024+1));assert(#raw<=8*1024*1024)
local input=json.decode(raw);local Contract=require('weread.lib.finish_change_contract');local plans={}
assert(type(input.samples)=='table' and #input.samples==2)
local Task=require('weread.lib.finish_change_task');local scope={vid='900000',epoch=1}
local settings={get_auth_scope=function() return scope end,auth_scope_matches=function() return true end}
local credentials={vid=scope.vid,accessToken='fixture-finish-access'}
local selected=require('weread.lib.native_read_access').capture(settings,{read=function() return credentials,1 end})
local calls=0;local codec={json_encode=function(_self,value) return json.encode(value) end,json_decode=function(_self,value) return json.decode(value) end}
function codec:request(options)
    assert(options.method=='GET' and not options.body and options.sensitive and options.skip_cookie and options.persist_response_cookies==false
        and options.headers.vid==scope.vid and options.headers.accessToken==credentials.accessToken and not options.headers.Cookie)
    local value=options.url=='https://i.weread.qq.com/shelf/sync' and input.shelf
    for _i,sample in ipairs(input.samples) do if options.url=='https://i.weread.qq.com/book/getProgress?bookId='..sample.book_id then value=sample.progress end end
    assert(value);calls=calls+1;return json.encode(value),200
end
for _i,sample in ipairs(input.samples) do
    local plan=Task.preview(codec,settings,selected,sample.book_id,sample.desired);plan.observed=nil;plans[#plans+1]=plan
    assert(not Contract.check(input.shelf,sample.progress,plans[#plans].metadata))
end
assert(calls==4)
io.write('\nWEREAD_FINISH_CHANGE_RESULT='..json.encode(plans)..'\n')
