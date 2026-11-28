-- Credentials and source words enter only through an anonymous pipe.
require('ffi').log=function() end
require('setupkoenv')
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open('/dev/null')
local Device=require('device');require('document/canvascontext'):init(Device)
package.path=assert(arg[1])..'/?.lua;'..package.path
local json=require('json')
local raw=io.stdin:read(1024*1024+1)
local ok,result=pcall(function()
    assert(#raw<=1024*1024)
    local payload=json.decode(raw);raw=nil
    local credentials=assert(payload.credentials);local scope={vid=credentials.vid,epoch=1}
    local settings={get=function(_self,_key,default) return default end,
        get_auth_scope=function() return scope end,auth_scope_matches=function(_self,value) return value==scope end}
    local store={read=function() return credentials,1 end}
    local Access=require('weread.lib.native_gateway_access')
    local client=require('weread.lib.client'):new(settings)
    local request,reads=client.request,0
    function client:request(options)
        assert(options.method=='GET' and options.url:match('^https://i%.weread%.qq%.com/store/suggest%?count=10&keyword='))
        reads=reads+1;assert(reads<=1)
        return request(self,options)
    end
    local selected=assert(Access.capture(settings,store))
    local Model=require('weread.lib.search_suggestions')
    local model=Model.project(payload.reference,payload.keyword)
    local live=Model.fetch(client,selected,payload.keyword)
    assert(#model==#live and #live>0)
    for index,word in ipairs(model) do assert(word==live[index]) end
    return {result='PASS',projection_matches=true,native_https_matches=true,count=#live,requests=reads}
end)
io.stdout:write('\nWEREAD_SUGGESTION_PROBE='..json.encode(ok and result or {result='FAIL'})..'\n')
os.exit(ok and 0 or 1)
