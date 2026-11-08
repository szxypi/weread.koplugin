-- Owner-approved memory-only comparison; only fixed Web progress GETs allowed.
require("ffi").log=function() end
require("setupkoenv")
G_defaults=require("luadefaults"):open()
G_reader_settings=require("luasettings"):open("/tmp/weread-display-probe-settings.lua")
local Device=require("device")
require("document/canvascontext"):init(Device)
package.path=assert(arg[1]).."/?.lua;"..package.path
local json=require("json")
local bytes=io.stdin:read(1024*1024+1)
local stage="model"
local statuses={}
local diagnostics={}
local ok,result=pcall(function()
    assert(#bytes<=1024*1024)
    local input=json.decode(bytes);bytes=nil
    assert(type(input.samples)=="table" and #input.samples>=1 and #input.samples<=12)
    local Data=require("weread.lib.shelf_progress")
    local model,ids,allowed=json.decode("[]"),{},{}
    local function display(snapshot) return {book_id=snapshot.book_id,percent=snapshot.percent} end
    for _,sample in ipairs(input.samples) do
        local id=assert(Data.book_id(sample.book_id))
        assert(not allowed[id]);allowed[id]=true;ids[#ids+1]=id
        local snapshot,reason=Data.parse(sample.raw,id)
        assert(snapshot or reason=="unavailable")
        if snapshot then model[#model+1]=display(snapshot) end
    end
    local output={model=model}
    if input.session then
        stage="client"
        local scope={vid=input.session.vid,epoch=1}
        local settings={
            get=function(_self,key,default) if key=="cookies" then return input.session.cookies end return default end,
            get_auth_scope=function() return scope end,
            auth_scope_matches=function(_self,check) return check==scope end,
        }
        local client=require("weread.lib.client"):new(settings)
        local request=client.request
        local reads=0
        function client:request(options)
            local id=options.url:match("^https://weread%.qq%.com/web/book/getProgress%?bookId=(%d+)$")
            assert(options.method=="GET" and id and allowed[id],"readonly_scope_required")
            reads=reads+1
            assert(reads<=#ids)
            local body,code,headers,status=request(self,options)
            statuses[#statuses+1]=code or 0
            return body,code,headers,status
        end
        local read_display=client.get_shelf_display_progress
        function client:get_shelf_display_progress(id,access)
            local read_ok,response=pcall(read_display,self,id,access)
            if not read_ok then
                diagnostics[#diagnostics+1]={read_failed=true,decode_failed=response=="sensitive_json_invalid",
                    limit_or_http_failed=response=="display_progress/unavailable"}
                error("probe_read_failed",0)
            end
            local snapshot,reason=Data.parse(response,id)
            diagnostics[#diagnostics+1]={has_book=type(response)=="table" and type(response.book)=="table",
                valid_display=snapshot~=nil,unavailable=reason=="unavailable"}
            return response
        end
        stage="fetch"
        local batch=Data.fetch(client,ids,{checkCancelled=function() end,emit=function() end})
        assert(not batch.failed and not batch.stale)
        local native=json.decode("[]")
        for _,snapshot in ipairs(batch.snapshots) do
            assert(snapshot.source=="web")
            if not snapshot.unavailable then native[#native+1]=display(snapshot) end
        end
        output.native=native;output.requests=reads
    end
    return output
end)
io.stdout:write("\nWEREAD_DISPLAY_RESULT="..json.encode(ok and result or {error="probe_failed",stage=stage,statuses=statuses,
    diagnostics=diagnostics}).."\n")
os.exit(ok and 0 or 1)
