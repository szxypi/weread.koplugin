-- Live read-only adapter: inputs/outputs stay in pipes, no saved credentials.
require('jit').off()
require('ffi').log=function() end
require('setupkoenv')
G_reader_settings=require('luasettings'):wrap({})
G_defaults=require('luadefaults'):open()
package.loaded['weread.lib.logger']={info=function() end,warn=function() end,err=function() end,dbg=function() end}
package.path=assert(arg[1])..'/?.lua;'..package.path
local json=require('json')
local count=0
local good,result=pcall(function()
    local raw=assert(io.stdin:read(65537));assert(#raw<=65536)
    local input=json.decode(raw)
    io.write('PROBE_INPUT\n');io.flush()
    local scope={vid=input.credentials.vid,epoch=1}
    local settings={get=function(_self,_key,default) return default end,
        get_auth_scope=function() return scope end,auth_scope_matches=function(_self,value) return value==scope end}
    local store={read=function() return input.credentials,1,nil,false end}
    local client=require('weread.lib.client'):new(settings)
    io.write('PROBE_CLIENT\n');io.flush()
    local request=client.request
    client.request=function(self,options)
        count=count+1;io.write('PROBE_REQUEST_'..count..'\n');io.flush();assert(count<=6 and options.skip_cookie and options.persist_response_cookies==false)
        local base='https://i.weread.qq.com'
        if options.url==base..'/pay/memberCardSummary?pf=wechat_wx-2001-android-100-weread'
            or options.url==base..'/book/info?bookId='..input.book_id then
            assert(options.method=='GET' and options.body==nil)
        else
            assert(options.url==base..'/book/chapterInfos' and options.method=='POST')
            local body=json.decode(options.body)
            assert(body.bookIds[1]==input.book_id and #body.bookIds==1 and body.synckeys[1]==0
                and body.updateTimes[1]==0 and body.maxfreeIdx[1]==0)
        end
        return request(self,options)
    end
    io.write('PROBE_BEFORE_NETWORK\n');io.flush()
    local selected=assert(require('weread.lib.native_read_access').capture(settings,store))
    local result=assert(require('weread.lib.translation_generation_access').inspect(client,settings,selected,
        input.book_id,input.uid,{is_current=function() return true end}))
    assert(count==6)
    return {ok=true,requests=count,version=result.version,translate_version=result.translate_version}
end)
io.write('\nTRANSLATION_ACCESS='..json.encode(good and result or {ok=false,requests=count})..'\n');io.flush()
os.exit(good and 0 or 1)
