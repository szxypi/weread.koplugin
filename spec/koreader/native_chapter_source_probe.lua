-- Real credentials, identity and text enter only via a private pipe.
require('jit').off()
require('ffi').log=function() end
require('setupkoenv')
G_reader_settings=require('luasettings'):wrap({})
G_defaults=require('luadefaults'):open()
package.loaded['weread.lib.logger']={info=function() end,warn=function() end,err=function() end,dbg=function() end}
package.path=assert(arg[1])..'/?.lua;'..package.path
local json=require('json')
local count,reason=0,'probe_failed'
local ok,result=pcall(function()
    local raw=assert(io.stdin:read(65537));assert(#raw<=65536)
    local input=json.decode(raw)
    local scope={vid=input.credentials.vid,epoch=1}
    local settings={get=function(_self,_key,default) return default end,
        get_auth_scope=function() return scope end,auth_scope_matches=function(_self,value) return value==scope end}
    if input.mock_endpoint~=nil then
        assert(os.getenv('WEREAD_SYNTHETIC')=='1' and type(input.mock_endpoint)=='string'
            and input.mock_endpoint:match('^http://127%.0%.0%.1:%d+$'))
        settings.mock_endpoint=input.mock_endpoint
    end
    local store={read=function() return input.credentials,1,nil,false end}
    local client=require('weread.lib.client'):new(settings)
    local request=client.request
    client.request=function(self,options)
        count=count+1
        assert(count<=3 and options.skip_cookie and options.persist_response_cookies==false and options.sensitive)
        local base='https://i.weread.qq.com'
        if count==1 then
            assert(options.url==base..'/book/info?bookId='..input.book_id and options.method=='GET')
        elseif count==2 then
            assert(options.url==base..'/book/chapterInfos' and options.method=='POST')
            local body=json.decode(options.body)
            assert(body.bookIds[1]==input.book_id and #body.bookIds==1 and body.synckeys[1]==0)
        else
            assert(options.method=='GET' and options.url:find(base..'/book/chapterdownload?',1,true)==1
                and options.url:find('stopAutoPayWhenBNE=1',1,true) and options.url:find('preview=0',1,true))
        end
        return request(self,options)
    end
    local selected=assert(require('weread.lib.native_read_access').capture(settings,store))
    local source,why=require('weread.lib.native_chapter_source').fetch(client,settings,selected,input.book_id,input.uid,
        {is_current=function() return true end})
    if not source then reason=why;error('source_failed') end
    assert(count==3 and source.source_channel=='eink' and source.coordinate_source_authoritative==false)
    local Crypto=require('weread.lib.crypto')
    local assets=json.decode('[]')
    for _,asset in ipairs(source.assets) do
        assets[#assets+1]={digest=Crypto.sha256_hex(asset.data),mime=asset.media_type,
            safe_href=asset.href:match('^images/native%-%d+%.[a-z]+$')~=nil,
            parent_source=asset.source:find('../',1,true)~=nil}
    end
    return {ok=true,requests=count,body_sha256=Crypto.sha256_hex(source.body),css_sha256=Crypto.sha256_hex(source.css),
        is_text=source.is_text,web_coordinate_authority=source.coordinate_source_authoritative,assets=assets,
        image_signatures_recognized=source.image_signatures_recognized,unusable_resources=source.unusable_resources}
end)
if reason~='invalid' and reason~='session_changed' and reason~='rate_limited' and reason~='auth_expired' and reason~='service_rejected'
    and reason~='not_entitled' and reason~='unavailable' then reason='probe_failed' end
io.stdout:write('\nWEREAD_NATIVE_SOURCE_RESULT='..json.encode(ok and result or {ok=false,requests=count,reason=reason})..'\n')
os.exit(ok and 0 or 1)
