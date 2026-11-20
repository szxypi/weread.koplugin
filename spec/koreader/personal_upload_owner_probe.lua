-- Narrowly scoped native upload executor for a single synthetic book.
-- All input and the returned book ID travel over a private host pipe.
require('ffi').log=function() end
require('setupkoenv')
package.path=assert(arg[1])..'/?.lua;'..package.path
local json=require('json')
local lfs=require('libs/libkoreader-lfs')
local input=json.decode(assert(io.stdin:read('*l')))
local root=assert(os.getenv('WEREAD_UPLOAD_PROBE_ROOT'))
assert(root:match('^/dev/shm/weread%-native%-upload%-[a-f0-9]+$') and #root<128)
assert(lfs.mkdir(root))
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(root..'/settings.reader.lua')
local mock=tonumber(os.getenv('WEREAD_UPLOAD_MOCK_PORT') or '')
local name=input.name
assert(type(name)=='string' and (mock and name=='SyntheticUpload.txt' or name:match('^KOReaderSynthetic%-[a-f0-9]+%.txt$') and #name==38))
local body='Synthetic upload for KOReader.\n'
local path=root..'/'..name;local file=assert(io.open(path,'wb'));assert(file:write(body));file:close()
local scope={vid=input.credentials.vid,epoch=1}
assert(type(scope.vid)=='string' and scope.vid:match('^[1-9]%d*$'))
local settings={data_dir=root,auth_scope_matches=function(_self,value) return value and value.vid==scope.vid and value.epoch==1 end,
    get_auth_scope=function() return scope end}
if mock then
    assert(mock>=1 and mock<=65535 and input.credentials.vid=='900000' and input.credentials.accessToken=='mock-native-access')
    settings.mock_endpoint='http://127.0.0.1:'..mock
end
local store={read=function() return input.credentials,1,nil,false end}
local Access=require('weread.lib.native_read_access');local selected=assert(Access.capture(settings,store))
local Client=require('weread.lib.client');local client=Client:new(settings)
local Journal=require('weread.lib.personal_upload_journal');local journal=Journal:new(settings,client)
local Task=require('weread.lib.personal_upload');local captured=assert(Task.capture(path))
local record=assert(journal:begin(scope,path,#body))
local protocol=require('weread.lib.protocol');local Cos=require('weread.lib.cos_sign')
local base='https://i.weread.qq.com';local temporary;local counts={shelf=0,credential=0,put=0,notify=0,denied=0}
local Auth=require('weread.lib.native_authorization');local old_auth=Auth._request
function Auth:_request(stage,...)
    local value=old_auth(self,stage,...)
    if stage=='personal_upload_credential' then assert(not temporary);temporary=value end
    return value
end
local request=Client.request
function Client:request(opts)
    local h=opts.headers or {};local kind
    if opts.sensitive and opts.skip_cookie and opts.persist_response_cookies==false and h.Cookie==nil then
        if opts.method=='GET' and opts.body==nil and h.vid==scope.vid and h.accessToken==input.credentials.accessToken then
            if opts.url==base..'/shelf/sync' then kind='shelf'
            elseif opts.url==base..'/cos/getcredential?name='..protocol.urlencode(captured.stem)..'&from=' then kind='credential' end
        elseif temporary and opts.method=='PUT' and opts.body==nil then
            local prepared=assert(Cos.prepare(temporary,#body,os.time()));local signed=assert(Cos.sign(prepared))
            if opts.url==signed.url and h.Host==signed.headers.Host and h['Content-Length']==tostring(#body)
                and h['x-cos-security-token']==signed.headers['x-cos-security-token'] and type(h.Authorization)=='string'
                and h.vid==nil and h.accessToken==nil and type(opts.source)=='function' then kind='put' end
        elseif temporary and opts.method=='POST' and h.vid==scope.vid and h.accessToken==input.credentials.accessToken
            and opts.url==base..'/cos/notify?name='..protocol.urlencode(name)..'&path='..protocol.urlencode(temporary.ObjectName)..'&cancel=0'
            and opts.body=='{}' then kind='notify' end
    end
    if not kind or kind=='shelf' and counts.shelf>=8 or kind~='shelf' and counts[kind]>=1
        or not journal:owns(scope,record) then counts.denied=counts.denied+1;error('probe/denied',0) end
    counts[kind]=counts[kind]+1
    if kind=='put' then
        local source=opts.source;local sent=''
        opts.source=function()
            local part,err=source();if part then sent=sent..part;assert(body:sub(1,#sent)==sent) else assert(sent==body) end
            return part,err
        end
    end
    return request(self,opts)
end
local accepted=pcall(client.request,client,{url=base..'/login',method='POST',body='{}',headers={vid=scope.vid,
    accessToken=input.credentials.accessToken},sensitive=true,skip_cookie=true,persist_response_cookies=false})
assert(not accepted and counts.denied==1);counts.denied=0
local ok,result=pcall(Task.run,client,settings,selected,captured,journal,record,function() return true end)
local output={kind=ok and result.kind or 'error',counts=counts}
if ok and result.kind=='confirmed' then output.target=result.book_id end
os.remove(path);os.remove(journal:path(scope));os.remove(journal:path(scope)..'.lock');lfs.rmdir(root)
print('WEREAD_UPLOAD_PROBE='..json.encode(output))
