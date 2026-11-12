-- Owner metadata and credentials are compared only in captured memory pipes.
require('ffi').log=function() end
require('setupkoenv')
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open('/tmp/weread-shelf-flags-probe.lua')
local Device=require('device');require('document/canvascontext'):init(Device)
package.path=assert(arg[1])..'/?.lua;'..package.path
local json=require('json')
local bytes=io.stdin:read(8*1024*1024+1)
local ok,result=pcall(function()
    assert(#bytes<=8*1024*1024)
    local input=json.decode(bytes);bytes=nil
    local Flags=require('weread.lib.shelf_flags')
    local Source=require('weread.lib.shelf_source')
    local function project(shelf,kind)
        local rows=json.decode('[]')
        for _,book in ipairs(Source.normalize(shelf,kind).books) do
            local value=Flags.project(book);value.book_id=book.bookId;rows[#rows+1]=value
        end
        return rows
    end
    local output={model={native=project(input.shelves.native,'native'),web=project(input.shelves.web,'web')}}
    if input.credentials then
        local session=input.session
        local scope={vid=session.vid,epoch=1}
        assert(input.credentials.vid==scope.vid)
        local settings={get=function(_self,key,default) if key=='cookies' then return session.cookies end;return default end,
            get_auth_scope=function() return scope end,auth_scope_matches=function(_self,value) return value==scope end}
        local client=require('weread.lib.client'):new(settings)
        local base,calls=client.request,0
        client.request=function(self,options)
            assert(options.method=='GET' and (options.url=='https://i.weread.qq.com/shelf/sync' or options.url=='https://weread.qq.com/web/shelf/sync'))
            calls=calls+1;assert(calls<=2)
            return base(self,options)
        end
        local auth=require('weread.lib.native_authorization'):new(client,{expected_vid=scope.vid})
        local native=auth:read_shelf(input.credentials);auth:cancel()
        output.native={native=project(native,'native'),web=project(client:get_web_shelf(session.cookies),'web')}
        output.requests=calls
    end
    return output
end)
io.write('\nWEREAD_FLAGS_RESULT='..json.encode(ok and result or {error='probe_failed'}))
os.exit(ok and 0 or 1)
