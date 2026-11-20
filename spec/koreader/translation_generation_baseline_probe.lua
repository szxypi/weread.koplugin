-- Live, read-only baseline via memory-only credentials and exact request scope.
require('jit').off()
require('ffi').log=function() end
require('setupkoenv')
G_reader_settings=require('luasettings'):wrap({})
G_defaults=require('luadefaults'):open()
package.loaded['weread.lib.logger']={info=function() end,warn=function() end,err=function() end,dbg=function() end}
package.path=assert(arg[1])..'/?.lua;'..package.path
local json=require('json')
local native_count,web_count=0,0
local good,result=pcall(function()
    local raw=assert(io.stdin:read(65537));assert(#raw<=65536)
    local input=json.decode(raw)
    local scope={vid=input.credentials.vid,epoch=1}
    local settings={get=function(_self,key,default) if key=='cookies' then return input.cookies end;return default end,
        get_auth_scope=function() return scope end,auth_scope_matches=function(_self,value) return value==scope end}
    local store={read=function() return input.credentials,1,nil,false end}
    local client=require('weread.lib.client'):new(settings)
    local request=client.request
    client.request=function(self,options)
        assert(options.method=='GET' and not options.body and options.skip_cookie and not options.persist_response_cookies)
        if options.url:match('^https://i%.weread%.qq%.com/') then
            native_count=native_count+1;assert(native_count<=4)
            assert(options.url=='https://i.weread.qq.com/book/getProgress?bookId='..input.book_id
                or options.url=='https://i.weread.qq.com/shelf/sync')
        else
            web_count=web_count+1;assert(web_count<=4)
            local progress='https://weread.qq.com/web/book/getProgress?bookId='..input.book_id..'&_='
            assert(options.url=='https://weread.qq.com/web/shelf/sync' or options.url:sub(1,#progress)==progress
                and options.url:sub(#progress+1):match('^%d+$'))
        end
        return request(self,options)
    end
    local selected=assert(require('weread.lib.native_read_access').capture(settings,store))
    local web=assert(require('weread.lib.read_access').capture(settings))
    local value,reason=require('weread.lib.translation_generation_baseline').stable(client,settings,selected,web,input.book_id,
        {is_current=function() return true end})
    if not value then return {ok=false,reason=reason,native_reads=native_count,web_reads=web_count} end
    return {ok=true,position_present=value.position_present,native_reads=native_count,web_reads=web_count}
end)
io.write('\nTRANSLATION_BASELINE='..json.encode(good and result or {ok=false,native_reads=native_count,web_reads=web_count})..'\n')
io.flush();os.exit(good and 0 or 1)
