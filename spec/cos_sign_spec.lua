package.path='./?.lua;'..package.path
local M=require('weread.lib.cos_sign')
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local function value()
    return {bucket='synthetic-12345',ObjectName='/prefix/example-book.txt',Response={ExpiredTime=1300,
        Credentials={TmpSecretId='synthetic-id',TmpSecretKey='synthetic-key',Token='synthetic-token'}}}
end
local valid=assert(M.prepare(value(),17,1000))
expect(valid.host=='synthetic-12345.cos.accelerate.myqcloud.com' and valid.path=='/prefix/example-book.txt','valid credential projection failed')
expect(M.MAX_SINGLE_BYTES==200*1024*1024 and M.prepare(value(),M.MAX_SINGLE_BYTES,1000)~=nil,'200 MiB limit not accepted')
for _,name in ipairs({'bucket','path','traversal','secret','expired','too_large','negative','boolean'}) do
    local sample=value();local size=17
    if name=='bucket' then sample.bucket='host.invalid' elseif name=='path' then sample.ObjectName='//unsafe'
    elseif name=='traversal' then sample.ObjectName='/prefix/../file' elseif name=='secret' then sample.Response.Credentials.Token=''
    elseif name=='expired' then sample.Response.ExpiredTime=1030 elseif name=='too_large' then size=M.MAX_SINGLE_BYTES+1
    elseif name=='negative' then size=-1 else sample.Response.ExpiredTime=true end
    expect(not M.prepare(sample,size,1000),'invalid credential accepted: '..name)
end
expect(not M.pathname('/a//b') and not M.pathname('/a?b') and not M.pathname('/a#b') and not M.pathname('/a\\b'),'unsafe path accepted')
local copy={};for key,item in pairs(valid) do copy[key]=item end;copy.host='attacker.invalid'
expect(not M.sign(copy),'foreign COS host accepted')
copy={};for key,item in pairs(valid) do copy[key]=item end;copy.path='/prefix/../other'
expect(not M.sign(copy),'changed object path accepted')
print('PASS: COS signing boundaries ('..checks..' checks)')
