package.path = "./?.lua;./?/init.lua;" .. package.path
local Data = require("weread.lib.shelf_progress")
local checks = 0
local function expect(value, message)
    checks = checks + 1
    assert(value, message)
end
for _, n in ipairs({ 0, 1, 50, 100 }) do
    local result = Data.parse({ bookId = "a", book = { progress = n } }, "a", 1000)
    expect(result and result.percent == n and result.fetched_at == 1000, "percent units changed")
end
for _, n in ipairs({ -1, 101, math.huge, 0 / 0, "bad", false }) do
    expect(not Data.parse({ book = { progress = n } }, "a"), "invalid progress accepted")
end
expect(not Data.parse({ bookId = "b", book = { progress = 50 } }, "a"), "root book mismatch accepted")
expect(not Data.parse({ book = { bookId = "b", progress = 50 } }, "a"), "nested book mismatch accepted")
expect(not Data.parse({ progress = 50 }, "a"), "missing progress container accepted")
local saved = { recent_read_account = "account-a", pending_upload_position = { percent = 83, book_id = "a" }, progress = 83 }
local snapshot = { percent = 37, fetched_at = 1000 }
local value, pending = Data.display(saved, snapshot, "account-a", "a")
expect(value == 83 and pending and saved.progress == 83 and snapshot.percent == 37, "local pending display was overwritten")
expect(Data.label(value,pending)=='Local · 83%' and Data.label(37,false)=='37%', 'local and cloud progress labels are ambiguous')
expect(Data.label(0,true)=='Local · 0%' and not Data.label(-1,true), 'invalid local progress label')
local fractional=Data.parse({book={progress=0.25}},'a',1000)
expect(fractional.percent==0 and fractional.exact_percent==0.25,'fractional cloud progress was rounded before caching')
local display,local_position,exact=Data.display({},fractional,'account-a','a')
expect(display==0 and not local_position and exact==0.25 and Data.label(display,false,exact)=='<1%',
    'fractional cloud progress displayed as zero')
display,local_position,exact=Data.display({}, {percent=0,exact_percent=0},'account-a','a')
expect(display==0 and exact==0 and Data.label(display,local_position,exact)=='0%','exact zero was lost')
display,local_position,exact=Data.display({}, {percent=0},'account-a','a')
expect(display==0 and not local_position and exact==nil,'legacy rounded zero was mistaken for an exact zero')
display,local_position,exact=Data.display({}, {percent=1},'account-a','a')
expect(display==1 and not local_position and exact==1,'positive legacy progress stopped being known positive')
display,local_position,exact=Data.display({}, {percent=0,exact_percent=2},'account-a','a')
expect(display==0 and not local_position and exact==nil,'inconsistent precise cache became a filter value')
display,local_position,exact=Data.display({pending_upload_account='account-a',pending_upload_position={book_id='a',percent=0.3}},
    {percent=8,exact_percent=8},'account-a','a')
expect(display==0 and local_position and exact==0.3 and Data.label(display,true,exact)=='Local · <1%',
    'local fractional pending progress lost its precision or source')
display,local_position,exact=Data.display({pending_upload_account='another',pending_upload_position={book_id='a',percent=0.3}},
    {percent=8,exact_percent=8},'account-a','a')
expect(display==8 and not local_position and exact==8,'another account supplied fractional progress')
local old_settings=G_reader_settings
G_reader_settings={readSetting=function() return 'zh_CN' end}
expect(Data.label(83,true)=='本机 · 83%' and Data.label(37,false)=='37%', 'local progress label was not translated')
G_reader_settings=old_settings
expect(Data.display(saved, snapshot, "account-b", "a") == 37, "another account's local progress displayed")
expect(Data.display(saved, snapshot, "account-a", "b") == 37, "another book's local position displayed")
saved.pending_upload_account, saved.recent_read_account = "account-a", "account-b"
expect(Data.display(saved, snapshot, "account-a", "a") == 83, "explicit pending owner lost to recent-reading account")
expect(Data.display(saved, snapshot, "account-b", "a") == 37, "recent reading transferred another account's pending location")
saved.pending_upload_account, saved.recent_read_account = nil, "account-a"
expect(Data.display({}, nil, "account-a", "a") == nil, "missing progress invented")
local calls = {}
local ctx = { checkCancelled = function() end, emit = function() end }
local configured,cookies,scope_valid,api_key=true,{},true,"synthetic-api-key"
local scope={vid="900000",epoch=1}
local settings={
    get=function(_self,key,default)
        if key=="api_key" then return configured and api_key or "" end
        if key=="cookies" then return cookies end
        return default
    end,
    get_auth_scope=function() return scope end,
    auth_scope_matches=function() return scope_valid end,
}
local client = { settings=settings, get_shelf_display_progress = function(_self, id)
    calls[#calls + 1] = id
    if id == "bad" then error("private response must not be persisted") end
    return { bookId = id, book = { progress = 37 } }
end }
local batch = Data.fetch(client, { "a", "bad", "never" }, ctx)
expect(batch.failed and #batch.snapshots == 1 and #calls == 2, "failed batch flooded remaining books or lost valid prefix")
expect(batch.error == nil, "raw response error persisted")
local cancel_checks = 0
calls = {}
local ok = pcall(Data.fetch, client, { "a", "b" }, {
    emit = function() end,
    checkCancelled = function() cancel_checks = cancel_checks + 1 if cancel_checks > 1 then error("cancelled") end end,
})
expect(not ok and #calls == 1, "cancelled batch kept fetching")

local tasks, cancellations, writes, redrawn, account, online = {}, {}, {}, 0, "account-a", true
local worker = {
    available = function() return true end,
    start = function(_self, options)
        local request = { options = options }
        tasks[#tasks + 1] = request
        return true, request
    end,
    cancel = function(_self, request) cancellations[#cancellations + 1] = request end,
}
local Progress = require("weread.ui.shelf_progress")
local cache = { ["900001"] = { book_id = "900001", percent = 37, fetched_at = os.time() } }
saved.pending_upload_position.book_id="900001"
local original_get=settings.get
settings.get=function(self,key,default)
    if key=="books" then return {["900001"]=saved} end
    return original_get(self,key,default)
end
settings.set=function() error("display refresh wrote reader settings") end
local host = setmetatable({
    settings = settings,
    library_db = {
        accountKey = function() return account end,
        getShelfProgress = function() return cache end,
        putShelfProgress = function(_self, snapshots) writes[#writes + 1] = snapshots return true end,
    },
    shelf_progress_worker = worker, client = client,
    isNetworkOnline = function() return online end,
    shelf_view = {},
}, { __index = Progress })
local books = { { bookId = "900001" }, { bookId = "900002" } }
host:prepareShelfProgress(books)
expect(books[1]._shelf_progress == 83 and books[1]._shelf_progress_local and books[2]._shelf_progress == nil,
    "cached/local progress not prepared for display")
local stable_get=settings.get
settings.get=function(self,key,default)
    if key=='books' then return {[900001]={book_id='900001',pending_upload_account='account-a',
        pending_upload_position={book_id='900001',percent=62}},
        ['900002']={book_id='wrong',pending_upload_account='account-a',pending_upload_position={percent=99}}} end
    return stable_get(self,key,default)
end
cache['900002']={book_id='900003',percent=98,fetched_at=os.time()}
local verified=host:prepareShelfProgress(books)
expect(books[1]._shelf_progress==62 and books[1]._shelf_progress_local,
    'legacy numeric key did not restore same-account pending progress')
expect(books[2]._shelf_progress==nil and verified['900002']==nil,
    'foreign local or cached book progress was displayed')
settings.get=stable_get;cache['900002']=nil;host:prepareShelfProgress(books)
local original_online,link_checks=host.isNetworkOnline,0
host.isNetworkOnline=function() error('visible progress resolved DNS on the UI thread') end
host.isNetworkLinkAvailable=function() link_checks=link_checks+1;return online end
local all_fresh={['900001']=cache['900001'],['900002']={book_id='900002',percent=5,fetched_at=os.time()}}
host:refreshVisibleShelfProgress(host.shelf_view,books,all_fresh,{})
expect(link_checks==0 and #tasks==0,'fresh progress performed a network check')
host:refreshVisibleShelfProgress(host.shelf_view, books, cache, { on_redraw = function() redrawn = redrawn + 1 end })
expect(#tasks == 1 and link_checks==1, "visible batch not queued using link state")
host.isNetworkOnline=original_online
host:refreshVisibleShelfProgress({}, books, cache, { on_redraw = function() redrawn = redrawn + 10 end })
expect(#tasks == 1, "cover redraw restarted an identical progress request")
local result = tasks[1].options.task(ctx)
expect(#result.snapshots == 1 and result.snapshots[1].book_id == "900002", "fresh cache not respected")
tasks[1].options.on_done { ok = true, value = result }
expect(#writes == 1 and redrawn == 10, "completion did not redraw latest view")
host:refreshVisibleShelfProgress({}, books, cache, { force = true })
local stale_task = tasks[#tasks]
expect(#stale_task.options.task(ctx).snapshots == 2, "manual force did not bypass fresh cache")
host:refreshVisibleShelfProgress({}, { { bookId = "900003" } }, {}, {})
expect(cancellations[#cancellations] == stale_task, "page change did not cancel old request")
stale_task.options.on_done { ok = true, value = result }
expect(#writes == 1, "stale page wrote display data")
local current = tasks[#tasks]
account = "account-b"
current.options.on_done { ok = true, value = result }
expect(#writes == 1, "completion wrote to a different account database")
account = "account-a"
host:cancelShelfProgress()
host:refreshVisibleShelfProgress({}, books, cache, { force = true })
current = tasks[#tasks]
host.discovery_epoch = 1
current.options.on_done { ok = true, value = result }
expect(#writes == 1, "closed epoch wrote snapshots")
host:cancelShelfProgress()
online = false
local count = #tasks
host:refreshVisibleShelfProgress({}, books, {}, {})
expect(#tasks == count, "offline display started HTTP")
online, configured = true, false
host:refreshVisibleShelfProgress({}, books, {}, {})
expect(#tasks == count, "missing API key started HTTP")
configured = true
host:refreshVisibleShelfProgress({}, books, {}, {})
tasks[#tasks].options.on_done { ok = true, value = { snapshots = {}, failed = true } }
count = #tasks
host:refreshVisibleShelfProgress({}, books, {}, {})
expect(#tasks == count and host.shelf_progress_retry_at, "failed service immediately retried")
host.shelf_progress_retry_at = nil
cache["900001"].fetched_at = os.time() - Data.TTL - 1
host:refreshVisibleShelfProgress({}, { books[1] }, cache, {})
expect(#tasks == count + 1, "expired snapshot not refreshed")
host:cancelShelfProgress()
configured=false
cookies={wr_vid="900000",wr_skey="synthetic-web-access"}
client.get_shelf_display_progress=function(_self,id,access)
    expect(access.kind=="web" and access.cookies.wr_skey=="synthetic-web-access","keyless read used wrong captured access")
    return {book={bookId=id,progress=42.7}}
end
host:refreshVisibleShelfProgress({},books,{}, {force=true})
current=tasks[#tasks]
result=current.options.task(ctx)
expect(#result.snapshots==2 and result.snapshots[1].percent==42 and result.snapshots[1].source=="web","Web display projection")
local written=#writes
cookies={wr_vid="900000",wr_skey="replacement-web-access"}
current.options.on_done{ok=true,value=result}
expect(#writes==written,"Cookie replacement accepted old progress")
host:refreshVisibleShelfProgress({},books,{}, {force=true})
current=tasks[#tasks]
scope.epoch=2
current.options.on_done{ok=true,value=result}
expect(#writes==written,"new login epoch accepted old progress")
scope_valid=false
expect(not Data.selection(settings),"unverified account scope accepted")
scope_valid=true
cookies={wr_vid="900099",wr_skey="synthetic-web-access"}
expect(not Data.selection(settings),"wrong cookie account accepted")
cookies={wr_vid="900000",wr_skey="synthetic-web-access"}
configured=true
local routes={}
client.get_shelf_display_progress=function(_self,id,access)
    routes[#routes+1]=access.kind
    if access.kind=="gateway" then error("private-service-response") end
    if id=="900001" then return {recordReadingTime=12} end
    return {book={bookId=id,progress=42}}
end
batch=Data.fetch(client,{"900001","900002","900003"},ctx)
expect(not batch.failed and #batch.snapshots==3 and batch.snapshots[1].unavailable and batch.snapshots[1].percent==nil
    and table.concat(routes,",")=="gateway,web,web,web",
    "gateway retry flooded source or duration-only response stopped the batch")
routes={}
client.get_shelf_display_progress=function(_self,id,access)
    routes[#routes+1]=access.kind
    return {errcode=-1,book={bookId=id,progress=99}}
end
batch=Data.fetch(client,{"900001","900002"},ctx)
expect(batch.failed and #batch.snapshots==0 and #routes==2,"rejected response became a progress or flooded the batch")
configured=false
client.get_shelf_display_progress=function(_self,id)
    cookies={}
    return {book={bookId=id,progress=42}}
end
batch=Data.fetch(client,{"900001","900002"},ctx)
expect(batch.stale and #batch.snapshots==0,"child retained progress after access change")
for _,id in ipairs({false,"MP_WXS_test","900001&other=value",-1,0,"0","","900001\n"}) do
    expect(not Data.book_id(id),"ineligible book entered Web read")
end
host:cancelShelfProgress()
cookies={wr_vid="900000",wr_skey="synthetic-web-access"}
local count_before=#tasks
host:refreshVisibleShelfProgress({}, {books[1]}, {["900001"]={unavailable=true,fetched_at=os.time()}}, {})
expect(#tasks==count_before,"fresh unavailable position was repeatedly fetched")
expect(Data.display({}, {unavailable=true}, "account-a", "900001")==nil,"duration-only cache invented 0 percent")

local progress_id='900002'
for _,case in ipairs({
    {name='new cache time and origin', old={percent=37,exact_percent=37,source='gateway'},
        new={percent=37,exact_percent=37,source='web'}},
    {name='unavailable progress stays hidden', new={unavailable=true}},
    {name='legacy zero becomes known', old={percent=0}, new={percent=0,exact_percent=0}, repaint=true},
    {name='a sub-one-percent position replaces zero', old={percent=0,exact_percent=0},
        new={percent=0,exact_percent=0.25}, repaint=true},
    {name='a known position disappears', old={percent=37}, new={unavailable=true}, repaint=true},
}) do
    local previous_writes,previous_redraws=#writes,redrawn
    case.new.book_id,case.new.fetched_at=progress_id,os.time()
    host:refreshVisibleShelfProgress(host.shelf_view,{books[2]},{[progress_id]=case.old},
        {force=true,on_redraw=function() redrawn=redrawn+1 end})
    tasks[#tasks].options.on_done{ok=true,value={snapshots={case.new}}}
    expect(#writes==previous_writes+1 and writes[#writes][1]==case.new,'snapshot not saved: '..case.name)
    expect(redrawn==previous_redraws+(case.repaint and 1 or 0),'incorrect redraw: '..case.name)
end
local previous_redraws=redrawn
local updated={book_id=progress_id,percent=37,exact_percent=37,fetched_at=os.time()}
local refresh={force=true,on_redraw=function() redrawn=redrawn+1 end}
host:refreshVisibleShelfProgress(host.shelf_view,{books[2]},{},refresh)
local carried=tasks[#tasks]
host.shelf_view={}
host:refreshVisibleShelfProgress(host.shelf_view,{books[2]},{[progress_id]=updated},refresh)
expect(tasks[#tasks]==carried,'rebuilding the same page restarted its progress worker')
carried.options.on_done{ok=true,value={snapshots={updated}}}
expect(redrawn==previous_redraws,'progress was compared with the view that had already closed')

local original_credentials=package.loaded['weread.lib.native_credentials']
local grant={vid=scope.vid,accessToken='synthetic-native-access'}
local native_revision,native_pending=1,false
package.loaded['weread.lib.native_credentials']={new=function()
    return {read=function() return grant,native_revision,nil,native_pending end}
end}
settings.data_dir='/unused'
cookies={}
local native_access=Data.selection(settings)
expect(native_access and native_access.native and not Data.supports('CB_Example',native_access),'native-only routing')
local native_calls,reply,rotate=0,nil,false
function client:request(options)
    native_calls=native_calls+1
    expect(options.url=='https://i.weread.qq.com/book/getProgress?bookId=900001'
        and options.method=='GET' and options.skip_cookie and options.persist_response_cookies==false
        and options.headers.accessToken==grant.accessToken and not options.headers.Cookie,'native display request')
    if rotate then native_revision=native_revision+1 end
    return 'synthetic response',200
end
function client:json_decode() return reply end
reply={bookId='900001',book={progress=0.25,summary='private position'}}
batch=Data.fetch(client,{'900001'},ctx,native_access)
expect(#batch.snapshots==1 and batch.snapshots[1].source=='native' and batch.snapshots[1].exact_percent==0.25
    and batch.snapshots[1].summary==nil,'native display imported raw response or lost precision')
reply={book={progress=0}}
batch=Data.fetch(client,{'900001','900002'},ctx,native_access)
expect(batch.failed and #batch.snapshots==0 and native_calls==2,'native display accepted progress without book identity')
reply={bookId='900001',recordReadingTime=2}
batch=Data.fetch(client,{'900001'},ctx,native_access)
expect(batch.failed and #batch.snapshots==0,'native display inferred zero from recorded time')
reply={bookId='900001',book={progress=0}}
rotate=true
batch=Data.fetch(client,{'900001'},ctx,native_access)
expect(batch.stale and #batch.snapshots==0,'replaced E-Ink grant allowed a result into the cache')
native_pending=true
expect(not Data.selection(settings),'pending native renewal allowed a new display request')
package.loaded['weread.lib.native_credentials']=original_credentials
print("shelf_progress_spec: " .. checks .. " checks")
