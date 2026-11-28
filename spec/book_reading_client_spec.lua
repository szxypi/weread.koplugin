package.path='./?.lua;'..package.path
local Protocol=require('weread.lib.protocol')
local Model=require('weread.lib.book_reading_client')
local book={book_id='900001'}
local chapter={chapterUid='2'}
local code,decoded=401
local response_headers,merged,last_request={},0,nil
local client={settings={get_auth_scope=function() return {vid='900000'} end,
    get=function() return {wr_vid='900000',wr_skey='valid-cookie'} end,
    merge_set_cookie=function(_,value) assert(value=='synthetic=new');merged=merged+1 end},
    request=function(_,options) last_request=options;return 'private-body',code,response_headers,'status' end,
    json_decode=function() return decoded end}
local scoped=Model.wrap(client,book,chapter)
local function check(options,expired)
    local ok,value,status=pcall(scoped.request,scoped,options)
    if expired then assert(not ok and value=='book_reading/web_expired','scoped 401 not classified')
    else assert(ok and value=='private-body' and status==code,'unrelated response was classified or changed') end
end
check({url=Protocol.reader_url(book.book_id)},true)
check({url=Protocol.reader_url(book.book_id,chapter.chapterUid)},true)
check({url=Protocol.reader_url('900002')},false)
check({url='https://weread.qq.com/web/reader/foreign'},false)
decoded={bookIds={'900001'}}
check({url='https://weread.qq.com/web/book/chapterInfos',body='{}'},true)
decoded={bookIds={'900001'},extra=true}
check({url='https://weread.qq.com/web/book/chapterInfos',body='{}'},false)
decoded={bookIds={'900001',other=true}}
check({url='https://weread.qq.com/web/book/chapterInfos',body='{}'},false)
decoded={b=Protocol.e('900001'),c=Protocol.e('2')}
for _,suffix in ipairs({'e_0','e_1','e_2','e_3','t_0','t_1'}) do
    check({url='https://weread.qq.com/web/book/chapter/'..suffix,body='{}'},true)
end
decoded={b=Protocol.e('900001'),c=Protocol.e('3')}
check({url='https://weread.qq.com/web/book/chapter/e_0',body='{}'},false)
local second=Model.wrap(client,book,{chapterId='3'})
local second_ok,second_error=pcall(second.request,second,{url='https://weread.qq.com/web/book/chapter/e_0',body='{}'})
assert(not second_ok and second_error=='book_reading/web_expired','current chapterId was not scoped')
check({url='https://weread.qq.com/web/book/read',body='{}'},false)
check({url='https://weread.qq.com/web/book/chapter/e_0',body=string.rep('x',16385)},false)
for _,status in ipairs({200,403,429,500}) do code=status;check({url=Protocol.reader_url(book.book_id)},false) end
code=401;response_headers={['Set-Cookie']='synthetic=new'}
local options={url=Protocol.reader_url(book.book_id)}
check(options,true)
assert(merged==0 and options.persist_response_cookies==nil and last_request.persist_response_cookies==false,
    'failed scoped request committed response cookies or modified its caller')
code=200;check(options,false)
assert(merged==1,'successful scoped request dropped its response cookies')
options.persist_response_cookies=false;check(options,false)
assert(merged==1,'explicit no-cookie request persisted a response cookie')
options.persist_response_cookies=nil
for _,foreign in ipairs({'wr_vid=900099; Path=/','wr_skey=; Path=/'}) do
    response_headers={['set-cookie']=foreign}
    local accepted,reason=pcall(scoped.request,scoped,options)
    assert(not accepted and reason=='book_reading/session_changed' and merged==1,
        'successful response changed the owner or erased the login')
end
response_headers={['Set-Cookie']='synthetic=new'}
client.settings.mock_endpoint='http://127.0.0.1:1';options.persist_response_cookies=nil;check(options,false)
assert(merged==1,'mock response cookies escaped the mock boundary')
assert(client.book_reading_auth_classification==nil and scoped.book_reading_auth_classification)
print('book_reading_client_spec: scoped 401 classification passed')
