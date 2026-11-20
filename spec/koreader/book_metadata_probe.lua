-- Private display fields only travel in a captured memory pipe, never files.
require("ffi").log=function() end
require("setupkoenv")
G_defaults=require("luadefaults"):open()
G_reader_settings=require("luasettings"):open("/tmp/weread-metadata-probe-settings.lua")
local Device=require("device")
require("document/canvascontext"):init(Device)
package.path=assert(arg[1]).."/?.lua;"..package.path
local json=require("json")
local input=io.stdin:read(2*1024*1024+1)
local ok,result=pcall(function()
    assert(#input<=2*1024*1024)
    local payload=json.decode(input);input=nil
    assert(type(payload.samples)=="table" and #payload.samples>=1 and #payload.samples<=(payload.cb_metadata==true and 8 or 4))
    local Metadata=require("weread.lib.book_metadata")
    local Access=require("weread.lib.read_access")
    local Protocol=require("weread.lib.protocol")
    local output={model=json.decode("[]")}
    local allowed={}
    for _,sample in ipairs(payload.samples) do
        local id=assert((payload.cb_metadata==true and Access.display_book_id or Access.book_id)(sample.book_id))
        if payload.cb_metadata==true then assert(id:match('^CB_')) end
        assert(not allowed[Protocol.reader_url(id)])
        allowed[Protocol.reader_url(id)]=true
        output.model[#output.model+1]=(sample.native and Metadata.normalize_native or Metadata.normalize)(sample.source,id)
    end
    if payload.session then
        local scope={vid=payload.session.vid,epoch=1}
        local settings={get=function(_self,key,default)
            if key=="cookies" then return payload.session.cookies end
            return default
        end,get_auth_scope=function() return scope end,auth_scope_matches=function(_self,current) return current==scope end}
        local client=require("weread.lib.client"):new(settings)
        local request,reads=client.request,0
        function client:request(options)
            assert(options.method=="GET" and allowed[options.url],"readonly_scope_required")
            reads=reads+1;assert(reads<=#payload.samples)
            return request(self,options)
        end
        output.native=json.decode("[]")
        for _,sample in ipairs(payload.samples) do
            local value=Metadata.fetch(client,sample.book_id)
            assert(value.source=="web")
            output.native[#output.native+1]=value.metadata
        end
        output.requests=reads
    end
    if payload.native_credentials then
        assert(not payload.session)
        local scope={vid=payload.native_credentials.vid,epoch=1}
        local settings={get=function(_self,_key,default) return default end,
            get_auth_scope=function() return scope end,auth_scope_matches=function(_self,current) return current==scope end}
        local store={read=function() return payload.native_credentials,1 end}
        local client=require("weread.lib.client"):new(settings)
        local request,reads=client.request,0
        local native_allowed={}
        for _,sample in ipairs(payload.samples) do
            native_allowed["https://i.weread.qq.com/book/info?bookId="..sample.book_id]=true
        end
        function client:request(options)
            assert(options.method=="GET" and native_allowed[options.url],"readonly_native_scope_required")
            reads=reads+1;assert(reads<=#payload.samples)
            return request(self,options)
        end
        output.native=json.decode("[]")
        for _,sample in ipairs(payload.samples) do
            local value=Metadata.fetch(client,sample.book_id,Metadata.capture(settings,store))
            assert(value.source=="native")
            output.native[#output.native+1]=value.metadata
        end
        output.requests=reads
    end
    return output
end)
io.stdout:write("\nWEREAD_METADATA_RESULT="..json.encode(ok and result or {error="probe_failed"}).."\n")
os.exit(ok and 0 or 1)
