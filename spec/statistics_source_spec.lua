package.path="./?.lua;./?/init.lua;"..package.path
local Source=require("weread.lib.statistics_source")
local Data=require("weread.lib.statistics_data")
local Stats=require("weread.lib.read_stats")
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local now=Stats.cst_time{year=2025,month=1,day=2,hour=12}
local base=Stats.period_start("monthly",now)
local raw={baseTime=base,readTimes={[tostring(base)]=60},totalReadTime=60,readDays=1,
    secret="private",readLongest={{book={bookId="private-id",title="Title",author="Author",token="private"},readTime=60}}}
local projected=Data.project(raw,"monthly",base,now)
expect(projected.secret==nil and projected.readLongest[1].book.bookId==nil and projected.readLongest[1].book.token==nil,"private/non-display fields escaped")
expect(raw.readLongest[1].book.bookId=="private-id","projection mutated source")
for _,change in ipairs({{totalReadTime=0/0},{readDays=32},{readDays=1.5},{baseTime=base-86400},{readTimes={bad=1}},
    {readTimes={[tostring(base-86400)]=60}},{readTimes={[tostring(base+1)]=60}},
    {readTimes={[tostring(base)]=-1}},{readTimes={false}},{errcode=-1},{readLongest={bad=true}}}) do
    local value={} for k,v in pairs(raw) do value[k]=v end for k,v in pairs(change) do value[k]=v end
    expect(not pcall(Data.project,value,"monthly",base,now),"invalid statistics became known activity")
end
local value=Data.project({baseTime=base,totalReadTime=0,readDays=0,readTimes={}},"monthly",base,now)
expect(value.totalReadTime==0,"valid no-activity response rejected")
value=Data.project({baseTime=0,totalReadTime=120,readDays=1,readTimes={[tostring(base)]=60}},"overall",0,now)
expect(value.totalReadTime==120,"server overall total replaced by bucket sum")
value=Data.project({baseTime=base,totalReadTime=60,readDays=1,readTimes={[tostring(base)]=60,[tostring(base*1000)]=60}},"monthly",base,now)
expect(value.readTimes[tostring(base)]==60,"timestamp units not canonicalized")
expect(not pcall(Data.project,{baseTime=base,totalReadTime=60,readDays=1,
    readTimes={[tostring(base)]=60,[tostring(base*1000)]=61}},"monthly",base,now),"conflicting units accepted")
local scope={vid="900000",epoch=1}
local state={revision=1,pending=false,key="synthetic-key",valid=true,present=true,code=200,native=0,gateway=0}
local credentials={vid="900000",accessToken="synthetic-access",refreshToken="synthetic-refresh",deviceId=string.rep("1",32)}
local settings={get=function(_self,key,default) if key=="api_key" then return state.key end return default end,
    get_auth_scope=function() return scope end,auth_scope_matches=function(_self,candidate) return state.valid and candidate==scope end}
local store={read=function() return state.present and credentials or nil,state.revision,nil,state.pending end}
local request,callback
local client={settings=settings,json_decode=function() return raw end,
    request=function(_self,options)
        state.native=state.native+1;request=options;if callback then callback() end
        if state.code=="transport" then error("private-transport") end
        return "fixture",state.code
    end,
    get_gateway_read_stats=function(_self,mode,target,key)
        expect(mode=="monthly" and target==base and key=="synthetic-key","captured gateway parameters")
        state.gateway=state.gateway+1;return raw
    end}
local function fetch(options,selected) return Source.fetch(client,"monthly",base,selected or Source.capture(settings,store),options) end
value=fetch()
expect(value._stats_source=="native" and state.gateway==0,"native first statistics")
expect(request.url=="https://i.weread.qq.com/readdata/detail?baseTime="..base.."&mode=monthly" and request.method=="GET"
    and not request.body and request.sensitive and request.skip_cookie and request.persist_response_cookies==false
    and request.headers.vid=="900000" and request.headers.accessToken=="synthetic-access" and not request.headers.Cookie
    and not request.headers.Authorization,"fixed isolated native statistics GET")
for _,code in ipairs({401,403,500,503,"transport"}) do
    state.code=code;state.gateway=0
    expect(fetch()._stats_source=="gateway" and state.gateway==1,"safe first read fallback")
    expect(not pcall(fetch,{source_kind="native"}) and state.gateway==1,"bound statistics batch mixed sources")
end
state.code=401;state.gateway=0
local ok,err=pcall(fetch,{recover_auth=true})
expect(not ok and err=="statistics/native_expired" and state.gateway==0,"401 did not delegate parent renewal")
state.pending=true
expect(fetch({recover_auth=true})._stats_source=="gateway","unconfirmed grant cannot request another renewal")
state.pending=false;state.code=429;state.gateway=0
expect(not pcall(fetch,{recover_auth=true}) and state.gateway==0,"429 renewed or fanned out")
state.code=200
local selected=Source.capture(settings,store);state.revision=2
expect(not pcall(fetch,{},selected),"replaced grant retained statistics request")
selected=Source.capture(settings,store)
callback=function() state.valid=false end
expect(not pcall(fetch,{},selected),"account change during HTTP applied statistics")
callback=nil;state.valid=true;state.present=false;state.gateway=0
expect(fetch()._stats_source=="gateway" and state.gateway==1,"gateway-only remains available")
state.key="";expect(not Source.capture(settings,store),"missing authorization accepted")
local before=state.native
for _,bad in ipairs({-1,0/0,math.huge,1.5,4102444801}) do
    expect(not pcall(Source.fetch,client,"monthly",bad,selected),"invalid requested period accepted")
end
expect(state.native==before,"invalid periods sent HTTP")
print("PASS: "..checks.." statistics projection/source/period/session checks")
