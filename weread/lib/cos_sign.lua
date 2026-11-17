-- Tencent COS REST PUT signing. The caller owns credential and request lifetimes.
-- Protocol: https://cloud.tencent.com/document/api/436/7778
local Protocol=require('weread.lib.protocol')
local M={MAX_SINGLE_BYTES=8*1024*1024}
local function token(value,max)
    return type(value)=='string' and #value>0 and #value<=max and not value:find('[^!-~]')
end
local function integer(value,min,max)
    return type(value)=='number' and value==value and value%1==0 and value>=min and value<=max
end
local function pathname(value)
    if type(value)~='string' or #value<1 or #value>2048 or value:find('[%z%c%s\\?#]')
        or Protocol.utf8_substr(value,#value+1)~=value then return nil end
    value=value:gsub('^/','')
    if value=='' or value:sub(1,1)=='/' or value:find('//',1,true) or value:sub(-1)=='/' then return nil end
    for segment in value:gmatch('[^/]+') do if segment=='.' or segment=='..' then return nil end end
    return '/'..value
end
M.pathname=pathname
function M.prepare(value,size,now)
    if type(value)~='table' or not integer(size,1,M.MAX_SINGLE_BYTES) or not integer(now,1,4102444800) then return nil end
    local response=value.Response;local creds=type(response)=='table' and response.Credentials
    local bucket,key=value.bucket,pathname(value.ObjectName)
    local appid=type(bucket)=='string' and bucket:match('%-(%d+)$')
    if type(bucket)~='string' or #bucket>128 or not bucket:match('^[a-z0-9][a-z0-9%-]*%-%d+$')
        or not appid or #appid>20 or not key or type(creds)~='table' or not token(creds.TmpSecretId,4096)
        or not creds.TmpSecretId:match('^[A-Za-z0-9_%-]+$') or not token(creds.TmpSecretKey,4096) or not token(creds.Token,8192)
        or not integer(response.ExpiredTime,now+31,now+86400) then return nil end
    local expires=math.min(now+900,response.ExpiredTime)
    return {host=bucket..'.cos.accelerate.myqcloud.com',path=key,size=size,start=now,expires=expires,
        secret_id=creds.TmpSecretId,secret_key=creds.TmpSecretKey,token=creds.Token}
end
function M.sign(input)
    local appid=type(input)=='table' and type(input.host)=='string' and input.host:match('%-(%d+)%.cos%.accelerate%.myqcloud%.com$')
    if type(input)~='table' or type(input.host)~='string' or not input.host:match('^[a-z0-9][a-z0-9%-]*%-%d+%.cos%.accelerate%.myqcloud%.com$')
        or not appid or #appid>20 or not pathname(input.path) or pathname(input.path)~=input.path or not integer(input.size,1,M.MAX_SINGLE_BYTES)
        or not integer(input.start,1,4102444800) or not integer(input.expires,input.start+1,input.start+900)
        or not token(input.secret_id,4096) or not input.secret_id:match('^[A-Za-z0-9_%-]+$')
        or not token(input.secret_key,4096) or not token(input.token,8192) then return nil end
    local sha=require('ffi/sha2')
    local key_time=string.format('%.0f;%.0f',input.start,input.expires)
    local headers='content-length='..input.size..'&host='..Protocol.urlencode(input.host)
        ..'&x-cos-security-token='..Protocol.urlencode(input.token)
    local http='put\n'..input.path..'\n\n'..headers..'\n'
    local signing='sha1\n'..key_time..'\n'..sha.sha1(http)..'\n'
    local key=sha.hmac(sha.sha1,input.secret_key,key_time)
    local signature=sha.hmac(sha.sha1,key,signing)
    local authorization='q-sign-algorithm=sha1&q-ak='..input.secret_id..'&q-sign-time='..key_time..'&q-key-time='..key_time
        ..'&q-header-list=content-length;host;x-cos-security-token&q-url-param-list=&q-signature='..signature
    local encoded=input.path:gsub('[^/]+',function(segment) return Protocol.urlencode(segment) end)
    return {url='https://'..input.host..encoded,headers={Host=input.host,['Content-Length']=tostring(input.size),
        Authorization=authorization,['x-cos-security-token']=input.token}}
end
return M
