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
local public_client={get_public_book_search=function(_self,keyword,cursor)
    expect(keyword=='term' and cursor==0,'public search input changed')
    return {books={{bookInfo={bookId='900001',title='Public',intro='Public intro',publisher='Public publisher',
        newRating=860,newRatingCount=12,token='private'},searchIdx=1},
        {bookInfo={bookId='unsupported',title='Unsupported'},searchIdx=2}},hasMore=1}
end}
local public=Source.fetch(public_client,{kind='search',keyword='term',cursor=0,source_kind='public'})
expect(public.source_kind=='public' and public.source_revision=='public' and #public.books==1
    and public.next_cursor==2 and public.has_more,'public search failed supported IDs or pagination')
expect(public.books[1]._public_info.intro=='Public intro' and public.books[1]._public_info.publisher=='Public publisher'
    and public.books[1]._public_info.newRating==860 and not public.books[1]._public_info.token,
    'public search did not safely project available book details')
for _,status in ipairs({401,403,500,503,'transport'}) do
    local fallback=fixture();fallback.change{status=status,key=''}
    local calls=0
    fallback.client.get_public_book_search=function(_self,keyword,cursor)
        calls=calls+1;return public_client:get_public_book_search(keyword,cursor)
    end
    local access=fallback.capture()
    local found=Source.fetch(fallback.client,{kind='search',keyword='term',cursor=0},access)
    expect(found.source_kind=='public' and calls==1,'unavailable native search did not fall back publicly')
    expect(not pcall(Source.fetch,fallback.client,{kind='search',keyword='term',cursor=20,
        source_kind='native',source_revision=access.revision},access) and calls==1,
        'bound native page switched to public search')
end
do
    local fallback=fixture();fallback.change{status=429,key=''}
    fallback.client.get_public_book_search=function() error('rate-limited request fanned out') end
    expect(not pcall(Source.fetch,fallback.client,{kind='search',keyword='term',cursor=0},fallback.capture()),
        'rate limit triggered public fallback')
    fallback.change{status=401}
    local valid,reason=pcall(Source.fetch,fallback.client,{kind='search',keyword='term',cursor=0},fallback.capture(),{recover_auth=true})
    expect(not valid and reason=='discovery/native_expired','public fallback skipped native renewal')
end
for _,native in ipairs({false,true}) do
    local fallback=fixture();fallback.change{present=native,status=403}
    local gateways,public_reads=0,0
    fallback.client.get_gateway_discovery=function()
        gateways=gateways+1;error('discovery/gateway_recoverable',0)
    end
    fallback.client.get_public_book_search=function(_self,keyword,cursor)
        public_reads=public_reads+1;return public_client:get_public_book_search(keyword,cursor)
    end
    local access=fallback.capture()
    local found=Source.fetch(fallback.client,{kind='search',keyword='term',cursor=0},access)
    expect(found.source_kind=='public' and gateways==1 and public_reads==1,
        'unavailable gateway did not fall back to public search')
    expect(not pcall(Source.fetch,fallback.client,{kind='search',keyword='term',cursor=20,
        source_kind='gateway',source_revision=access.revision},access) and public_reads==1,
        'gateway continuation changed source')
    expect(not pcall(Source.fetch,fallback.client,{kind='recommend',cursor=0},access) and public_reads==1,
        'failed recommendations silently became public search')
    fallback.client.get_gateway_discovery=function() error('discovery/gateway_unavailable',0) end
    expect(not pcall(Source.fetch,fallback.client,{kind='search',keyword='term',cursor=0},access) and public_reads==1,
        'gateway rate limit or malformed result triggered fallback')
    fallback.client.get_gateway_discovery=function() return {errcode=-2012} end
    expect(not pcall(Source.fetch,fallback.client,{kind='search',keyword='term',cursor=0},access) and public_reads==1,
        'gateway business rejection triggered fallback')
end
do
    local fallback=fixture();fallback.change{present=false}
    fallback.client.get_gateway_discovery=function() fallback.change{current=false};error('discovery/gateway_recoverable',0) end
    fallback.client.get_public_book_search=function() error('stale account requested public data') end
    expect(not pcall(Source.fetch,fallback.client,{kind='search',keyword='term',cursor=0},fallback.capture()),
        'changed account survived gateway failure')
end
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
do
    local empty=fixture()
    empty.data.books={};empty.data.hasMore=false
    local calls={}
    empty.client.get_gateway_discovery=function(_client,kind,options,key)
        expect(kind=='recommend' and key=='synthetic-key','empty recommendation used the wrong Skill access')
        calls[#calls+1]=options.cursor
        return {books={{bookId='900002',title='Skill recommendation',searchIdx=options.cursor==0 and 20 or 21}},
            hasMore=options.cursor==0}
    end
    local access=empty.capture()
    local first=Source.fetch(empty.client,{kind='recommend',cursor=0},access)
    expect(first.source_kind=='gateway' and first.source_revision==access.revision and first.has_more and first.next_cursor==20
        and #calls==1 and #empty.requests==1,'explicit empty native first page did not fall back once')
    local second=Source.fetch(empty.client,{kind='recommend',cursor=first.next_cursor,source_kind=first.source_kind,
        source_revision=first.source_revision},access)
    expect(second.source_kind=='gateway' and second.next_cursor==21 and not second.has_more
        and #calls==2 and calls[2]==20 and #empty.requests==1,'Skill continuation retried native or reset the cursor')
    local bound=Source.fetch(empty.client,{kind='recommend',cursor=0,source_kind='native',source_revision=access.revision},access)
    expect(bound.source_kind=='native' and #bound.books==0 and #calls==2,'bound native recommendation changed source')
    empty.data.hasMore=true
    Source.fetch(empty.client,{kind='recommend',cursor=0},access)
    expect(#calls==2,'contradictory empty result started a fallback')
    empty.data.hasMore=false;empty.data.books={{not_a_book=true}}
    Source.fetch(empty.client,{kind='recommend',cursor=0},access)
    expect(#calls==2,'filtered invalid rows were mistaken for an explicit empty response')
    empty.data.books={}
    empty.client.get_gateway_discovery=function() return {books={},hasMore=false} end
    local neither=Source.fetch(empty.client,{kind='recommend',cursor=0},access)
    expect(neither.source_kind=='native' and #neither.books==0,'empty fallback changed the selected source')
    empty.client.get_gateway_discovery=function() error('discovery/rate_limited',0) end
    local unchanged=Source.fetch(empty.client,{kind='recommend',cursor=0},access)
    expect(unchanged.source_kind=='native' and #unchanged.books==0,'optional Skill failure lost a valid native response')
    empty.client.get_gateway_discovery=function() empty.change{revision=2};error('discovery/gateway_unavailable',0) end
    local accepted,reason=pcall(Source.fetch,empty.client,{kind='recommend',cursor=0},access)
    expect(not accepted and reason=='discovery/session_changed','optional fallback restored a stale native result')
    empty.change{key=''}
    empty.client.get_gateway_discovery=function() error('unexpected Skill request',0) end
    local keyless=Source.fetch(empty.client,{kind='recommend',cursor=0},empty.capture())
    expect(keyless.source_kind=='native' and #keyless.books==0,'valid keyless empty recommendations were lost')
end
for _,status in ipairs({401,403,500,503,"transport"}) do
    f=fixture();f.change{status=status};selected=f.capture()
    result=Source.fetch(f.client,{kind="recommend",cursor=0},selected)
    expect(result.source_kind=="gateway" and f.gateway_count()==1,"first-page fallback")
    expect(not pcall(Source.fetch,f.client,{kind="recommend",cursor=20,source_kind="native",source_revision=selected.revision},selected)
        and f.gateway_count()==1,"continuation cannot fall back across sources")
end
f=fixture();f.change{status=429}
local ok,err=pcall(Source.fetch,f.client,{kind="recommend",cursor=0},f.capture())
expect(not ok and err=="discovery/rate_limited" and f.gateway_count()==0,"rate limiting cannot trigger fallback or leak response")
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
auth:read_search_suggestions({vid="123",accessToken="synthetic"},"书 &")
request=f.requests[#f.requests]
expect(request.url:find('/store/suggest?count=10&keyword=',1,true) and request.url:find('%%26')
    and request.method=='GET' and request.skip_cookie and request.sensitive,'suggestions transport contract')
expect(not pcall(auth.read_search_suggestions,auth,{vid='456',accessToken='synthetic'},'word'),
    'suggestions did not enforce the account')
local before=#f.requests
for _,options in ipairs({{cursor=-1},{cursor=0/0},{cursor=math.huge},{cursor=1.5},{cursor=2147483648}}) do
    expect(not pcall(auth.read_discovery,auth,{vid="123",accessToken="synthetic"},"recommend",options),"invalid cursor rejected")
end
expect(#f.requests==before,"invalid query sends no HTTP")
f=fixture();f.data.keyword='science';f.data.records={{word='science books'}};f.data.list={};f.data.parts={}
local Suggest=require('weread.lib.search_suggestions')
local suggestions=Suggest.fetch(f.client,f.capture(),'science')
expect(#suggestions==1 and suggestions[1]=='science books' and #f.requests==1,
    'session-bound suggestions were not returned')
f=fixture();selected=f.capture();f.change{revision=2}
expect(not pcall(Suggest.fetch,f.client,selected,'science') and #f.requests==0,
    'stale suggestion credentials sent a request')
f=fixture();selected=f.capture();f.change{callback=function() f.change{current=false} end}
expect(not pcall(Suggest.fetch,f.client,selected,'science'), 'account change accepted suggestion response')
for _,data in ipairs({{}, {books={bad=true}}, {books=string.rep("x",10)}, {results={{}}}, {results={false}}, {books={},succ=0}}) do
    expect(not pcall(Source.project,{},"search",data,0),"malformed page rejected")
end
expect(#Source.project({},"search",{results={}},0).books==0,"valid empty search")
expect(#Source.project({},"recommend",{books={}},0).books==0,"valid empty recommendations")
expect(not Source.project({},"recommend",{books={{bookId="a"}},hasMore=true},20).has_more,"missing cursor cannot loop")
local credits={books={{bookId='42',author='One\r\nTwo',idx=21},{bookId='43',author='Three',idx=22}},hasMore=1}
local category=Source.project({},'category',credits,20)
expect(#category.books==2 and category.books[1].author=='One Two' and category.next_cursor==22 and category.has_more,
    'line breaks in public authors rejected the whole batch or changed pagination')
credits.books[1].bookId='42\n'
expect(not pcall(Source.project,{},'category',credits,20),'identity was normalized as display text')
credits.books[1].bookId,credits.books[1].author='42','One\0Two'
expect(not pcall(Source.project,{},'category',credits,20),'an invalid author character was accepted')
print("discovery_source_spec: "..checks.." checks")
