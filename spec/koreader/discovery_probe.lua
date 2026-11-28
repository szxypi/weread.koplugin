-- Real responses and credentials travel only in bounded captured memory pipes.
require("ffi").log=function() end
require("setupkoenv")
G_defaults=require("luadefaults"):open()
G_reader_settings=require("luasettings"):open("/tmp/weread-discovery-probe-settings.lua")
local Device=require("device")
require("document/canvascontext"):init(Device)
package.path=assert(arg[1]).."/?.lua;"..package.path
local json=require("json")
local raw=io.stdin:read(4*1024*1024+1)
local ok,result=pcall(function()
    assert(#raw<=4*1024*1024)
    local payload=json.decode(raw);raw=nil
    assert(type(payload.samples)=="table" and #payload.samples<=6)
    local Source=require("weread.lib.discovery_source")
    local output={model=json.decode("[]")}
    local codec={json_decode=function(_self,value) return json.decode(value) end}
    for _,sample in ipairs(payload.samples) do
        output.model[#output.model+1]=Source.project(codec,sample.kind,sample.source,sample.cursor)
    end
    if payload.credentials then
        local scope={vid=payload.credentials.vid,epoch=1}
        local settings={get=function(_self,_key,default) return default end,
            get_auth_scope=function() return scope end,auth_scope_matches=function(_self,value) return value==scope end}
        local store={read=function() return payload.credentials,1 end}
        local client=require("weread.lib.client"):new(settings)
        local request,reads=client.request,0
        function client:request(options)
            local path=options.url:match("^https://i%.weread%.qq%.com(/[^?]+)%?")
            assert(options.method=="GET" and (path=="/store/search" or path=="/book/recommend" or path=="/book/detailinfo"))
            reads=reads+1;assert(reads<=6)
            return request(self,options)
        end
        local selected=assert(Source.capture(settings,store))
        output.native_pages=json.decode("[]")
        for _,kind in ipairs({"recommend","search","similar"}) do
            local query={kind=kind,cursor=0,keyword=kind=="search" and "三体" or nil,book_id=payload.book_id}
            local first=Source.fetch(client,query,selected)
            assert(first.source_kind=="native")
            local record={kind=kind,first_count=#first.books,has_more=first.has_more,session_returned=kind=="similar" and first.session_id~="" or false}
            if first.has_more then
                query.cursor=first.next_cursor;query.source_kind=first.source_kind;query.source_revision=first.source_revision
                query.session_id=first.session_id
                local second=Source.fetch(client,query,selected)
                local seen={};for _,book in ipairs(first.books) do seen[book.bookId]=true end
                for _,book in ipairs(second.books) do assert(not seen[book.bookId]) end
                assert(second.next_cursor>first.next_cursor and (kind~="similar" or second.session_id==first.session_id))
                record.second_count=#second.books;record.cursor_advanced=true;record.overlap_count=0
                record.session_preserved=kind~="similar" or second.session_id==first.session_id
            end
            output.native_pages[#output.native_pages+1]=record
        end
        output.requests=reads
    end
    return output
end)
io.stdout:write("\nWEREAD_DISCOVERY_RESULT="..json.encode(ok and result or {error="probe_failed"}).."\n")
os.exit(ok and 0 or 1)
