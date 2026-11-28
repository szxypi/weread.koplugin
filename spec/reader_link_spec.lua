package.path='./?.lua;'..package.path
local Link=require('weread.lib.reader_link')
local Protocol=require('weread.lib.protocol')
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local id='900001'
local url=Protocol.reader_url(id)
expect(Link.canonical(' '..Protocol.reader_url(id,'2')..'?wvid=discarded#discarded\n')==url,'sharing data or chapter retained')
expect(Link.canonical(url:gsub('https://weread.qq.com','HTTPS://WEREAD.QQ.COM'))==url,'case-insensitive host rejected')
for _,value in ipairs({url:gsub('https:','http:'),url:gsub('weread.qq.com','weread.qq.com.evil.test'),
    url:gsub('weread.qq.com','user@weread.qq.com'),url:gsub('weread.qq.com','weread.qq.com:443'),
    url:gsub('/web/reader/','/web/mp/reader/'),url..'/extra',url..'\nhttps://evil.test',url..'kbad',string.rep('x',4097)}) do
    expect(not Link.canonical(value),'non-reader destination accepted')
end
local source={bookId=id,title='Synthetic 中文',token='private',bookVersion=7,progress=88,author='Author'}
local state={reader={bookInfo=source}}
local html='window.__INITIAL_STATE__={synthetic};(function(){})();'
local record=Link.project(url,html,function() return state end)
expect(record.reader_url==url and record.metadata.title==source.title and record.metadata.token==nil
    and record.metadata.progress==nil and record.metadata.bookVersion==nil,'reader state entered imported metadata')
expect(not pcall(Link.project,Protocol.reader_url('900002'),html,function() return state end),'foreign book imported under selected link')
expect(not pcall(Link.project,url,'{"bookId":"900001"}',function() error('not JSON state') end),'fallback regex used')
expect(not pcall(Link.record,{reader_url=url,metadata={bookId=id,title=string.rep('a',4097)}}),'unbounded metadata accepted')
local function fixture()
    local values={valid=true,requests={},code=200,oversize=false}
    local scope={vid='900000',epoch=1}
    local settings={get_auth_scope=function() return scope end,auth_scope_matches=function() return values.valid end,
        get=function(_self,key,default) if key=='cookies' then return {wr_vid='900000',wr_skey='synthetic-link-cookie'} end;return default end}
    local client={settings=settings,json_decode=function() return state end}
    function client:request(options)
        values.requests[#values.requests+1]=options
        options.sink(values.oversize and string.rep('x',4*1024*1024+1) or html)
        if values.switch then values.valid=false end
        return '',values.code,{}
    end
    return client,values
end
local client,values=fixture()
local imported=Link.fetch(client,url..'?tracking=discarded')
local request=values.requests[1]
expect(imported.metadata.bookId==id and #values.requests==1 and request.url==url,'canonical Reader GET changed')
expect(request.sensitive and request.skip_cookie and request.persist_response_cookies==false
    and request.headers.Cookie:find('synthetic-link-cookie',1,true) and not request.headers.Authorization,'read access escaped captured cookie boundary')
for _,code in ipairs({301,302,401,429,503}) do
    client,values=fixture();values.code=code
    expect(not pcall(Link.fetch,client,url) and #values.requests==1,'HTTP failure followed or retried')
end
client,values=fixture();values.switch=true
expect(not pcall(Link.fetch,client,url),'changed credentials accepted response')
client,values=fixture();values.oversize=true
expect(not pcall(Link.fetch,client,url),'oversized reader accepted')
client,values=fixture()
expect(not pcall(Link.fetch,client,'https://evil.test') and #values.requests==0,'invalid URL performed HTTP')
print(('reader_link_spec: %d checks'):format(checks))
