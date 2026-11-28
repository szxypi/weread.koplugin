package.path='./?.lua;./?/init.lua;'..package.path
local Name=require('weread.lib.profile_account')
local n=0
local function expect(value,message) n=n+1;assert(value,message or ('check '..n)) end
expect(Name.project({vid=123,name='测试昵称'},'123')=='测试昵称')
expect(Name.project({userVid='123',name='Reader'},'123')=='Reader')
for _i,value in ipairs({
    {vid='999',name='Reader'}, {vid='123',userVid='999',name='Reader'},
    {name='Reader'}, {vid='123',name=''}, {vid='123',name=' \t'},
    {vid='123',name='bad\nname'}, {vid='123',name='\255'}, {vid='123',name=string.rep('a',257)},
    {vid='123',name='Reader',errcode=401}, {vid='123',name=123},
}) do expect(not Name.project(value,'123'),'invalid name or owner accepted') end
expect(Name.valid_name(string.rep('a',256)) and not Name.valid_name(string.rep('好',171)))
local selected={web={cookies={wr_vid='123',wr_skey='synthetic'}}}
local matches=true;Name.matches=function() return matches end
local response={vid='123',name='Updated'};local status=200;local data='synthetic';local request
local client={settings={},json_decode=function() return response end,request=function(_self,opts)
    request=opts;opts.sink(data);return nil,status
end}
expect(Name.fetch(client,selected)=='Updated')
expect(request.method=='GET' and request.url=='https://weread.qq.com/api/userInfo?userVid=123'
    and request.skip_cookie and not request.persist_response_cookies and request.sensitive and request.headers.Cookie)
status=401;expect(not Name.fetch(client,selected),'HTTP error accepted');status=200
data=string.rep('a',65537);expect(not Name.fetch(client,selected),'oversized response accepted');data='synthetic'
client.request=function(_self,opts) opts.sink(data);matches=false;return nil,200 end
expect(not Name.fetch(client,selected),'changed session accepted');matches=true
response={vid='123',userVid='124',name='Other'}
expect(not Name.fetch(client,selected),'conflicting owner accepted')
expect(not Name.fetch(client,{web={cookies={wr_vid='wrong'}}}),'invalid credential owner accepted')
print('profile_account_spec: '..n..' checks')
