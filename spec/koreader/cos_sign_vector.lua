-- Compare the real KOReader SHA/HMAC implementation with an independent
-- synthetic COS SDK vector. No account or network access.
require('setupkoenv')
package.path=assert(arg[1])..'/?.lua;'..package.path
local M=require('weread.lib.cos_sign')
local input=assert(M.prepare({bucket='synthetic-12345',ObjectName='/prefix/example-book.txt',Response={ExpiredTime=1700000300,
    Credentials={TmpSecretId='synthetic-id',TmpSecretKey='synthetic-key',Token='synthetic-token'}}},17,1700000000))
local signed=assert(M.sign(input))
assert(signed.url=='https://synthetic-12345.cos.accelerate.myqcloud.com/prefix/example-book.txt')
assert(signed.headers.Authorization=='q-sign-algorithm=sha1&q-ak=synthetic-id&q-sign-time=1700000000;1700000300'
    ..'&q-key-time=1700000000;1700000300&q-header-list=content-length;host;x-cos-security-token&q-url-param-list='
    ..'&q-signature=127e92ff67702f58765c060e886c87f666623ae8')
input=assert(M.prepare({bucket='synthetic-12345',ObjectName='/示例/书.txt',Response={ExpiredTime=1700000300,
    Credentials={TmpSecretId='synthetic-id',TmpSecretKey='synthetic-key',Token='synthetic+/=token'}}},17,1700000000))
signed=assert(M.sign(input))
assert(signed.url=='https://synthetic-12345.cos.accelerate.myqcloud.com/%E7%A4%BA%E4%BE%8B/%E4%B9%A6.txt')
assert(signed.headers.Authorization:match('q%-signature=(%x+)$')=='f0cf1aa839d0ac5b8ad4fee57a574c5280bf9239')
print('PASS: COS SDK signing vector')
