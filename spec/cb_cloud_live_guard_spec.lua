package.path='./?.lua;'..package.path
local Guard=require('spec.koreader.cb_cloud_live_guard')
local Protocol=require('weread.lib.protocol');local Cookie=require('weread.lib.cookie')
local input={book='CB_Synthetic',chapter='7',cookies={wr_vid='1',wr_skey='synthetic'}}
local check=Guard.new(input,Protocol,Cookie,10)
local header={Cookie=Cookie.to_header(input.cookies)}
local progress='https://weread.qq.com/web/book/getProgress?bookId='..Protocol.urlencode(input.book)
local reader=Protocol.reader_url(input.book,input.chapter)
local urls={progress,reader,'https://weread.qq.com/web/book/chapter/e_0','https://weread.qq.com/web/book/chapter/e_1',
    'https://weread.qq.com/web/book/chapter/e_3',progress}
local function decode(value) return value end
local checks=0
local function expect(value) checks=checks+1;assert(value) end
for i,url in ipairs(urls) do
    local post=i>=3 and i<=5
    local option={method=post and 'POST' or 'GET',url=url,sensitive=true,skip_cookie=true,persist_response_cookies=false,
        headers=header,body=post and {b=Protocol.e(input.book),c=Protocol.e(input.chapter)} or nil}
    expect(check(option,i-1,11,decode,false))
    expect(not check(option,i-1,10,decode,false))
    expect(not check(option,i-1,11,decode,true))
    expect(not check(option,6,11,decode,false))
    local old=option.url;option.url='https://weread.qq.com/web/book/read';expect(not check(option,i-1,11,decode,false));option.url=old
    old=option.headers;option.headers={Cookie='foreign'};expect(not check(option,i-1,11,decode,false));option.headers=old
    old=option.method;option.method=post and 'GET' or 'POST';expect(not check(option,i-1,11,decode,false));option.method=old
    if post then
        old=option.body.c;option.body.c=Protocol.e('8');expect(not check(option,i-1,11,decode,false));option.body.c=old
        old=option.body.b;option.body.b=Protocol.e('CB_Other');expect(not check(option,i-1,11,decode,false));option.body.b=old
    end
end
input.owner='1';input.source_preview=true
check=Guard.new(input,Protocol,Cookie,10)
local account='https://weread.qq.com/api/userInfo?userVid=1'
local catalog='https://weread.qq.com/web/book/chapterInfos'
local tail={account,catalog,reader,urls[3],urls[4],urls[5],catalog,account}
for i,url in ipairs(tail) do
    local post=i==2 or i==4 or i==5 or i==6 or i==7
    local body=post and ((i==2 or i==7) and {bookIds={input.book}} or {b=Protocol.e(input.book),c=Protocol.e(input.chapter)}) or nil
    local option={method=post and 'POST' or 'GET',url=url,sensitive=true,skip_cookie=true,persist_response_cookies=false,headers=header,body=body}
    expect(check(option,i+5,11,decode,false))
    expect(not check(option,i+5,10,decode,false))
    expect(not check(option,i+5,11,decode,true))
    expect(not check(option,14,11,decode,false))
    if i==2 or i==7 then
        option.body={bookIds={'CB_Other'}};expect(not check(option,i+5,11,decode,false))
        option.body={bookIds={input.book},extra=true};expect(not check(option,i+5,11,decode,false))
        option.body=false;expect(not check(option,i+5,11,decode,false))
    end
end
print('cb_cloud_live_guard_spec: '..checks..' checks')
