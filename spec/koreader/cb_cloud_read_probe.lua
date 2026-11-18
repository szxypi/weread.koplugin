-- Private target and credentials arrive through stdin and never enter output.
require('ffi').log=function() end
require('setupkoenv')
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open('/tmp/weread-cb-cloud-read-probe.lua')
local Device=require('device');require('document/canvascontext'):init(Device)
package.path=assert(arg[1])..'/?.lua;'..package.path
local json=require('json')
local bytes=io.stdin:read(131073)
local ok,result=pcall(function()
    assert(#bytes<=131072)
    local input=json.decode(bytes);bytes=nil
    local scope={vid=input.vid,epoch=1}
    local settings={get=function(_self,key,default) if key=='cookies' then return input.cookies end;return default end,
        get_auth_scope=function() return scope end,auth_scope_matches=function(_self,value) return value==scope end}
    local Client=require('weread.lib.client');local client=Client:new(settings)
    local Protocol=require('weread.lib.protocol');local request=client.request;local calls=0
    function client:request(options)
        local path=options.url
        local progress='https://weread.qq.com/web/book/getProgress?bookId='..Protocol.urlencode(input.book)
        local reader=Protocol.reader_url(input.book,input.chapter)
        local allowed=options.method=='GET' and (path==progress or path==reader)
        if options.method=='POST' and path:match('^https://weread%.qq%.com/web/book/chapter/e_[013]$') then
            local body=self:json_decode(options.body)
            allowed=type(body)=='table' and body.b==Protocol.e(input.book) and body.c==Protocol.e(input.chapter)
        end
        assert(allowed and calls<6,'out of scope');calls=calls+1
        return request(self,options)
    end
    local target=require('weread.lib.source_cloud').fetch(client,input.book)
    return {matched=target.book_id==input.book and target.chapter_uid==input.chapter
            and target.chapter_offset==input.offset and target.raw_sha256==input.source_sha256
            and target.upload_verified==false,requests=calls}
end)
io.write('\nWEREAD_CB_CLOUD_READ='..json.encode(ok and result or {matched=false})..'\n')
os.exit(ok and 0 or 1)
