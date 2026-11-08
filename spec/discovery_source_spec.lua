package.path = "./?.lua;./?/init.lua;" .. package.path
local Source = require("weread.lib.discovery_source")
local Auth = require("weread.lib.native_authorization")
local checks = 0
local function expect(value, label) checks = checks + 1 assert(value, label) end
local function fixture()
    local scope, revision = { vid = "123", epoch = 1 }, 1
    local credentials = { vid = "123", accessToken = "synthetic-access", refreshToken = "synthetic-refresh", deviceId = string.rep("1",32) }
    local key, present, current, status, callback = "synthetic-key", true, true, 200
    local data = { books = {{bookInfo={bookId="900001",title="Synthetic",version=99,token="private"},searchIdx=20}},hasMore=true }
    local requests, gateway = {}, 0
    local settings = { get=function(_self,name,default) if name=="api_key" then return key end return default end,
        get_auth_scope=function() return scope end,auth_scope_matches=function(_self,value) return current and value==scope end }
    local store = {read=function() return present and credentials or nil,revision end}
    local client = {settings=settings,json_decode=function() return data end,
        request=function(_self,request)
            requests[#requests+1]=request
            if callback then callback() end
            if status=="transport" then error("private-url-token") end
            return "fixture",status
        end,
        get_gateway_discovery=function(_self,kind,options,captured_key)
            gateway=gateway+1;expect(captured_key=="synthetic-key","captured gateway key")
            return kind=="similar" and {booksimilar={books=data.books,sessionId=options.session_id or "s1"}} or data
        end }
    return {settings=settings,client=client,store=store,requests=requests,data=data,
        capture=function() return Source.capture(settings,store) end,
        gateway_count=function() return gateway end,
        change=function(values)
            if values.key~=nil then key=values.key end
            if values.present~=nil then present=values.present end
            if values.current~=nil then current=values.current end
            if values.revision then revision=values.revision end
            if values.status then status=values.status end
            if values.callback then callback=values.callback end
        end}
end
local f=fixture()
local selected=f.capture()
local result=Source.fetch(f.client,{kind="search",keyword="三体 &",cursor=0},selected)
expect(result.source_kind=="native" and result.next_cursor==20 and #result.books==1,"native root books projection")
expect(result.books[1].version==nil and result.books[1].token==nil,"display-only projection")
local request=f.requests[1]
expect(request.url:find("/store/search?",1,true) and request.url:find("scope=10",1,true)
    and request.url:find("count=20",1,true) and request.url:find("maxIdx=0",1,true),"native search contract")
expect(request.method=="GET" and request.body==nil and request.sensitive and request.skip_cookie
    and request.persist_response_cookies==false and request.headers.accessToken=="synthetic-access"
    and not request.headers.Cookie and not request.headers.Authorization,"isolated native transport")
expect(f.gateway_count()==0,"native success skips gateway")
for _,status in ipairs({401,403,500,503,"transport"}) do
    f=fixture();f.change{status=status};selected=f.capture()
    result=Source.fetch(f.client,{kind="recommend",cursor=0},selected)
    expect(result.source_kind=="gateway" and f.gateway_count()==1,"first-page fallback")
    expect(not pcall(Source.fetch,f.client,{kind="recommend",cursor=20,source_kind="native",source_revision=selected.revision},selected)
        and f.gateway_count()==1,"continuation cannot fall back across sources")
end
f=fixture();f.change{status=429}
local ok,err=pcall(Source.fetch,f.client,{kind="recommend",cursor=0},f.capture())
expect(not ok and err=="discovery/native_unavailable" and f.gateway_count()==0,"rate limiting cannot trigger fallback or leak response")
f=fixture();f.data.errcode=-2012
expect(not pcall(Source.fetch,f.client,{kind="recommend",cursor=0},f.capture()) and f.gateway_count()==0,"API rejection stays rejected")
f=fixture();selected=f.capture();f.change{revision=2}
expect(not Source.matches(f.settings,selected) and not pcall(Source.fetch,f.client,{kind="recommend"},selected)
    and #f.requests==0,"renewal invalidates captured access before HTTP")
f=fixture();selected=f.capture();f.change{callback=function() f.change{current=false} end}
expect(not pcall(Source.fetch,f.client,{kind="recommend"},selected) and f.gateway_count()==0,"account change during read discarded")
f=fixture();selected=f.capture()
expect(not pcall(Source.fetch,f.client,{kind="recommend",source_revision="old"},selected) and #f.requests==0,"stale list cannot continue")
f.change{present=false};selected=f.capture()
expect(selected and not selected.native and Source.fetch(f.client,{kind="recommend"},selected).source_kind=="gateway","gateway-only supported")
f.change{key=""};local absent,reason=f.capture()
expect(not absent and reason=="native_required","no Web Cookie as native token")
f.change{current=false};absent,reason=f.capture()
expect(not absent and reason=="login_required","owner scope must be current")
f=fixture()
local auth=Auth:new(f.client,{expected_vid="123"})
auth:read_discovery({vid="123",accessToken="synthetic"},"similar",{book_id="900001",cursor=20,session_id="s&1"})
request=f.requests[1]
expect(request.url:find("/book/detailinfo?",1,true) and request.url:find("listtypes=2",1,true)
    and request.url:find("synckey=0",1,true) and request.url:find("sessionId=s%%261"),"native similar session contract")
local before=#f.requests
for _,options in ipairs({{cursor=-1},{cursor=0/0},{cursor=math.huge},{cursor=1.5},{cursor=2147483648}}) do
    expect(not pcall(auth.read_discovery,auth,{vid="123",accessToken="synthetic"},"recommend",options),"invalid cursor rejected")
end
expect(#f.requests==before,"invalid query sends no HTTP")
for _,data in ipairs({{}, {books={bad=true}}, {books=string.rep("x",10)}, {results={{}}}, {results={false}}, {books={},succ=0}}) do
    expect(not pcall(Source.project,{},"search",data,0),"malformed page rejected")
end
expect(#Source.project({},"search",{results={}},0).books==0,"valid empty search")
expect(#Source.project({},"recommend",{books={}},0).books==0,"valid empty recommendations")
expect(not Source.project({},"recommend",{books={{bookId="a"}},hasMore=true},20).has_more,"missing cursor cannot loop")
print("discovery_source_spec: "..checks.." checks")
