-- Test-only fail-closed source-read gate. It never recognizes a data write,
-- renewal, native API, resource, redirect or cross-book/chapter request.
local Protocol=require('weread.lib.protocol')
local Cookie=require('weread.lib.cookie')
local M={};M.__index=M
function M:new(input,mode,counters,parent)
    local chapters,urls={},{}
    for _i,item in ipairs(input.chapters) do
        chapters[Protocol.e(item.chapter_uid)]=Protocol.reader_url(input.book_id,item.chapter_uid)
        urls[Protocol.reader_url(input.book_id,item.chapter_uid)]=true
    end
    urls[Protocol.reader_url(input.book_id)]=true
    return setmetatable({input=input,mode=mode,counters=counters,parent=parent,chapters=chapters,urls=urls},self)
end
function M:classify(client,options)
    if self.mode~='live' or self.counters[5]~=1 then return end
    local headers=options.headers or {};local cookies=client.settings:get('cookies',{})
    local explicit_cookie
    for key,value in pairs(headers) do
        local name=tostring(key):lower()
        if name=='authorization' or name=='accesstoken' or name=='vid' then return end
        if name=='cookie' then
            if explicit_cookie or value~=Cookie.to_header(cookies) then return end
            explicit_cookie=value
        end
    end
    if cookies.wr_vid~=self.input.owner or options.skip_cookie and not explicit_cookie then return end
    if options.method=='GET' and not options.body and self.urls[options.url] then return 1 end
    if options.method~='POST' or type(options.body)~='string' or #options.body>16384 then return end
    local decoded,body=pcall(client.json_decode,client,options.body);if not decoded or type(body)~='table' then return end
    if options.url=='https://weread.qq.com/web/book/chapterInfos' then
        local n=0;for _key in pairs(body) do n=n+1 end
        if n==1 and type(body.bookIds)=='table' and #body.bookIds==1 and body.bookIds[1]==self.input.book_id then return 2 end
    end
    local shard=type(options.url)=='string' and options.url:match('^https://weread%.qq%.com/web/book/chapter/(e_[0-3])$')
    if not shard then return end
    local allowed={b=true,c=true,r=true,ct=true,ps=true,pc=true,sc=true,prevChapter=true,st=true,s=true}
    local n=0;for key in pairs(body) do if not allowed[key] then return end;n=n+1 end
    if n==10 and body.b==Protocol.e(self.input.book_id) and self.chapters[body.c] and body.sc==1 and body.prevChapter==false
        and body.st==(shard=='e_2' and 1 or 0) and headers.Referer==self.chapters[body.c] then return 3 end
end
function M.install(gate,Client)
    local request=Client.request;local ffi=require('ffi');local limits={#gate.input.chapters*4,#gate.input.chapters,#gate.input.chapters*8}
    function Client:request(options)
        local kind=gate:classify(self,options)
        if not kind or gate.counters[kind]>=limits[kind] or tonumber(ffi.C.getpid())==gate.parent then
            gate.counters[4]=gate.counters[4]+1;error('note_download/transport_scope',0)
        end
        gate.counters[0]=gate.counters[0]+1;gate.counters[kind]=gate.counters[kind]+1
        options.sensitive,options.diagnostic_api=true,'note_download_source'
        local body,code,headers,status=request(self,options)
        if tonumber(code)~=200 then gate.counters[6]=gate.counters[6]+1 end
        return body,code,headers,status
    end
end
return M
