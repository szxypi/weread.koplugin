package.path="./?.lua;"..package.path
local Metadata=require("weread.lib.book_metadata")
local Auth=require("weread.lib.native_authorization")
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local function fixture(book_id)
    book_id=book_id or '900001'
    local scope={vid="900000",epoch=1}
    local revision,present,valid,key,cookies=1,true,true,"synthetic-key",{wr_vid="900000",wr_skey="synthetic-web"}
    local code,change=200,nil
    local credentials={vid="900000",accessToken="synthetic-native",refreshToken="synthetic-refresh",deviceId=string.rep("1",32)}
    local settings={get=function(_self,name,default)
        if name=="api_key" then return key end
        if name=="cookies" then return cookies end
        return default
    end,get_auth_scope=function() return scope end,auth_scope_matches=function(_self,value) return valid and value==scope end}
    local source={bookId=book_id,title="Native title",intro="Native introduction",publisher="Native publisher",totalWords=12345,
        version=700,bookVersion=99,progress=99,chapterOffset=321,finishReading=1,token="private-token"}
    local requests,routes={},{}
    local store={read=function() return present and credentials or nil,revision end}
    local client={settings=settings,json_decode=function() return source end,
        request=function(_self,request)
            requests[#requests+1]=request
            if change then change() end
            if code=="transport" then error("private-url-token") end
            return "fixture",code
        end,
        get_display_book_metadata=function(_self,id,access)
            routes[#routes+1]=access.kind
            return {bookId=id,title="Fallback title"}
        end}
    return {settings=settings,client=client,store=store,source=source,requests=requests,routes=routes,
        capture=function() return Metadata.capture(settings,store) end,
        change=function(value)
            if value.revision then revision=value.revision end
            if value.present~=nil then present=value.present end
            if value.valid~=nil then valid=value.valid end
            if value.key~=nil then key=value.key end
            if value.cookies~=nil then cookies=value.cookies end
            if value.code then code=value.code end
            if value.on_request then change=value.on_request end
        end}
end
local f=fixture()
local selected=f.capture()
local result=Metadata.fetch(f.client,"900001",selected)
expect(result.source=="native" and result.metadata.wordCount==12345 and #f.routes==0,"native-first metadata and verified word count")
expect(f.source.wordCount==nil,"native projection mutated source")
for _,key in ipairs({"version","bookVersion","totalWords","progress","chapterOffset","finishReading","token"}) do
    expect(result.metadata[key]==nil,"non-display state escaped native projection")
end
local request=f.requests[1]
expect(request.method=="GET" and request.url=="https://i.weread.qq.com/book/info?bookId=900001" and request.body==nil,"fixed native metadata GET")
expect(request.sensitive and request.skip_cookie and request.persist_response_cookies==false and request.headers.accessToken=="synthetic-native"
    and request.headers.vid=="900000" and not request.headers.Cookie and not request.headers.Authorization,"isolated sensitive native transport")
for _,code in ipairs({401,403,500,503,"transport"}) do
    f=fixture();f.change{code=code}
    expect(Metadata.fetch(f.client,"900001",f.capture()).source=="gateway" and #f.routes==1,"safe native failure uses configured fallback")
end
f=fixture();f.change{code=503,key=""}
expect(Metadata.fetch(f.client,"900001",f.capture()).source=="web" and #f.routes==1,"keyless Web fallback remains available")
for _,code in ipairs({429,404,302}) do
    f=fixture();f.change{code=code}
    local ok,err=pcall(Metadata.fetch,f.client,"900001",f.capture())
    expect(not ok and err=="book_metadata/unavailable" and #f.routes==0,"native refusal cannot fan out or expose raw error")
end
f=fixture();f.source.bookId="900002"
expect(not pcall(Metadata.fetch,f.client,"900001",f.capture()) and #f.routes==0,"wrong native book cannot overwrite selected metadata")
f=fixture();f.source.errcode=-2012
expect(not pcall(Metadata.fetch,f.client,"900001",f.capture()) and #f.routes==0,"native rejection is terminal")
for _,change in ipairs({{revision=2},{present=false},{valid=false},{cookies={}},{key="different-key"}}) do
    f=fixture();selected=f.capture();f.change(change)
    expect(not Metadata.matches(f.settings,selected),"changed authorization invalidates snapshot")
    expect(not pcall(Metadata.fetch,f.client,"900001",selected) and #f.requests==0,"changed authorization sends no HTTP")
end
f=fixture();selected=f.capture();f.change{on_request=function() f.change{revision=2} end}
expect(not pcall(Metadata.fetch,f.client,"900001",selected) and #f.routes==0,"renewal during HTTP cannot apply or fall back")
f=fixture();f.change{key="",cookies={}}
expect(Metadata.fetch(f.client,"900001",f.capture()).source=="native","native grant does not require Web Cookie or Skill key")
local auth=Auth:new(f.client,{expected_vid="900000"})
local before=#f.requests
for _,id in ipairs({"0","900001&other=1",false,"MP_WXS_test",string.rep("9",21)}) do
    expect(not pcall(auth.read_book_metadata,auth,{vid="900000",accessToken="synthetic"},id),"invalid metadata identity rejected")
end
expect(not pcall(auth.read_book_metadata,auth,{vid="900001",accessToken="synthetic"},"900001") and #f.requests==before,"wrong owner sends no HTTP")

local cb='CB_SyntheticMetadata'
f=fixture(cb);result=Metadata.fetch(f.client,cb,f.capture())
expect(result.source=='native' and result.metadata.bookId==cb and result.metadata.wordCount==12345,'verified CB native metadata was rejected')
expect(f.requests[1].url=='https://i.weread.qq.com/book/info?bookId='..cb and f.requests[1].body==nil,'CB native metadata route changed')
f=fixture(cb);f.change{code=403}
expect(Metadata.fetch(f.client,cb,f.capture()).source=='web' and table.concat(f.routes,',')=='web','CB metadata attempted an unverified gateway fallback')
f=fixture(cb);f.change{present=false,cookies={}}
expect(not pcall(Metadata.fetch,f.client,cb,f.capture()) and #f.requests==0 and #f.routes==0,'gateway-only CB metadata sent HTTP')
f=fixture(cb);f.source.bookId='CB_SyntheticOther'
expect(not pcall(Metadata.fetch,f.client,cb,f.capture()) and #f.routes==0,'another CB book overwrote the target')
f=fixture(cb);f.change{code=429}
expect(not pcall(Metadata.fetch,f.client,cb,f.capture()) and #f.requests==1 and #f.routes==0,'CB metadata rate failure fanned out')
f=fixture(cb);auth=Auth:new(f.client,{expected_vid='900000'});before=#f.requests
expect(not pcall(auth.write_shelf_membership,auth,{vid='900000',accessToken='synthetic'},cb,'remove') and #f.requests==before,
    'CB metadata expanded a membership write identity')
expect(not pcall(auth.read_annotations,auth,{vid='900000',accessToken='synthetic'},'underlines',cb,'1') and #f.requests==before,
    'CB metadata expanded an unverified annotation route')
for _i,id in ipairs({'CB_','CB_'..string.rep('a',65),'CB_a/b','CB_a?x=1','CB_a_b'}) do
    expect(not pcall(auth.read_book_metadata,auth,{vid='900000',accessToken='synthetic'},id) and #f.requests==before,
        'invalid CB metadata identity reached HTTP')
end

-- Exercise the parent controller's native fingerprint and storage allowlist.
local active_store
package.preload["weread.lib.native_credentials"]=function() return {new=function() return active_store end} end
package.preload["ui/uimanager"]=function() return {close=function() end,scheduleIn=function() end} end
package.preload["weread.lib.plugin_util"]=function() return {tr=function(value) return value end} end
local UI=require("weread.ui.book_metadata")
local function host_fixture(book_id)
    book_id=book_id or '900001'
    local sample=fixture(book_id);sample.settings.data_dir="/synthetic-unused";active_store=sample.store
    local books={[book_id]={book_id=book_id,progress=80,bookVersion=7,chapter_uid=1,pending_upload_position={percent=80}}}
    local get=sample.settings.get
    sample.settings.get=function(self,name,default) if name=="books" then return books end return get(self,name,default) end
    sample.settings.set=function(_self,name,value) expect(name=="books","metadata changed another setting");books=value end
    sample.settings.flush=function() end
    local job,saves,shown=nil,0,nil
    local host={settings=sample.settings,client=sample.client,
        library_db={accountKey=function() return "synthetic-owner" end,putBook=function() saves=saves+1;return true end},
        isNetworkOnline=function() return true end,
        showBusy=function(self) self.busy_message={} end,closeBusy=function(self) self.busy_message=nil end,
        showInfo=function() end,showTransientInfo=function() end,showBookMenu=function(_self,value) shown=value end,
        book_metadata_worker={start=function(_self,task,callback) job={task=task,callback=callback};return true end,cancel=function() end}}
    return sample,host,function() return job,books,saves,shown end
end
local host,state
f,host,state=host_fixture()
expect(UI.refresh(host,{book_id="900001"},nil,{automatic=true}),"native metadata UI did not start")
local job,books=state()
result=job.task()
books['900001'].progress=84;books['900001'].bookVersion=47;books['900001'].chapter_uid=99
job.callback(result)
local _,_,saves,shown=state()
expect(saves==1 and shown.detail_source=="native" and shown.wordCount==12345,"native result not accepted by parent")
expect(shown.progress==84 and shown.bookVersion==47 and shown.chapter_uid==99 and shown.pending_upload_position.percent==80
    and not shown.token and not shown.totalWords,"native metadata replaced current reader/source state")
for _,change in ipairs({{revision=2},{present=false},{valid=false},{cookies={}}}) do
    f,host,state=host_fixture()
    UI.refresh(host,{book_id="900001"},nil,{automatic=true})
    job=state();result=job.task();f.change(change);job.callback(result)
    local _,_,written=state()
    expect(written==0 and not host.busy_message and not host.book_metadata_context,"old native authorization result was committed")
end
f,host,state=host_fixture(cb)
expect(UI.refresh(host,{book_id=cb},nil,{automatic=true}),'CB metadata controller did not start')
job,books=state();result=job.task()
books[cb].progress=84;books[cb].chapter_uid=99;books[cb].bookVersion=47
job.callback(result)
local cb_saves,cb_shown=select(3,state())
expect(cb_saves==1 and cb_shown.book_id==cb and cb_shown.detail_source=='native','CB result did not persist through its owner controller')
expect(cb_shown.progress==84 and cb_shown.chapter_uid==99 and cb_shown.bookVersion==47
    and cb_shown.pending_upload_position.percent==80 and cb_shown.token==nil,'CB metadata overwrote current reading state')
f,host,state=host_fixture(cb);UI.refresh(host,{book_id=cb},nil,{automatic=true});job=state();result=job.task()
f.change{revision=2};job.callback(result)
local cb_written=select(3,state())
expect(cb_written==0 and not host.book_metadata_context,'old CB authorization metadata was committed')
print("PASS: "..checks.." native metadata route/projection/session checks")
