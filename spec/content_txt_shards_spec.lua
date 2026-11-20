package.path = './?.lua;./?/init.lua;' .. package.path

local Content = require('weread.lib.content')
local checks = 0
local function expect(value, message) checks=checks+1;assert(value,message) end
local t0='9E454E3735F6C2718DD5C2693CA66CC50T25lIsa5bnRoZXiBYjWUdCQgbGluZS4'
local t1='E5E7BC3E936780D5CEDC568EF50D3C8AKQW5vdGhlcyBkaXN0aW5RpFBHNW5lLgo'
local complete='4684D80B72CE56D52C1BC9B152F554720T25lIsa5bnRoZXiBYjWUdCQgbGluZS4KQW5vdGhlcyBkaXN0aW5RpFBHNW5lLgo'
local plain='One synthetic TXT line.\nAnother distinct line.\n'
local book={book_id='900001',psvts='synthetic',_content_format='txt'}
local chapter={chapterUid=1}
local cached=0
Content.cache_annotation_source=function(_settings,_book,_chapter,text,is_raw)
    expect(text==plain and is_raw==true,'incorrect source cached');cached=cached+1
end
local function client(first,second,code,raise)
    local requests={}
    local value={json_encode=function() return '{}' end}
    function value:request(options)
        local suffix=options.url:match('/([^/]+)$');requests[#requests+1]=suffix
        if suffix=='t_0' then return first,200 end
        assert(suffix=='t_1')
        if raise then error('synthetic transport failure') end
        return second,code
    end
    return value,requests
end
local both,requests=client(t0,t1,200)
local rendered,source=Content.fetch_txt_as_xhtml(both,{},book,chapter)
expect(source and source.raw==plain and source.format=='web_txt','two TXT shards did not reproduce source')
expect(rendered:find('Another distinct line.',1,true) and #requests==2 and cached==1,'complete TXT not rendered')
for _,second in ipairs({'{}','',require('weread.lib.crypto').md5_hex(''):upper()}) do
    local before=cached
    local result,receipt=Content.fetch_txt_as_xhtml(client(complete,second,200),{},book,chapter)
    expect(result and receipt and receipt.raw==plain and cached==before+1,'explicitly empty second shard was rejected')
end
for _,case in ipairs({{second='{}',code=401},{second='{}',code=429},{second='{}',code=503},
                       {second='',code=nil},{second='',code=200,raise=true},
                       {second='{"errcode":-1}',code=200},{second=string.rep('F',32),code=200},
                       {second=string.rep('F',32)..'bad',code=200}}) do
    local before=cached
    local ok=pcall(Content.fetch_txt_as_xhtml,client(t0,case.second,case.code,case.raise),{},book,chapter)
    expect(not ok and cached==before,'failed or invalid second shard was published')
end
for _,first in ipairs({'{}','',string.rep('F',32),'unsupported'}) do
    local bad_first,first_requests=client(first,t1,200)
    local previous=cached
    expect(not pcall(Content.fetch_txt_as_xhtml,bad_first,{},book,chapter) and cached==previous
        and #first_requests==1,'empty or malformed first shard was accepted')
end
book.cached_file='/synthetic/previous.epub';book.cached_chapters={['1']='/synthetic/previous.epub'}
Content.refresh_reader_state=function() end
local css_reads,publishes=0,0
Content.fetch_chapter_css=function() css_reads=css_reads+1 end
Content.save_chapter_epub=function() publishes=publishes+1 end
local before=cached
local ok=pcall(Content.fetch_chapter_epub,client(t0,'{}',503),{},book,chapter)
expect(not ok and cached==before and css_reads==0 and publishes==0,'failed TXT shard reached publication')
expect(book.cached_file=='/synthetic/previous.epub' and book.cached_chapters['1']=='/synthetic/previous.epub',
    'failed TXT shard replaced existing reading cache')
print(('content_txt_shards_spec: %d checks'):format(checks))
