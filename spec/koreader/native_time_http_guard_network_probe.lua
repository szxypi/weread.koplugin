-- Synthetic-only loopback HTTP probe. It cannot contact the real service.
require('setupkoenv')
local json=require('json');local http=require('socket.http');local ltn12=require('ltn12')
http.PROXY=nil
local input=json.decode(assert(io.stdin:read('*a')))
assert(type(input.port)=='number' and input.port%1==0 and input.port>=1 and input.port<=65535)
assert(input.mode=='success' or input.mode=='dry_run' or input.mode=='bad_status' or input.mode=='no_ack' or input.mode=='disconnect' or input.mode=='redirect')
local root=assert(arg[1]);package.path=root..'/?.lua;'..root..'/?/init.lua;'..package.path
local Guard=require('spec.koreader.native_time_http_guard');local Cookie=require('weread.lib.cookie')
local grant={vid='900000',accessToken='synthetic-access',refreshToken='synthetic-refresh',deviceId='eink334691225'..string.rep('1',19)}
local cookies={wr_vid = '900000',wr_skey='synthetic-cookie'}
local client={settings={},json_encode=function(_self,value) return json.encode(value) end,json_decode=function(_self,value) return json.decode(value) end}
function client:request(options)
    local path=options.url=='https://i.weread.qq.com/book/batchUploadProgress' and '/native/write'
        or options.url=='https://weread.qq.com/web/book/chapterInfos' and '/web/read' or '/native/read'
    local body=options.body;local pieces={}
    local result,code,headers,status=http.request{url='http://127.0.0.1:'..input.port..path,method=options.method,
        headers=body and {['content-length']=tostring(#body)} or {},source=body and ltn12.source.string(body),sink=ltn12.sink.table(pieces),redirect=options.redirect}
    if not result then error('synthetic_http/unavailable',0) end
    local raw=table.concat(pieces);options.sink(raw);options.sink(nil)
    return nil,tonumber(code),headers,status
end
local events={}
local guarded=Guard.install(client,{grant=grant,book_id='900001',chapter_uid='11',cookies=cookies,months={1698796800},now=function() return 1700000000 end,
    current=function() return true end,selection=function() return {synthetic=true} end,record=function() return {phase='claimed'} end,
    rpc=function(kind,value)
        events[#events+1]=kind
        if kind=='claim' then return input.mode~='dry_run' end
        return value.status==200 and value.response.succ==1
    end})
local function options(url,method,api,body,web)
    local h=web and {Cookie=Cookie.to_header(cookies),Origin='https://weread.qq.com'} or {vid=grant.vid,accessToken=grant.accessToken}
    return {url=url,method=method,diagnostic_api=api,body=body,headers=h,skip_cookie=true,persist_response_cookies=false,
        sensitive=true,sink=function() return 1 end}
end
assert(select(2,client:request(options('https://i.weread.qq.com/book/info?bookId=900001','GET','native_time_metadata')))==200)
assert(select(2,client:request(options('https://weread.qq.com/web/book/chapterInfos','POST','source_currentness',json.encode({bookIds={'900001'}}),true)))==200)
local request=options('https://i.weread.qq.com/book/batchUploadProgress','POST','native_time_write',json.encode({books={}}))
local accepted=pcall(client.request,client,request);local replay=pcall(client.request,client,request)
assert(not replay and guarded.write_attempted)
assert(accepted==(input.mode=='success'))
assert(guarded.write_forwarded==(input.mode~='dry_run'))
assert(guarded.acknowledged==(input.mode=='success'))
assert(events[1]=='claim' and #events==((input.mode=='dry_run' or input.mode=='disconnect') and 1 or 2))
io.stdout:write('\nWEREAD_SYNTHETIC_HTTP='..json.encode({result='PASS',mode=input.mode,attempted=guarded.write_attempted,
    forwarded=guarded.write_forwarded,acknowledged=guarded.acknowledged,replay_blocked=not replay})..'\n')
