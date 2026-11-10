package.path='./?.lua;'..package.path
local Data=require('weread.lib.my_cloud_marks')
local Auth=require('weread.lib.native_authorization')
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local null,array={},{}
local client={json_decode=function(_self,value) if value=='null' then return null end;return setmetatable({},array) end}
local function rows(value) return setmetatable(value or {},array) end
local function source()
    return {bookId='900001',updated=rows{{bookmarkId='synthetic-mark',bookId='900001',vid='900000',markText='合成引用\n第二行',
        abstract='摘要',range='12-23',chapterUid=7,type=1,style=1,createTime=123,token='discard'}},
        chapters=rows{{chapterUid=7,title='合成章节'}},accessToken='discard'}
end
local value=Data.project(client,source(),'900001','900000',1000)
expect(#value.updated==1 and value.updated[1].markText=='合成引用\n第二行' and value.chapters[1].title=='合成章节','own quote/chapters lost')
expect(not value.updated[1].vid and not value.updated[1].bookId and not value.updated[1].token and not value.accessToken,'private extras retained')
expect(Data.validate(client,value,'900001').updated[1].range=='12-23','display range lost')
expect(#Data.project(client,{updated=rows()},'900001',nil,1).updated==0,'empty response rejected')
local function reject(raw) expect(not pcall(Data.project,client,raw,'900001','900000',1),'invalid source accepted') end
for _,key in ipairs({'bookId','vid','hasMore','errcode','succ','updated','chapters'}) do
    local raw=source();raw[key]=({bookId='900002',vid='900002',hasMore=1,errcode=false,succ=false,updated={},chapters=null})[key];reject(raw)
end
for _,case in ipairs({{'bookmarkId','bad id'},{'bookId','900002'},{'vid','900002'},{'markText','x\0'},
    {'markText',string.rep('x',131073)},{'markText','\255'},{'chapterUid',true},{'type',-1},{'range',33},{'createTime',math.huge}}) do
    local raw=source();raw.updated[1][case[1]]=case[2];reject(raw)
end
local raw=source();raw.updated[2]=raw.updated[1];reject(raw)
raw=source();raw.chapters[2]=raw.chapters[1];reject(raw)
raw=source();raw.updated[3]=raw.updated[1];reject(raw)
raw=source();raw.updated=rows();for i=1,5001 do raw.updated[i]={bookmarkId='synthetic-'..i} end;reject(raw)
for _,id in ipairs({'0','CB_Synthetic','900001&x=1',string.rep('9',21)}) do
    expect(not pcall(Data.project,client,source(),id,'900000',1),'invalid identity accepted')
end
for _,now in ipairs({0,true,0/0,math.huge}) do expect(not pcall(Data.project,client,source(),'900001','900000',now),'invalid time accepted') end
-- Native grant and transport isolation, stale replies, one GET, no fallback.
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
local result=Data.fetch(client,'900001',selected,{now=1000})
expect(result.fetched_at==1000 and #calls==1,'native fetch did not project exactly once')
local request=calls[1]
expect(request.url=='https://i.weread.qq.com/book/bookmarklist?bookId=900001&synckey=0' and request.method=='GET' and request.body==nil,'own marks route changed')
expect(request.sensitive and request.skip_cookie and not request.persist_response_cookies and request.headers.accessToken=='synthetic-access'
    and not request.headers.Cookie and not request.headers.Authorization,'native transport leaked credentials')
revision=2
expect(not Data.matches(settings,selected) and not pcall(Data.fetch,client,'900001',selected) and #calls==1,'stale grant sent HTTP')
selected=Data.capture(settings,store);change=true
expect(not pcall(Data.fetch,client,'900001',selected),'grant changed during HTTP accepted')
change=false;selected=Data.capture(settings,store);code=401
local ok,err=pcall(Data.fetch,client,'900001',selected,{recover_auth=true})
expect(not ok and err=='my_marks/native_expired','explicit expiry not passed to parent recovery')
for _,status in ipairs({403,404,429,500}) do
    code=status;ok,err=pcall(Data.fetch,client,'900001',selected,{recover_auth=true})
    expect(not ok and err=='my_marks/unavailable','non401 failure caused renewal or raw error')
end
local auth=Auth:new(client,{expected_vid='900000'});local count=#calls
expect(not pcall(auth.read_my_cloud_marks,auth,{vid='900002',accessToken='synthetic'},'900001') and #calls==count,'wrong owner sent request')
valid=false
expect(not pcall(Data.fetch,client,'900001',selected) and #calls==count,'signed-out native request sent')
print('PASS: own cloud mark projection and isolated read transport ('..checks..' checks)')
