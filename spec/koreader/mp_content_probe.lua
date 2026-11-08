-- Existing article-body extraction, with real bytes kept in memory pipes only.
require('ffi').log=function() end
require('setupkoenv')
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open('/tmp/weread-mp-content-probe.lua')
local Device=require('device');require('document/canvascontext'):init(Device)
package.path=assert(arg[1])..'/?.lua;'..package.path
local json=require('json')
local bytes=io.stdin:read(12*1024*1024+1)
local ok,result=pcall(function()
    assert(#bytes<=12*1024*1024)
    local input=json.decode(bytes);bytes=nil
    assert(input.review_id=='MP_WXS_3286016687_9gm5eWle7VrEYNiwBGaaOQ')
    local Content=require('weread.lib.content')
    local Crypto=require('weread.lib.crypto')
    local function project(html)
        assert(type(html)=='string' and #html<=4*1024*1024)
        local body=assert(Content.extract_mp_body(html))
        return {body_bytes=#body,body_sha256=Crypto.sha256_hex(body)}
    end
    local output={model=project(input.html)};input.html=nil
    local scope={vid=input.session.vid,epoch=1}
    local settings={get_auth_scope=function() return scope end,auth_scope_matches=function(_self,value) return value==scope end,
        get=function(_self,key,default) if key=='cookies' then return input.session.cookies end
            if key=='wr_wrpa' then return input.web_headers and input.web_headers.wr_wrpa or '' end;return default end}
    local client=require('weread.lib.client'):new(settings)
    local allowed={}
    assert(type(input.mp_books)=='table' and #input.mp_books>=1 and #input.mp_books<=2)
    for _,book in ipairs(input.mp_books) do
        assert(type(book)=='string' and #book<=28 and book:match('^MP_WXS_[1-9]%d*$'))
        allowed['https://weread.qq.com/web/mp/articles?bookId='..book..'&maxIdx=0&count=100']=true
    end
    local request,reads=client.request,0
    function client:request(options)
        assert(options.method=='GET' and (allowed[options.url] or options.url=='https://weread.qq.com/web/mp/content?reviewId='..input.review_id))
        reads=reads+1;assert(reads<=#input.mp_books+1)
        local chunks,size={},0
        options.persist_response_cookies=false
        options.sink=function(chunk)
            if not chunk then return 1 end
            size=size+#chunk;if size>4*1024*1024 then return nil,'content_limit' end
            chunks[#chunks+1]=chunk;return 1
        end
        local _,code,headers=request(self,options)
        return table.concat(chunks),code,headers
    end
    output.catalog={}
    for _,book in ipairs(input.mp_books) do
        local data,code=client:get_mp_articles(book,0,100,input.web_headers and input.web_headers.wr_ticket)
        assert(code==nil or (type(code)=='number' and code==code and code%1==0 and code>=-2147483648 and code<2147483648))
        output.catalog[#output.catalog+1]={error_code=code or 0,group_count=type(data)=='table' and type(data.reviews)=='table' and #data.reviews or 0}
    end
    output.native=project(client:get_mp_content(input.review_id,{skip_mp_auth_headers=true}))
    output.requests=reads
    return output
end)
io.stdout:write('\nWEREAD_MP_CONTENT_RESULT='..json.encode(ok and result or {error='probe_failed'})..'\n')
os.exit(ok and 0 or 1)
