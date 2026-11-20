-- Real-source read-only check. All identity and credentials enter via stdin.
require('ffi').log=function() end
require('setupkoenv')
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open('/tmp/weread-cb-source-currentness-probe.lua')
local Device=require('device');require('document/canvascontext'):init(Device)
package.path=assert(arg[1])..'/?.lua;'..package.path
local json=require('json');local calls=0;local ok,result=pcall(function()
    local raw=io.stdin:read(65537);assert(#raw<=65536)
    local input=json.decode(raw)
    local scope={vid=input.vid,epoch=1}
    local settings={get=function(_self,key,default) if key=='cookies' then return input.cookies end;return default end,
        get_auth_scope=function() return scope end,auth_scope_matches=function(_self,value) return value==scope end}
    local Client=require('weread.lib.client');local client=Client:new(settings)
    local Protocol=require('weread.lib.protocol');local Cookie=require('weread.lib.cookie')
    local account='https://weread.qq.com/api/userInfo?userVid='..Protocol.urlencode(input.vid)
    local catalog='https://weread.qq.com/web/book/chapterInfos'
    local reader=Protocol.reader_url(input.expected.book_id,input.expected.chapter_uid)
    local paths={{'GET',account},{'POST',catalog},{'GET',reader},
        {'POST','https://weread.qq.com/web/book/chapter/e_0'},{'POST','https://weread.qq.com/web/book/chapter/e_1'},
        {'POST','https://weread.qq.com/web/book/chapter/e_3'},{'POST',catalog},{'GET',account}}
    local request=client.request
    function client:request(options)
        local next_item=paths[calls+1]
        assert(next_item and options.method==next_item[1] and options.url==next_item[2] and options.sensitive==true
            and options.skip_cookie==true and options.persist_response_cookies==false
            and options.headers.Cookie==Cookie.to_header(input.cookies),'scope')
        if options.method=='POST' then
            local body=self:json_decode(options.body)
            if options.url==catalog then
                local n=0;for _key in pairs(body) do n=n+1 end
                assert(n==1 and type(body.bookIds)=='table' and #body.bookIds==1 and body.bookIds[1]==input.expected.book_id)
            else
                assert(body.b==Protocol.e(input.expected.book_id) and body.c==Protocol.e(input.expected.chapter_uid))
            end
        else assert(options.body==nil) end
        calls=calls+1;return request(self,options)
    end
    local Check=require('weread.lib.source_currentness')
    local proof
    if input.book_version~=nil then
        assert(type(input.book_version)=='number' and input.book_version%1==0 and input.book_version>0)
        local observed=0
        proof=Check.fetch_cb_versioned(client,input.expected,nil,function(catalog_data)
            assert(require('weread.lib.readtime_source').version(catalog_data,input.expected.book_id)==input.book_version)
            observed=observed+1
        end)
        assert(observed==2)
    else proof=Check.fetch_cb(client,input.expected) end
    assert(Check.packet_cb(proof,input.expected) and not Check.packet(proof,input.expected)
        and Check.run(client,input.expected).error=='source_currentness_unavailable')
    return {matched=true,requests=calls,upload_disabled=proof.upload_verified==false,numeric_gate_preserved=true}
end)
if not ok then
    local code=type(result)=='string' and result:match('source_currentness/([a-z_]+)') or nil
    local allowed={expected=true,catalog=true,catalog_changed=true,reader=true,source_invalid=true,source_changed=true,
        web_required=true,session_changed=true,web_expired=true,unavailable=true,response=true,owner=true}
    result={matched=false,requests=calls,reason=allowed[code] and code or 'probe',
        line=tonumber(type(result)=='string' and result:match('cb_source_currentness_probe%.lua:(%d+):')) or 0}
end
print('\nWEREAD_CB_SOURCE_CURRENTNESS='..json.encode(result))
os.exit(ok and 0 or 1)
