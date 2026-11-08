package.path="./?.lua;./?/init.lua;"..package.path
package.preload["weread.lib.native_credentials"]=function() return {new=function(_self,settings) return settings.native_store end} end
package.preload["ui/uimanager"]=function() return {close=function() end} end
package.preload["weread.lib.plugin_util"]=function() return {tr=function(value) return value end} end
local Auth=require("weread.lib.native_authorization")
local Renewal=require("weread.lib.native_renewal")
local Source=require("weread.lib.discovery_source")
local Discovery=require("weread.ui.discovery_request")
local Metadata=require("weread.ui.book_metadata")
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local function fixture(kind,options)
    options=options or {}
    local scope={vid="900000",epoch=1}
    local state={revision=1,pending=false,posts=0,reads=0,gateway=0,saves=0,rendered=0,current=true,
        key="synthetic-key",codes=options.codes or {401},credentials={vid="900000",accessToken="old-synthetic-access",
            refreshToken="synthetic-refresh",deviceId=string.rep("1",32)}}
    local books={['900001']={book_id="900001",progress=83,bookVersion=47}}
    local settings={data_dir="/unused",get=function(_self,key,default)
        if key=="api_key" then return state.key end
        if key=="books" then return books end
        if key=="cookies" then return {wr_vid="900000",wr_skey="synthetic-cookie"} end
        return default
    end,get_auth_scope=function() return scope end,auth_scope_matches=function(_self,value) return state.current and value==scope end,
        set=function(_self,key,value) assert(key=="books");books=value end,flush=function() end}
    settings.native_store={read=function() return state.credentials,state.revision,nil,state.pending end,
        begin_renewal=function(_self,_scope,revision)
            if state.pending then return false,"renewal_unconfirmed" end
            assert(revision==state.revision);state.revision=revision+1;state.pending=true;return true,state.revision
        end,release_renewal=function() state.revision=state.revision+1;state.pending=false;return true,state.revision end,
        save=function(_self,credentials,_scope,revision)
            assert(revision==state.revision)
            state.credentials=credentials;state.revision=revision+1;state.pending=false;return true,state.revision
        end}
    local scheduled,queue={},{}
    local function worker(label) return {start=function(_self,task,callback)
        queue[#queue+1]={label=label,task=task,callback=callback};return true
    end,cancel=function() end} end
    local decoded
    local function page(query)
        return {books={{bookInfo={bookId="900001",title="Synthetic"},searchIdx=(query and query.cursor or 0)+20}},hasMore=true}
    end
    local client={settings=settings,json_encode=function() return "encoded" end,json_decode=function() return decoded end,
        request=function(_self,request)
            if request.url=="https://i.weread.qq.com/login" then
                state.posts=state.posts+1
                if options.lost then error("private-transport-response") end
                decoded={vid="900000",accessToken="new-synthetic-access"};return "fixture",200
            elseif request.url=="https://i.weread.qq.com/shelf/sync" then decoded={books={{bookId="900001"}}};return "fixture",200 end
            state.reads=state.reads+1
            local code=table.remove(state.codes,1) or 200
            if kind=="metadata" then decoded={bookId="900001",title="Native metadata",totalWords=12000}
            elseif kind=="similar" then decoded={booksimilar={books={{idx=40,bookInfo={bookId="900002",title="Similar"}}},sessionId="session-a",hasMore=false}}
            else decoded=page() end
            return "fixture",code
        end,
        get_gateway_discovery=function(_self,_kind,query) state.gateway=state.gateway+1;return page(query) end,
        get_display_book_metadata=function() state.gateway=state.gateway+1;return {bookId="900001",title="Fallback metadata"} end}
    local host={settings=settings,client=client,library_db={accountKey=function() return "owner-a" end,
        putBook=function() state.saves=state.saves+1;return true end},
        showBusy=function(self,_label,cancel) self.busy_message={};self.cancel_busy=cancel end,
        closeBusy=function(self) self.busy_message=nil end,showInfo=function() end,showTransientInfo=function() end,
        isNetworkOnline=function() return true end,showBookMenu=function(_self,book) state.shown=book end,
        showBookstore=function() state.rendered=state.rendered+1 end,
        runOnlineTask=function(_self,_label,task) scheduled[#scheduled+1]=task;return true end,
        book_metadata_worker=worker("read"),discovery_worker=worker("read")}
    host.native_renewal=Renewal:new{settings=settings,client=client,scheduler={},store=settings.native_store,worker=worker("renew"),
        make_auth=function(_client,opts)
            opts.digits=function(n) return string.rep("1",n) end;opts.now_ms=function() return 1794100000123 end
            return Auth:new(client,opts)
        end}
    local function load()
        if kind=="metadata" then Metadata.refresh(host,{book_id="900001"},nil,{automatic=true})
        elseif kind=="similar" then
            local selected=Source.capture(settings)
            host.discovery_state={kind="similar",account="owner-a",book_id="900001",session_id="session-a",books={},history={},cursor=0,
                next_cursor=20,source_kind="native",source_revision=selected.revision}
            Discovery.load(host,"similar",nil,20,false,false,host.discovery_state)
        else Discovery.load(host,"search","Synthetic",0) end
        while #scheduled>0 do table.remove(scheduled,1)() end
    end
    return {host=host,state=state,load=load,
        tick=function(expected)
            local job=assert(table.remove(queue,1),"missing worker")
            expect(job.label==expected,"worker phase ordering");job.callback(job.task())
        end,
        empty=function() return #queue==0 end,
        cancel=function() if kind=="metadata" then Metadata.cancel(host) else Discovery.cancel(host) end end}
end
for _,kind in ipairs({"metadata","search","similar"}) do
    local f=fixture(kind)
    f.load();f.tick("read")
    expect(f.state.pending and f.state.posts==0 and f.host.busy_message,"401 must persist intent before auth worker")
    f.tick("renew")
    expect(f.state.posts==1 and not f.state.pending and f.state.revision==3,"one verified renewal commits new grant")
    f.tick("read")
    expect(f.state.reads==2 and f.state.gateway==0 and not f.host.busy_message,"native read retries once and releases busy")
    if kind=="metadata" then
        expect(f.state.saves==1 and f.state.shown.detail_source=="native" and f.state.shown.progress==83 and f.state.shown.bookVersion==47,
            "renewed metadata preserves local state")
    else
        local result=f.host.discovery_state
        expect(result.source_kind=="native" and f.state.rendered==1,"renewed native page not displayed")
        if kind=="similar" then expect(result.cursor==20 and result.history[1]==0 and result.session_id=="session-a"
            and result.source_revision==Source.capture(f.host.settings).revision,"continuation lost session/cursor or renewed revision") end
    end
end
for _,kind in ipairs({"metadata","search","similar"}) do
    local f=fixture(kind,{codes={401,401}})
    f.load();local old=f.host.discovery_state;f.tick("read");f.tick("renew");f.tick("read")
    expect(f.state.posts==1 and f.state.reads==2 and f.empty(),"second 401 cannot loop or renew again")
    if kind=="similar" then expect(f.host.discovery_state==old and f.state.gateway==0,"bound continuation switched channel")
    else expect(f.state.gateway==1,"first read preserves standard fallback after one recovery") end
end
for _,kind in ipairs({"metadata","search"}) do
    local f=fixture(kind,{lost=true,codes={401,401}})
    f.load();f.tick("read");f.tick("renew");f.tick("read")
    expect(f.state.posts==1 and f.state.pending and f.state.gateway==1,"lost receipt must retain pending marker and use read-only fallback")
    f.load();f.tick("read")
    expect(f.state.posts==1 and f.empty(),"pending renewal must not replay in a new read")
end
for _,kind in ipairs({"metadata","search"}) do
    local f=fixture(kind)
    f.load();f.tick("read");f.cancel();f.tick("renew")
    expect(f.state.posts==0 and f.state.saves==0 and f.state.rendered==0 and f.empty() and not f.host.busy_message,
        "cancelled renewal cannot apply/retry a read")
    f=fixture(kind);f.load();f.tick("read");f.state.key="replaced-key";f.tick("renew")
    expect(f.state.saves==0 and f.state.rendered==0 and f.empty() and not f.host.busy_message,"changed fallback credentials retain old UI")
    f=fixture(kind,{codes={429}});f.load();f.tick("read")
    expect(f.state.posts==0 and f.state.gateway==0 and f.empty(),"rate limiting cannot renew or fan out")
    f=fixture(kind);f.load();f.tick("read")
    f.state.revision=f.state.revision+1;f.state.pending=false
    f.state.credentials={vid="900000",accessToken="external-synthetic-access",refreshToken="synthetic-refresh",deviceId=string.rep("1",32)}
    f.tick("renew")
    expect(f.state.saves==0 and f.state.gateway==0 and f.state.rendered==0 and f.empty(),"another grant cannot be mistaken for owned renewal")
    f=fixture(kind)
    local old_callback
    f.host.native_renewal={start=function(_self,_options,callback) old_callback=callback;return true,{} end,cancel=function() end}
    f.load();f.tick("read");f.cancel();f.load()
    local busy=f.host.busy_message
    old_callback(false)
    expect(f.host.busy_message==busy and busy~=nil,"stale renewal cancelled a newer request")
    f.tick("read")
end
print("PASS: "..checks.." native read renewal/continuation/fallback/cancel/uncertain-receipt checks")
