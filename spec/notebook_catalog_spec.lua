package.path='./?.lua;'..package.path
local Data=require('weread.lib.notebook_catalog')
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local null,array={},{}
local client={json_decode=function(_self,value) if value=='null' then return null end;return setmetatable({},array) end}
local function rows(value) return setmetatable(value or {},array) end
local function source()
    return {books=rows{{bookId='900001',book={bookId='900001',title='合成书籍',author='作者',token='discard'},
        noteCount=2,reviewCount=1,bookmarkCount=0,sort=100,token='discard'}},totalBookCount=1,token='discard'}
end
local value=Data.project(client,source(),1000)
expect(#value.books==1 and value.books[1].title=='合成书籍' and value.books[1].noteCount==2,'projection lost data')
expect(not value.token and not value.books[1].token and value.schema==1,'projection retained extra fields')
expect(Data.validate(client,value).books[1].bookId=='900001','snapshot cannot be reopened')
expect(#Data.project(client,{books=rows(),totalBookCount=0},1000).books==0,'empty list rejected')
local function reject(raw) expect(not pcall(Data.project,client,raw,1000),'invalid source accepted') end
for _,case in ipairs({{'totalBookCount',2},{'hasMore',1},{'errcode',false},{'succ',false},{'books',{}},{'books',null}}) do
    local raw=source();raw[case[1]]=case[2];reject(raw)
end
for _,case in ipairs({{'bookId','900002'},{'noteCount',true},{'sort',math.huge}}) do
    local raw=source();raw.books[1][case[1]]=case[2];reject(raw)
end
for _,case in ipairs({{'bookId','900002'},{'title','x\0'},{'title','\255'},{'author',true}}) do
    local raw=source();raw.books[1].book[case[1]]=case[2];reject(raw)
end
local raw=source();raw.books[2]=raw.books[1];raw.totalBookCount=2;reject(raw)
raw=source();raw.books=rows();for i=1,5001 do raw.books[i]={} end;raw.totalBookCount=5001;reject(raw)
local scope,revision,valid={vid='900000',epoch=1},1,true
local credentials={vid='900000',accessToken='synthetic-access',refreshToken='synthetic-refresh',deviceId=string.rep('1',32)}
local settings={get_auth_scope=function() return scope end,auth_scope_matches=function(_self,v) return valid and v==scope end}
local store={read=function() return credentials,revision end}
local calls,code,change={},200,false
client.settings=settings
client.request=function(_self,options) calls[#calls+1]=options;if change then revision=revision+1 end;return 'fixture',code end
local decode=client.json_decode
client.json_decode=function(self,bytes) return bytes=='fixture' and source() or decode(self,bytes) end
local selected=Data.capture(settings,store)
local result=Data.fetch(client,selected,{now=1000})
expect(result.fetched_at==1000 and #calls==1,'native fetch did not project once')
local request=calls[1]
expect(request.url=='https://i.weread.qq.com/user/notebooks?count=100' and request.method=='GET' and request.body==nil,'incorrect route')
expect(request.sensitive and request.skip_cookie and not request.persist_response_cookies and request.headers.accessToken=='synthetic-access'
    and not request.headers.Cookie and not request.headers.Authorization,'native transport leaked credentials')
revision=2;expect(not Data.matches(settings,selected) and not pcall(Data.fetch,client,selected) and #calls==1,'stale grant sent HTTP')
selected=Data.capture(settings,store);change=true;expect(not pcall(Data.fetch,client,selected),'grant changed during HTTP accepted')
change=false;selected=Data.capture(settings,store);code=401
local ok,err=pcall(Data.fetch,client,selected,{recover_auth=true})
expect(not ok and err==Data.EXPIRED,'401 did not signal recovery')
for _,status in ipairs({403,404,429,500}) do
    code=status;ok,err=pcall(Data.fetch,client,selected,{recover_auth=true})
    expect(not ok and err=='notebooks/unavailable','non401 failure caused recovery')
end
valid=false;local count=#calls;expect(not pcall(Data.fetch,client,selected) and #calls==count,'signed-out request sent')
print('PASS: notebook projection and native transport ('..checks..' checks)')
