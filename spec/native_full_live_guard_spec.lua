package.path='./?.lua;./?/init.lua;'..package.path
local protocol=require('weread.lib.protocol')
local credentials={vid='12345678',accessToken='test-token'}
local chapter={{chapterUid='42'},{chapterUid='43'}}
local inputs={
    valid={b=protocol.e('123'),c=protocol.e('42')},
    wrong_book={b=protocol.e('124'),c=protocol.e('42')},
    wrong_chapter={b=protocol.e('123'),c=protocol.e('44')},
    extra={b=protocol.e('123'),c=protocol.e('42'),write=true},
    catalog={bookIds={'123'},synckeys={0},updateTimes={0},maxfreeIdx={0}},
    wrong_catalog={bookIds={'124'},synckeys={0},updateTimes={0},maxfreeIdx={0}},
}
local guard=require('spec.helpers.native_full_live_guard').new('123',7,chapter,credentials,protocol,
    function(value) return inputs[value] end,function(url)
        return url=='https://img.example.test/safe' and url or nil
    end)
local checks=0
local function check(condition) checks=checks+1;assert(condition) end
check(guard{url=protocol.reader_url('123'),method='GET'})
check(guard{url=protocol.reader_url('123','42'),method='GET'})
check(not guard{url=protocol.reader_url('123','44'),method='GET'})
local endpoint='https://weread.qq.com/web/book/chapter/e_0'
check(guard{url=endpoint,method='POST',body='valid'})
check(not guard{url=endpoint,method='POST',body='valid',headers={accessToken='not-allowed'}})
check(not guard{url=protocol.reader_url('123'),method='GET',headers={Cookie='not-allowed'}})
for _,key in ipairs({'wrong_book','wrong_chapter','extra','unknown'}) do
    check(not guard{url=endpoint,method='POST',body=key})
end
check(not guard{url='https://weread.qq.com/web/book/read',method='POST',body='valid'})
local headers={vid=credentials.vid,accessToken=credentials.accessToken}
local options={method='POST',url='https://i.weread.qq.com/book/chapterInfos',body='catalog',headers=headers,
    skip_cookie=true,persist_response_cookies=false,sensitive=true}
check(guard(options));options.body='wrong_catalog';check(not guard(options))
options.body='catalog';options.skip_cookie=false;check(not guard(options));options.skip_cookie=true
options.url='https://i.weread.qq.com/shelf/add';check(not guard(options))
local download='https://i.weread.qq.com/book/chapterdownload?bookId=123&chapters=0%2C42&bookType=epub&bookVersion=7'
    ..'&pf=wechat_wx-2001-android-100-weread&pfkey=pfKey&zoneId=1&quote=&release=1&stopAutoPayWhenBNE=1'
    ..'&preload=2&preview=0&offline=1'
local request={url=download,method='GET',headers=headers,skip_cookie=true,persist_response_cookies=false,sensitive=true}
check(guard(request))
request.url=download:gsub('stopAutoPayWhenBNE=1','stopAutoPayWhenBNE=0');check(not guard(request))
request.url=download:gsub('0%%2C42','0%%2C44');check(not guard(request))
request.url=download;request.headers={vid=credentials.vid,accessToken=credentials.accessToken,Cookie='not-allowed'}
check(not guard(request))
check(guard{url='https://img.example.test/safe',method='GET',headers={Accept='image/*'},skip_cookie=true,diagnostic_api='native_chapter_image',
    persist_response_cookies=false,sensitive=true})
check(not guard{url='https://img.example.test/safe',method='GET',headers={vid=credentials.vid,Accept='image/*'},skip_cookie=true,diagnostic_api='native_chapter_image',
    persist_response_cookies=false,sensitive=true})
check(not guard{url='https://img.example.test/other',method='GET',headers={Accept='image/*'},skip_cookie=true,diagnostic_api='native_chapter_image',
    persist_response_cookies=false,sensitive=true})
print(('native_full_live_guard_spec: %d checks'):format(checks))
