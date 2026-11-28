-- Real responses and credentials enter/leave only through private memory pipes.
require('ffi').log=function() end
require('setupkoenv');package.path=assert(arg[1])..'/?.lua;'..package.path
local json=require('json');local output={result='UNVERIFIED'}
local ok,value=pcall(function()
    G_defaults=require('luadefaults'):open()
    G_reader_settings=require('luasettings'):open('/dev/shm/weread-position-review-probe-settings.lua')
    local Device=require('device');require('document/canvascontext'):init(Device)
    local input
    do local raw=assert(io.stdin:read(65537));assert(#raw<=65536);input=json.decode(raw) end
    local C=require('weread.lib.native_position_contract');assert(C.valid(input.metadata))
    local scope={vid=input.credentials.vid,epoch=1}
    local settings={get=function(_self,_key,default) return default end,get_auth_scope=function() return scope end,
        auth_scope_matches=function(_self,v) return v==scope end}
    local store={read=function() return input.credentials,1,nil,false end}
    local access=assert(require('weread.lib.native_read_access').capture(settings,store))
    local record={schema=1,id=string.rep('1',32),account=C.account_key(scope.vid),epoch=1,phase='pending',revision=2,metadata=input.metadata}
    local original=C.hash(record.metadata);local journal={read=function() return json.decode(json.encode(record)) end}
    local client=require('weread.lib.client'):new(settings);local request=client.request;local gets=0
    local allowed={['https://i.weread.qq.com/book/info?bookId='..input.metadata.book_id]=true,
        ['https://i.weread.qq.com/book/getProgress?bookId='..input.metadata.book_id]=true,['https://i.weread.qq.com/shelf/sync']=true}
    function client:request(options)
        assert(options.method=='GET' and not options.body and allowed[options.url] and gets<6
            and options.skip_cookie==true and options.persist_response_cookies==false and options.sensitive==true
            and options.headers.vid==scope.vid and options.headers.accessToken==input.credentials.accessToken and not options.headers.Cookie)
        gets=gets+1;return request(self,options)
    end
    local result=require('weread.lib.native_position_review_task').run(client,settings,access,record,journal,{valid=function() return true end})
    assert(result.kind=='observed' and result.readbacks==2 and gets==6)
    return {result='PASS',native_gets=gets,readbacks=result.readbacks,observation=result.observation,
        unchanged=record.phase=='pending' and record.revision==2 and C.hash(record.metadata)==original}
end)
if ok then output=value end
io.stdout:write('\nWEREAD_NATIVE_POSITION_REVIEW='..json.encode(output)..'\n');io.stdout:flush();os.exit(ok and 0 or 1)
