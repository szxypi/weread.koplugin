package.path='./?.lua;'..package.path
local Guard=require('spec.koreader.cb_initial_fixture_ui_guard')
local Protocol=require('weread.lib.protocol');local Cookie=require('weread.lib.cookie')
local Payload=require('weread.lib.cb_position_payload')
local checks=0;local function expect(value) checks=checks+1;assert(value,'check '..checks) end
local input={book='CB_Synthetic',chapter='11',owner='900000',chapter_idx=2,offset=45,armed=true,
    expected_summary='Synthetic first page',cookies={wr_vid='900000',wr_skey='synthetic-cookie'},native={accessToken='native-access'}}
local check=Guard.new(input,Protocol,Cookie);local current_body
local function decode() return current_body end
local function option(url,method,body)
    current_body=body;return {url=url,method=method or 'GET',body=body and 'encoded' or nil,
        headers={Cookie=Cookie.to_header(input.cookies)},sensitive=true,skip_cookie=true}
end
local base='https://weread.qq.com';local native='https://i.weread.qq.com/book/getProgress?bookId='..input.book
local read=option(native);read.headers={vid=input.owner,accessToken=input.native.accessToken}
expect(check(read,0,decode)=='read')
read.headers.accessToken='other';expect(not check(read,0,decode))
read.headers.accessToken=input.native.accessToken;read.url=native..'other';expect(not check(read,0,decode))
read.url=native;read.method='POST';expect(not check(read,0,decode))
for _i,url in ipairs({base..'/api/userInfo?userVid=900000',Protocol.reader_url(input.book),
    Protocol.reader_url(input.book,input.chapter),base..'/web/book/getProgress?bookId=CB_Synthetic',
    base..'/web/book/getProgress?bookId=CB_Synthetic&_=123'}) do expect(check(option(url),0,decode)=='read') end
expect(not check(option(base..'/web/book/getProgress?bookId=CB_Other'),0,decode))
expect(check(option(base..'/web/book/chapterInfos','POST',{bookIds={input.book}}),0,decode)=='read')
expect(not check(option(base..'/web/book/chapterInfos','POST',{bookIds={input.book,'CB_Other'}}),0,decode))
local txt=base..'/web/book/chapter/t_0'
local shard={b=Protocol.e(input.book),c=Protocol.e(input.chapter),sc=1}
expect(not check(option(txt,'POST',shard),0,decode))
input.source_format='web_txt';local txt_check=Guard.new(input,Protocol,Cookie)
expect(txt_check(option(txt,'POST',shard),0,decode)=='read')
shard.b=Protocol.e('CB_Other');expect(not txt_check(option(txt,'POST',shard),0,decode));shard.b=Protocol.e(input.book)
shard.c=Protocol.e('12');expect(not txt_check(option(txt,'POST',shard),0,decode));shard.c=Protocol.e(input.chapter)
local payload=Payload.build('enter',{book_id=input.book,chapter_uid=input.chapter,chapter_idx=input.chapter_idx,
    chapter_offset=input.offset,progress=37,summary=input.expected_summary,psvts='synthetic-ps',pclts='synthetic-pc',token='synthetic-token'})
local url=base..'/web/book/read'
expect(check(option(url,'POST',payload),0,decode)=='write')
expect(not check(option(url,'POST',payload),1,decode))
input.armed=false;expect(not check(option(url,'POST',payload),0,decode));input.armed=true
local altered={};for key,value in pairs(payload) do altered[key]=value end
altered.co=46;expect(not check(option(url,'POST',altered),0,decode))
altered.co=45;altered.sm='other';expect(not check(option(url,'POST',altered),0,decode))
altered.sm=input.expected_summary;altered.rt=0;expect(not check(option(url,'POST',altered),0,decode))
local wrong=option(url,'POST',payload);wrong.headers.Cookie='wrong';expect(not check(wrong,0,decode))
expect(not check(option('https://weread.qq.com/web/shelf/delete','POST',payload),0,decode))
print(('cb_initial_fixture_ui_guard_spec: %d checks'):format(checks))
