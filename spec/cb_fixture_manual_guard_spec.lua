package.path='./?.lua;'..package.path
local Guard=require('spec.koreader.cb_fixture_manual_guard')
local Protocol=require('weread.lib.protocol');local Cookie=require('weread.lib.cookie')
local Payload=require('weread.lib.cb_position_payload')
local n=0;local function expect(value) n=n+1;assert(value,'check '..n) end
local input={book='CB_Synthetic',chapter='11',owner='900000',chapter_idx=2,next_offset=45,
    expected_summary='Synthetic fixture text',cookies={wr_vid='900000',wr_skey='synthetic-cookie'}}
local check=Guard.new(input,Protocol,Cookie)
local headers={Cookie=Cookie.to_header(input.cookies)}
local current_body
local function decode() return current_body end
local function option(url,method,body)
    current_body=body;return {url=url,method=method or 'GET',body=body and 'encoded' or nil,headers=headers,
        sensitive=true,skip_cookie=true}
end
local base='https://weread.qq.com'
for _i,url in ipairs({base..'/api/userInfo?userVid=900000',Protocol.reader_url(input.book),
    Protocol.reader_url(input.book,input.chapter),base..'/web/book/getProgress?bookId=CB_Synthetic',
    base..'/web/book/getProgress?bookId=CB_Synthetic&_=123'}) do
    expect(check(option(url),0,decode)=='read')
end
expect(not check(option(base..'/web/book/getProgress?bookId=CB_Other'),0,decode))
expect(check(option(base..'/web/book/chapterInfos','POST',{bookIds={input.book}}),0,decode)=='read')
expect(not check(option(base..'/web/book/chapterInfos','POST',{bookIds={input.book,'CB_Other'}}),0,decode))
expect(check(option(base..'/web/book/chapter/e_0','POST',{b=Protocol.e(input.book),c=Protocol.e(input.chapter),sc=1}),0,decode)=='read')
expect(not check(option(base..'/web/book/chapter/e_0','POST',{b=Protocol.e(input.book),c=Protocol.e('12'),sc=1}),0,decode))
local args={book_id=input.book,chapter_uid=input.chapter,chapter_idx=input.chapter_idx,chapter_offset=input.next_offset,
    progress=37,summary=input.expected_summary,psvts='synthetic-ps',pclts='synthetic-pc',token='synthetic-token'}
local enter=Payload.build('enter',args);local read=Payload.build('position',args)
local url=base..'/web/book/read'
expect(check(option(url,'POST',enter),0,decode)=='write')
expect(check(option(url,'POST',read),1,decode)=='write')
expect(not check(option(url,'POST',enter),1,decode) and not check(option(url,'POST',read),2,decode))
local changed={};for k,v in pairs(read) do changed[k]=v end;changed.co=46
expect(not check(option(url,'POST',changed),1,decode))
changed.co=45;changed.sm='different';expect(not check(option(url,'POST',changed),1,decode))
input.timer=true;input.first_offset=44;input.timer_summary='Synthetic prior text';check=Guard.new(input,Protocol,Cookie)
local prior={};for key,value in pairs(args) do prior[key]=value end
prior.chapter_offset=input.first_offset;prior.summary=input.timer_summary
local timed=Payload.build('position',prior)
expect(check(option(url,'POST',enter),0,decode)=='write')
expect(check(option(url,'POST',read),1,decode)=='write')
expect(check(option(url,'POST',timed),2,decode)=='write')
expect(not check(option(url,'POST',read),2,decode) and not check(option(url,'POST',timed),3,decode))
expect(not check(option(url,'POST',enter),2,decode))
print('cb_fixture_manual_guard_spec: '..n..' checks')
