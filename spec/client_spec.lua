package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local timeout_calls = {}
local reset_count = 0
local requests = {}
local responses = {}
local logs = {}

package.preload["ltn12"] = function()
    return {
        source = {
            string = function(value)
                return function() return value end
            end,
        },
    }
end
package.preload["logger"] = function()
    local function capture(level, ...)
        local parts = { level }
        for i = 1, select("#", ...) do
            parts[#parts + 1] = tostring(select(i, ...))
        end
        logs[#logs + 1] = table.concat(parts, " ")
    end
    return {
        info = function(...) capture("info", ...) end,
        err = function(...) capture("error", ...) end,
        warn = function(...) capture("warn", ...) end,
    }
end
package.preload["socketutil"] = function()
    return {
        set_timeout = function(_self, block, total)
            timeout_calls[#timeout_calls + 1] = { block, total }
        end,
        reset_timeout = function()
            reset_count = reset_count + 1
        end,
        table_sink = function(target)
            return function(chunk)
                if chunk then target[#target + 1] = chunk end
                return 1
            end
        end,
    }
end
package.preload["socket.http"] = function()
    return {
        request = function(options)
            requests[#requests + 1] = options
            local response = table.remove(responses, 1)
            if response.raise then error(response.raise) end
            if options.sink then options.sink(response.body or "") end
            return 1, response.code, response.headers or {}, response.status
        end,
    }
end
package.preload["weread.lib.protocol"] = function()
    return {
        USER_AGENT = "WeRead client spec",
        SKILL_VERSION = "test-skill",
        reader_url = function(id) return "https://weread.qq.com/web/reader/"..tostring(id) end,
        urlencode = function(value)
            return tostring(value):gsub("([^%w%-_%.~])", function(ch)
                return string.format("%%%02X", ch:byte())
            end)
        end,
    }
end

local Client = require("weread.lib.client")
local merged_cookies = {}
local settings = {
    get = function(_self, key, default)
        if key == "cookies" then
            return { wr_skey = "XXX-cookie-value" }
        end
        return default
    end,
    merge_set_cookie = function(_self, value)
        merged_cookies[#merged_cookies + 1] = value
    end,
}
local client = Client:new(settings)

local mock = Client:new({
    mock_endpoint = "http://192.168.31.111:8765",
    get = settings.get,
    merge_set_cookie = function() error("mock must not persist server credentials") end,
})
responses[#responses + 1] = { body = "mock", code = 200, headers = { ["set-cookie"] = "ignored=value" } }
mock:request({ url = "https://weread.qq.com/web/test", headers = {
    Authorization = "Bearer sentinel", ["x-wr-ticket"] = "sentinel", ["x-wrpa-0"] = "sentinel",
    ["Content-Type"] = "application/json", Cookie = "sentinel=value", Host = "weread.qq.com",
} })
expect(requests[1].url == "http://192.168.31.111:8765/__proxy?url=https%3A%2F%2Fweread.qq.com%2Fweb%2Ftest",
    "mock did not route to the LAN endpoint")
expect(requests[1].headers.Authorization == nil and requests[1].headers.Cookie == nil
    and requests[1].headers["x-wr-ticket"] == nil and requests[1].headers["x-wrpa-0"] == nil
    and requests[1].headers.Host == nil, "credentials or original Host leaked to mock")
expect(requests[1].headers["Content-Type"] == "application/json" and requests[1].redirect == false,
    "mock changed payload type or allowed redirects")
expect(requests[1].proxy == mock.settings.mock_endpoint, "mock inherited the global HTTP proxy")
responses[#responses + 1] = { raise = "connection refused" }
local mock_ok = pcall(mock.request, mock, { url = "https://weread.qq.com/web/test" })
expect(not mock_ok and #requests == 2 and requests[2].url:find("192.168.31.111", 1, true),
    "mock failure fell back to production")
requests, timeout_calls, reset_count = {}, {}, 0

responses[#responses + 1] = {
    body = "ok",
    code = 200,
    headers = { ["Set-Cookie"] = "wr_ticket=new-ticket; Path=/" },
}
local body, code = client:request({
    url = "https://weread.qq.com/web/test",
    timeout = { 3, 7 },
})
expect(body == "ok" and code == 200, "basic request result was wrong")
expect(requests[1].headers.Cookie == "wr_skey=XXX-cookie-value",
    "WeRead cookie was not attached")
expect(timeout_calls[1][1] == 3 and timeout_calls[1][2] == 7,
    "request timeout was not applied")
expect(reset_count == 1, "timeout was not reset after successful request")
expect(merged_cookies[1] == "wr_ticket=new-ticket; Path=/",
    "response cookies were not persisted")

responses[#responses + 1] = { body = "public", code = 200 }
client:request({ url = "https://example.com/public" })
expect(requests[2].headers.Cookie == nil,
    "WeRead cookie leaked to a non-WeRead host")

responses[#responses + 1] = { raise = "transport failed" }
local ok, err = pcall(function()
    client:request({ url = "https://weread.qq.com/web/fail" })
end)
expect(not ok and tostring(err):find("transport failed", 1, true),
    "transport error was not propagated")
expect(reset_count == 3, "timeout was not reset after transport error")

responses[#responses + 1] = {
    body = "",
    code = 303,
    headers = { location = "https://cdn.example.net/book" },
}
responses[#responses + 1] = { body = "book", code = 200 }
local redirected, redirected_code, _, _, final_url = client:request_follow({
    url = "https://weread.qq.com/web/export",
    method = "POST",
    body = "{}",
    headers = {
        Authorization = "Bearer secret",
        Cookie = "manual=secret",
        Origin = "https://weread.qq.com",
        ["Content-Length"] = "2",
    },
})
expect(redirected == "book" and redirected_code == 200,
    "redirected response was not returned")
expect(final_url == "https://cdn.example.net/book",
    "final redirect URL was wrong")
local redirected_request = requests[#requests]
expect(redirected_request.method == "GET" and redirected_request.body == nil,
    "303 redirect did not switch POST to GET")
for key in pairs(redirected_request.headers) do
    local lower = tostring(key):lower()
    expect(lower ~= "authorization" and lower ~= "cookie"
        and lower ~= "origin" and lower ~= "content-length",
        "sensitive/entity header survived a cross-origin 303: " .. lower)
end

responses[#responses + 1] = {
    body = "",
    code = 302,
    headers = { location = "/again" },
}
responses[#responses + 1] = {
    body = "",
    code = 302,
    headers = { location = "/again" },
}
ok, err = pcall(function()
    client:request_follow({ url = "https://weread.qq.com/start" }, 1)
end)
expect(not ok and tostring(err):find("Too many redirects", 1, true),
    "redirect limit was not enforced")

logs = {}
responses[#responses + 1] = {
    body = "{\"errcode\":-202,\"errmsg\":\"raw response\"}",
    code = 499,
    headers = { ["content-type"] = "application/json" },
}
ok, err = pcall(function()
    client:get_text("https://weread.qq.com/web/failing-api")
end)
expect(not ok and tostring(err):find("HTTP 499", 1, true),
    "HTTP error details were not preserved")
local raw_response_log = table.concat(logs, "\n")
expect(raw_response_log:find(
    'response_body= {"errcode":-202,"errmsg":"raw response"}',
    1,
    true
), "HTTP failure log omitted the raw response body")

logs = {}
local gateway_settings = {
    get = function(_self, key, default)
        if key == "api_key" then return "private-api-key" end
        return default
    end,
    merge_set_cookie = function() end,
}
local gateway_client = Client:new(gateway_settings)
gateway_client.json_encode = function() return "{}" end
gateway_client.json_decode = function()
    return { errcode = -202, errmsg = "-202" }
end
responses[#responses + 1] = {
    body = '{"errcode":-202,"errmsg":"-202"}',
    code = 499,
    headers = { ["content-type"] = "application/json" },
}
ok = pcall(function()
    gateway_client:gateway("/shelf/sync", {})
end)
expect(not ok, "gateway HTTP failure was not propagated")
local gateway_failure_log = table.concat(logs, "\n")
expect(gateway_failure_log:find("api= /shelf/sync", 1, true),
    "gateway failure log omitted the logical API name")
expect(requests[#requests].diagnostic_api == nil,
    "diagnostic API metadata leaked into the HTTP request options")

logs = {}
client.json_decode = function(_self, _text)
    return { errcode = -300, errmsg = "application failure" }
end
local application_result = client:decode_http_json(
    '{"errcode":-300,"errmsg":"application failure"}',
    {
        method = "POST",
        url = "https://i.weread.qq.com/api/agent/gateway",
        code = 200,
        headers = { ["content-type"] = "application/json" },
    }
)
expect(application_result.errcode == -300,
    "application error response was not returned to the caller")
local application_error_log = table.concat(logs, "\n")
expect(application_error_log:find(
    'response_body= {"errcode":-300,"errmsg":"application failure"}',
    1,
    true
), "application failure log omitted the raw response body")

logs = {}
client.json_decode = function()
    error("invalid JSON")
end
ok, err = pcall(function()
    client:decode_http_json("<not-json>", {
        method = "GET",
        url = "https://weread.qq.com/web/invalid-json",
        code = 200,
    })
end)
expect(not ok and tostring(err):find("invalid JSON", 1, true),
    "JSON decode failure was not preserved")
local decode_failure_log = table.concat(logs, "\n")
expect(decode_failure_log:find("response_body= <not-json>", 1, true),
    "JSON decode failure log omitted the raw response body")

local shelf_client = Client:new(settings)
shelf_client.gateway = function(_self, api_name, params)
    expect(api_name == "/shelf/sync", "shelf helper used the wrong endpoint")
    expect(type(params) == "table" and next(params) == nil,
        "shelf helper unexpectedly sent parameters")
    return {
        books = { { bookId = "private-book-id", title = "Private title" } },
        archive = {},
        albums = {},
        mp = {},
    }, 200, {}
end
local shelf = shelf_client:get_shelf()
expect(#shelf.books == 1, "shelf helper did not return the response")
local success_log = table.concat(logs, "\n")
expect(success_log:find("api=/shelf/sync", 1, true),
    "shelf diagnostics omitted the endpoint")
expect(success_log:find("skill_version= test-skill", 1, true),
    "shelf diagnostics omitted the skill version")
expect(success_log:find("books= table(1)", 1, true),
    "shelf diagnostics omitted the response shape")
expect(not success_log:find("private-book-id", 1, true)
    and not success_log:find("Private title", 1, true),
    "shelf diagnostics leaked response contents")

logs = {}
shelf_client.gateway = function()
    error("HTTP 499, error_code=-202, error_message=-202")
end
ok, err = pcall(function()
    shelf_client:get_shelf()
end)
expect(not ok and tostring(err):find("error_code=-202", 1, true),
    "shelf helper did not preserve the gateway error")
local failure_log = table.concat(logs, "\n")
expect(failure_log:find("shelf sync failed", 1, true),
    "shelf failure diagnostics were not written")

local review_client = Client:new(settings)
local ok_review, data_review, err_review
ok_review, _, err_review = review_client:get_review_comments("")
expect(not ok_review and err_review == "empty review_id",
    "review comments rejected an empty review_id")

responses[#responses + 1] = {
    body = '{"reviewId":"r1","comments":[{"content":"hi"}],"commentsCount":1}',
    code = 200,
    headers = { ["content-type"] = "application/json" },
}
review_client.json_decode = function(_self, text)
    return { reviewId = "r1", comments = { { content = "hi" } }, commentsCount = 1, _raw = text }
end
local review_request_index = #requests + 1
ok_review, data_review, err_review = review_client:get_review_comments("r1", 60)
expect(ok_review and type(data_review) == "table"
    and data_review.commentsCount == 1 and err_review == nil,
    "review comments did not return parsed data")
local review_request = requests[review_request_index]
local review_url = review_request and review_request.url or ""
expect(review_url:find("/web/review/single?", 1, true)
    and review_url:find("reviewId=r1", 1, true)
    and review_url:find("commentsCount=60", 1, true)
    and review_url:find("commentsDirection=0", 1, true)
    and review_url:find("likesCount=0", 1, true)
    and review_url:find("synckey=0", 1, true),
    "review comments built the wrong URL: " .. tostring(review_url))

responses[#responses + 1] = { body = "not-json", code = 200 }
review_client.json_decode = function()
    error("invalid JSON")
end
ok_review, data_review, err_review = review_client:get_review_comments("r2")
expect(not ok_review and data_review == "not-json" and err_review == "invalid JSON",
    "review comments did not surface JSON decode failures")

responses[#responses + 1] = { body = "", code = 200 }
ok_review, _, err_review = review_client:get_review_comments("r3")
expect(not ok_review and err_review == "empty response",
    "review comments did not reject an empty body")

local download_path = os.tmpname()
os.remove(download_path)
responses[#responses + 1] = {
    body = "redirect-body-must-be-discarded",
    code = 302,
    headers = { location = "https://cdn.example.net/asset" },
}
responses[#responses + 1] = { body = "streamed-asset", code = 200 }
local saved_path, saved_bytes = client:download_to_file(
    "https://weread.qq.com/resource", download_path, { max_bytes = 1024 })
local saved_file = assert(io.open(saved_path, "rb"))
local saved_body = saved_file:read("*a")
saved_file:close()
expect(saved_body == "streamed-asset" and saved_bytes == #saved_body,
    "file download retained a redirect body or returned the wrong size")
os.remove(download_path)

responses[#responses + 1] = { body = "too-large", code = 200 }
ok = pcall(function()
    client:download_to_file(
        "https://weread.qq.com/large", download_path, { max_bytes = 2 })
end)
expect(not ok and io.open(download_path .. ".part", "rb") == nil,
    "oversized file download did not remove its partial output")

local public_client = Client:new(settings)
public_client.json_decode = function(_self, text) return { payload = text } end
responses[#responses + 1] = { body = "categories", code = 200 }
expect(public_client:get_store_categories().payload == "categories", "categories JSON not decoded")
local public_request = requests[#requests]
expect(public_request.url == "https://weread.qq.com/web/categories?rank=1&synckey=0"
    and public_request.headers.Cookie == nil and public_request.headers.Authorization == nil,
    "public category request attached authentication or changed endpoint")
responses[#responses + 1] = { body = "rank-books", code = 200 }
expect(public_client:get_category_books("rising", 20, true).payload == "rank-books",
    "rank books JSON not decoded")
public_request = requests[#requests]
expect(public_request.url == "https://weread.qq.com/web/bookListInCategory/rising?rank=1&maxIndex=20"
    and public_request.headers.Cookie == nil, "rank cursor or authentication incorrect")
responses[#responses + 1] = { body = "category-books", code = 200 }
public_client:get_category_books("100000", 0, false)
expect(requests[#requests].url:find("rank=0&maxIndex=0", 1, true), "category request used ranking flag")
local before_invalid = #requests
expect(not pcall(public_client.get_category_books, public_client, "../../bad", 0), "invalid category path accepted")
expect(not pcall(public_client.get_category_books, public_client, "rising", -1), "negative cursor accepted")
expect(not pcall(public_client.get_category_books, public_client, "rising", math.huge), "infinite cursor accepted")
expect(not pcall(public_client.get_category_books, public_client, "rising", 0.5), "fractional cursor accepted")
expect(#requests == before_invalid, "invalid category inputs sent HTTP")
logs = {}
responses[#responses + 1] = { body = "private-response-token", code = 401, headers = { location = "private-location" } }
client:request({ url = "https://i.weread.qq.com/login?private-session", skip_cookie = true,
    sensitive = true, diagnostic_api = "native_login" })
expect(requests[#requests].sensitive == nil, "sensitivity flag leaked into HTTP library options")
local sensitive_log = table.concat(logs, "\n")
expect(sensitive_log:find("native_login", 1, true) and sensitive_log:find("401", 1, true), "redacted diagnostic omitted stage/status")
expect(not sensitive_log:find("private-", 1, true), "sensitive HTTP response, URL or headers were logged")
responses[#responses + 1] = { raise = "private-transport-token-url" }
ok, err = pcall(client.request, client, { url = "https://i.weread.qq.com/login?private-session", skip_cookie = true,
    sensitive = true, diagnostic_api = "native_login" })
expect(not ok and not tostring(err):find("private-", 1, true), "sensitive transport exception was exposed")
expect(not table.concat(logs, "\n"):find("private-", 1, true), "sensitive transport details were logged")
responses[#responses + 1] = { code = "private-status", body = "private-response" }
client:request({ url = "https://i.weread.qq.com/login?private-session", sensitive = true, diagnostic_api = "native_login" })
expect(not table.concat(logs, "\n"):find("private-", 1, true), "unavailable sensitive response leaked diagnostics")
logs = {}
client.json_decode = function() error("private-parser-body") end
ok, err = pcall(client.decode_http_json, client, "private-malformed-payload", {
    sensitive = true, url = "https://weread.qq.com/?private-session", api_name = "qr_login", code = 200 })
expect(not ok and not tostring(err):find("private-", 1, true), "sensitive JSON exception leaked body")
client.json_decode = function() return { errcode = 123, accessToken = "private-token" } end
client:decode_http_json("private-error-body", { sensitive = true, api_name = "qr_login", code = 200 })
expect(not table.concat(logs, "\n"):find("private-", 1, true), "sensitive JSON error diagnostics leaked credentials")
local array_mt = {}
local function array(items) return setmetatable(items or {},array_mt) end
local web_data={books=array{{bookId="900001",title="Synthetic"}},archive=array{{bookIds=array()}}}
client.json_decode=function(_self,value)
    if value=="[]" then return array() end
    if value=="broken" then error("private-shelf-body") end
    return web_data
end
local cookie_count=#merged_cookies
responses[#responses+1]={code=200,body="shelf",headers={["set-cookie"]="ignored=value"}}
expect(client:get_web_shelf({wr_skey="XXX-cookie-value"})==web_data,"Web shelf payload")
local web_request=requests[#requests]
expect(web_request.url=="https://weread.qq.com/web/shelf/sync" and web_request.method=="GET"
    and web_request.headers.Cookie=="wr_skey=XXX-cookie-value" and #merged_cookies==cookie_count,
    "Web shelf changed account cookies or request contract")
expect(type(web_request.create)=="function","HTTPS did not install request-local TLS verification")
for _,web_code in ipairs({302,401,403,503}) do
    responses[#responses+1]={code=web_code,body="private-shelf-response"}
    ok,err=pcall(client.get_web_shelf,client,{})
    expect(not ok and err=="shelf_source/web_unavailable","Web shelf HTTP failure exposed private data")
end
responses[#responses+1]={code=200,body=string.rep("x",4*1024*1024+1)}
expect(not pcall(client.get_web_shelf,client,{}),"oversized shelf was accepted")
responses[#responses+1]={code=200,body="broken"}
ok,err=pcall(client.get_web_shelf,client,{})
expect(not ok and err=="sensitive_json_invalid","Web shelf parser leaked private input")
for _,data in ipairs({{books=array(),errcode=1},{books=array(),succ=false},{books={}},
    {books=array(),archive={}},{books=array(),archive=array{{bookIds={}}}}}) do
    web_data=data
    responses[#responses+1]={code=200,body="shelf"}
    expect(not pcall(client.get_web_shelf,client,{}),"rejected API or empty object was accepted as a shelf")
end
expect(not table.concat(logs,"\n"):find("private-",1,true),"Web shelf failure logged private payload")
local display_data={book={bookId="900001",progress=37.8}}
client.json_decode=function() return display_data end
responses[#responses+1]={code=200,body="progress",headers={["set-cookie"]="ignored=value"}}
expect(client:get_shelf_display_progress("900001",{kind="web",cookies={wr_skey="XXX-display-snapshot"}})==display_data,
    "Web display progress response")
local display_request=requests[#requests]
expect(display_request.method=="GET" and display_request.url=="https://weread.qq.com/web/book/getProgress?bookId=900001"
    and display_request.headers.Cookie=="wr_skey=XXX-display-snapshot" and display_request.headers.Authorization==nil,
    "display read did not use captured Web cookies exclusively")
expect(#merged_cookies==cookie_count,"display read changed live credentials")
local encoded_display
client.json_encode=function(_self,data) encoded_display=data return "{}" end
responses[#responses+1]={code=200,body="progress"}
client:get_shelf_display_progress("900001",{kind="gateway",api_key="captured-display-key"})
display_request=requests[#requests]
expect(display_request.method=="POST" and display_request.headers.Authorization=="Bearer captured-display-key"
    and display_request.headers.Cookie==nil and encoded_display.api_name=="/book/getprogress"
    and encoded_display.bookId=="900001" and encoded_display.skill_version=="test-skill","captured gateway contract")
for _,bad_id in ipairs({"900001&other=value","MP_WXS_test",0,false}) do
    local before=#requests
    expect(not pcall(client.get_shelf_display_progress,client,bad_id,{kind="web",cookies={}}) and #requests==before,
        "invalid display identity sent HTTP")
end
for _,response in ipairs({{code=302,body="private-progress"},{code=401,body="private-progress"},
    {code=429,body="private-progress"},{code=200,body=string.rep("x",65537)},{raise="private-transport-response"}}) do
    responses[#responses+1]=response
    ok,err=pcall(client.get_shelf_display_progress,client,"900001",{kind="web",cookies={}})
    expect(not ok and not tostring(err):find("private-",1,true),"display failure leaked response or exceeded bounds")
end
expect(not table.concat(logs,"\n"):find("private-",1,true),"display request logged raw position or private diagnostics")
local metadata_response={bookId="900001",title="Synthetic metadata",intro="<p>Synthetic introduction</p>",
    publisher="Synthetic publisher",bookVersion=99,progress=99,psvts="private-clock"}
local metadata_state='{"reader":{"bookInfo":{"bookId":"900001","title":"Synthetic"}}}'
client.json_decode=function(_self,value)
    if value==metadata_state then return {reader={bookInfo=metadata_response}} end
    if value=="broken" then error("private-metadata-json") end
    return metadata_response
end
responses[#responses+1]={code=200,body="<script>window.__INITIAL_STATE__="..metadata_state..";(function(){})();</script>",
    headers={["set-cookie"]="ignored=value"}}
local metadata=client:get_display_book_metadata("900001",{kind="web",cookies={wr_skey="XXX-metadata-snapshot"}})
local metadata_request=requests[#requests]
expect(metadata.publisher=="Synthetic publisher" and metadata.bookVersion==nil and metadata.progress==nil and metadata.psvts==nil,
    "Web metadata escaped display projection")
expect(metadata_request.method=="GET" and metadata_request.url=="https://weread.qq.com/web/reader/900001"
    and metadata_request.headers.Cookie=="wr_skey=XXX-metadata-snapshot" and #merged_cookies==cookie_count,
    "Web metadata changed credentials or route")
responses[#responses+1]={code=200,body="metadata"}
metadata=client:get_display_book_metadata("900001",{kind="gateway",api_key="captured-metadata-key"})
metadata_request=requests[#requests]
expect(encoded_display.api_name=="/book/info" and metadata_request.headers.Authorization=="Bearer captured-metadata-key"
    and metadata_request.headers.Cookie==nil and metadata.title=="Synthetic metadata","captured metadata gateway contract")
for _,response in ipairs({{code=302,body="private-metadata"},{code=403,body="private-metadata"},
    {code=200,body=string.rep("x",4*1024*1024+1)},{code=200,body="no initial state"},{raise="private-metadata-transport"}}) do
    responses[#responses+1]=response
    ok,err=pcall(client.get_display_book_metadata,client,"900001",{kind="web",cookies={}})
    expect(not ok and not tostring(err):find("private-",1,true),"metadata failure leaked body or exceeded bounds")
end
expect(not table.concat(logs,"\n"):find("private-",1,true),"metadata response entered diagnostics")
print(("client_spec: %d checks"):format(checks))
