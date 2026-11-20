package.path = "./?.lua;" .. package.path
local ffi = require("ffi")
local Store, decoded = {}, {}
package.loaded["weread.lib.native_credentials"] = Store
package.loaded.json = { decode = function(value) return decoded[value] end, util = { null = function() end } }
local Crypto = require("weread.lib.crypto")
local checks = 0
local function expect(value, label) checks = checks + 1; assert(value, label) end
local old = { vid = "900000", accessToken = "old-synthetic-access", refreshToken = "synthetic-refresh", deviceId = "eink334691225" .. string.rep("1",19) }
local function fixture(permit, mode)
    local input = { vid = old.vid, book_id = "900001", chapter_uid = "2", shelf_books = 139,
        annotations = { credentials = old, permit_renewal = permit, intent_digest = string.rep("a",64),
            ranges = { "1-2" }, digest = string.rep("a",64), source_quotes_digest = string.rep("b",64), underlines = 1, thought_items = 1 } }
    local counters = ffi.new("int[1024]")
    local case = dofile("spec/koreader/owner_expired_annotations_case.lua")(input, mode or "live", counters)
    case.enabled = true
    local scope = { vid = old.vid, epoch = 1 }
    local store = { settings = { auth_scope_matches = function(_self,value) return value.vid == scope.vid and value.epoch == scope.epoch end } }
    local request = { url = "https://i.weread.qq.com/book/underlines?bookId=900001&chapterUid=2&synckey=0", method = "GET",
        skip_cookie = true, persist_response_cookies = false, sensitive = true, headers = { vid = old.vid, accessToken = old.accessToken }, sink = function() return 1 end }
    local sends = 0
    local function dispatch(_client,options)
        sends = sends + 1
        if options.url:find("/login",1,true) then options.sink("login-reply"); return 1,200 end
        if options.url:find("/shelf/sync",1,true) then options.sink("shelf-reply"); return 1,200 end
        return 1,tonumber(counters[20]) == 1 and 401 or 200
    end
    decoded["login-reply"] = { vid = old.vid, accessToken = "new-synthetic-access" }
    decoded["shelf-reply"] = { books = { {},{} } }
    local function login()
        local timestamp, random = os.time()*1000, 7
        decoded.body = { deviceId = old.deviceId,deviceName = "BOOX",deviceType = 3,timestamp = timestamp,random = random,
            trackId = "",refreshToken = old.refreshToken,inBackground = 0,kickType = 1,refCgi = "",
            signature = Crypto.sha256_hex(string.format("%.0f",timestamp)..old.deviceId..random) }
        return { url = "https://i.weread.qq.com/login", method = "POST", body = "body", headers = {},
            skip_cookie = true, persist_response_cookies = false, sensitive = true, sink = function() return 1 end }
    end
    return { case=case,counters=counters,store=store,scope=scope,request=request,dispatch=dispatch,login=login,sends=function() return sends end }
end
local f = fixture(false)
f.case:request({},f.request,f.dispatch)
expect(f.counters[23] == 401 and f.sends() == 1,"expiry read was not recorded")
expect(not pcall(Store._write,f.store,old,f.scope,1,true),"dry mode wrote a renewal intent")
expect(not pcall(f.case.request,f.case,{},f.login(),f.dispatch) and f.sends() == 1,"dry mode sent authentication")
f = fixture(true)
expect(not pcall(f.case.request,f.case,{},f.login(),f.dispatch) and f.sends() == 0,"authentication ran before observed expiry")
f = fixture(true)
f.case:request({},f.request,f.dispatch)
expect(Store._write(f.store,old,f.scope,1,true),"parent pending transition refused")
local auth = f.login()
f.case:request({},auth,f.dispatch)
expect(f.counters[24] == 1 and f.sends() == 2,"one authentication dispatch was not counted")
expect(not pcall(f.case.request,f.case,{},auth,f.dispatch) and f.sends() == 2,"authentication was replayed")
local shelf = { url = "https://i.weread.qq.com/shelf/sync",method = "GET",headers = { vid = old.vid,accessToken = "new-synthetic-access" },
    skip_cookie = true,persist_response_cookies = false,sensitive = true,sink = function() return 1 end }
f.case:request({},shelf,f.dispatch)
expect(f.counters[26] == 200 and f.counters[27] == 2,"verification shelf was not bound")
local renewed = { vid = old.vid,accessToken = "new-synthetic-access",refreshToken = old.refreshToken,deviceId = old.deviceId,book_count = 2 }
local bad = {};for key,value in pairs(renewed) do bad[key] = value end;bad.accessToken = "foreign-synthetic"
expect(not pcall(Store._write,f.store,bad,f.scope,2),"unbound token passed the login hash")
-- Use a fresh fixture for the exact successful two-write receipt.
f = fixture(true)
f.case:request({},f.request,f.dispatch);Store._write(f.store,old,f.scope,1,true)
f.case:request({},f.login(),f.dispatch);f.case:request({},shelf,f.dispatch)
expect(Store._write(f.store,renewed,f.scope,2),"confirmed grant could not commit")
f.request.headers.accessToken = renewed.accessToken
f.case:request({},f.request,f.dispatch)
expect(f.counters[20] == 2,"fresh access did not allow the one resumed chapter read")
local rows = {};for index = 1,31 do rows[index] = { range = index.."-"..(index+1) } end
f.case:before_fetch { _prepareAnnotationContext = function() return { store = { get = function()
    return { source_kind = "native",underlines = rows }
end } } end }
local body = { bookId = "900001",chapterUid = 2,cht2sMode = "",reviews = {} }
for index = 1,30 do body.reviews[index] = { range = rows[index].range,maxIdx = 0,count = 30,synckey = 0 } end
decoded.reviews = body
local review_request = { url = "https://i.weread.qq.com/book/readreviews",method = "POST",body = "reviews",headers = f.request.headers,
    skip_cookie = true,persist_response_cookies = false,sensitive = true }
f.case:request({},review_request,f.dispatch)
body.reviews = { { range = "31-32",maxIdx = 0,count = 30,synckey = 0 } }
f.case:request({},review_request,f.dispatch)
expect(f.counters[21] == 2,"saved checkpoint ranges were not covered in two bounded batches")
expect(not pcall(f.case.request,f.case,{},review_request,f.dispatch),"thought batch was replayed")
f.case:finish();local private = f.case:private()
expect(private.credentials.accessToken == renewed.accessToken and private.recovery.saved_revision == 3,"private confirmed grant was lost")
for _i,change in ipairs({ function(r) r.headers.Cookie = "synthetic-cookie" end,
    function(r) r.headers.Authorization = "synthetic-bearer" end,
    function(r) r.url = r.url.."&extra=1" end,
    function(r) r.headers.accessToken = "wrong-synthetic" end,
    function(r) r.persist_response_cookies = true end }) do
    f = fixture(true);change(f.request)
    expect(not pcall(f.case.request,f.case,{},f.request,f.dispatch) and f.sends() == 0,"scope mutation dispatched a request")
end
f = fixture(false,"reopen")
expect(not pcall(f.case.request,f.case,{},f.request,f.dispatch) and f.sends() == 0,"offline reopen contacted native service")
print("owner_expiry_probe_spec: "..checks.." checks")
