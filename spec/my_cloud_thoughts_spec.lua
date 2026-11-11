package.path='./?.lua;'..package.path
local Data=require('weread.lib.my_cloud_thoughts')
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local null,mt={},{}
local function array(value) return setmetatable(value or {},mt) end
local client={json_decode=function(_self,value) return value=='null' and null or array() end}
local function source(count,total)
    local rows=array();for i=1,(count or 3) do rows[i]={reviewId='synthetic-'..i,review={reviewId='synthetic-'..i,
        bookId='900001',userVid=900000,author={userVid=900000,name='discard'},content='合成想法 '..i,abstract=i%2==1 and '引用文字' or '',
        chapterName='合成章节',chapterUid=7,chapterIdx=1,range='12-23',type=1,isPrivate=i%2,createTime=1000,token='discard'}} end
    return {reviews=rows,totalCount=total or 3,hasMore=0,synckey=12345}
end
local full=source();local page=Data.page(client,full,'900001','900000')
expect(not page.has_more and #page.reviews==3,'complete own thoughts lost')
local snapshot=Data.project(client,full,'900001','900000',1000)
expect(snapshot.reviews[1].content=='合成想法 1' and not snapshot.reviews[1].author and not snapshot.reviews[1].userVid
    and not snapshot.synckey and not snapshot.reviews[1].token,'source fields escaped display projection')
expect(Data.page(client,source(1,3),'900001','900000').has_more,'false hasMore truncated the personal list')
expect(not pcall(Data.project,client,source(1,3),'900001','900000',1000),'partial prefix became complete cache')
expect(#Data.project(client,source(0,0),'900001','900000',1000).reviews==0,'empty personal list rejected')
local function reject(value) expect(not pcall(Data.page,client,value,'900001','900000'),'invalid own thought accepted') end
local created=source();created.reviews[1].review.chapterUid='7'
expect(Data.project(client,created,'900001','900000',1000).reviews[1].chapterUid==7,'native-created decimal UID was not normalized')
expect(created.reviews[1].review.chapterUid=='7','projection mutated its source')
for _i,bad in ipairs({'07','7.0','1e1',' 7','2147483648',true}) do
    local value=source();value.reviews[1].review.chapterUid=bad;reject(value)
end
created=source();created.reviews[1].review.chapterIdx='7';reject(created)
for _,field in ipairs({'bookId','owner','author','nested','identity','missing_owner','duplicate','text','content','private','time','rows','total','flag','errcode'}) do
    local value=source();local row=value.reviews[1].review
    if field=='bookId' then row.bookId='900002' elseif field=='owner' then row.userVid=900001
    elseif field=='author' then row.author.userVid=900001 elseif field=='nested' then row.book={bookId='900002'}
    elseif field=='identity' then value.reviews[1].reviewId='different' elseif field=='missing_owner' then row.userVid=nil;row.author=nil
    elseif field=='duplicate' then value.reviews[2]=value.reviews[1] elseif field=='text' then row.content='bad\255'
    elseif field=='content' then row.content=nil elseif field=='private' then row.isPrivate=2 elseif field=='time' then row.createTime=true
    elseif field=='rows' then value.reviews={} elseif field=='total' then value.totalCount=2 elseif field=='flag' then value.hasMore='0'
    else value.errcode=false end
    reject(value)
end
local scope,revision,valid={vid='900000',epoch=1},1,true
local credentials={vid='900000',accessToken='synthetic-access',refreshToken='synthetic-refresh',deviceId=string.rep('1',32)}
local settings={get_auth_scope=function() return scope end,auth_scope_matches=function(_self,v) return valid and v==scope end}
local store={read=function() return credentials,revision end}
local calls,reply,status={},nil,200
local decode=client.json_decode
client.settings=settings;client.json_decode=function(self,bytes) return bytes=='fixture' and reply or decode(self,bytes) end
local responses={source(1,3),source(2,3),source(3,3)}
client.request=function(_self,options) calls[#calls+1]=options;reply=responses[#calls];return 'fixture',status end
local function selected() return Data.capture(settings,store) end
snapshot=Data.fetch(client,'900001',selected(),{now=1000})
expect(#snapshot.reviews==3 and #calls==3,'progressive prefix did not fetch all thoughts')
for index,count in ipairs({20,40,80}) do
    local request=calls[index]
    expect(request.url=='https://i.weread.qq.com/review/list?bookId=900001&listType=11&listMode=0&mine=1&synckey=0&count='..count
        and request.method=='GET' and not request.body,'wrong own-list query')
    expect(request.sensitive and request.skip_cookie and not request.persist_response_cookies and request.headers.vid=='900000'
        and request.headers.accessToken=='synthetic-access' and not request.headers.Cookie,'personal transport mixed credentials')
end
for _,change in ipairs({'prefix','count','no_progress','identity'}) do
    calls={};responses={source(1,3),source(2,3)}
    if change=='prefix' then responses[2].reviews[1].review.content='changed'
    elseif change=='count' then responses[2].totalCount=4 elseif change=='no_progress' then responses[2]=source(1,3)
    else responses[2].reviews[2].review.bookId='900002' end
    expect(not pcall(Data.fetch,client,'900001',selected()) and #calls==2,'unstable prefix accepted')
end
calls={};responses={source(1,3)};status=401
local ok,err=pcall(Data.fetch,client,'900001',selected(),{recover_auth=true})
expect(not ok and err==Data.EXPIRED and #calls==1,'explicit expiry not returned to parent once')
for _,code in ipairs({403,404,429,503}) do
    calls={};status=code;ok,err=pcall(Data.fetch,client,'900001',selected(),{recover_auth=true})
    expect(not ok and err=='my_thoughts/unavailable' and #calls==1,'non401 failure retried or exposed raw response')
end
local access=selected();revision=2;calls={}
expect(not pcall(Data.fetch,client,'900001',access) and #calls==0,'old grant sent request')
valid=false
expect(not pcall(Data.fetch,client,'900001',selected()) and #calls==0,'invalid scope sent request')
print('PASS: personal thought projection and progressive GET ('..checks..' checks)')
