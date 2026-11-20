-- Owner-approved read-only probe. Credentials/metadata pass only in memory.
require("ffi").log = function() end
require("setupkoenv")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open("/tmp/weread-web-probe-settings.lua")
local Device = require("device")
require("document/canvascontext"):init(Device)
package.path = assert(arg[1]) .. "/?.lua;" .. package.path
local json = require("json")
local bytes = io.stdin:read(6*1024*1024+1)
local stage = "normalize"
local function arrays(shelf)
    local array = getmetatable(json.decode("[]"))
    setmetatable(shelf.books,array); setmetatable(shelf.archive,array)
    for _,archive in ipairs(shelf.archive) do setmetatable(archive.bookIds,array) end
    return shelf
end
local ok, result = pcall(function()
    assert(#bytes <= 6*1024*1024)
    local input = json.decode(bytes)
    bytes = nil
    local Source = require("weread.lib.shelf_source")
    local output = {shelf=arrays(Source.normalize(input.shelf,"web")),native_http_verified=false}
    if input.session then
        local session = input.session
        local values = {cookies=session.cookies,api_key="",account={user_vid=session.vid},shelf={source="gateway"}}
        local scope = {vid=session.vid,epoch=1}
        local settings = {
            get=function(_self,key,default) local value=values[key]; if value==nil then return default end return value end,
            get_auth_scope=function() return scope end,
            auth_scope_matches=function(_self,check) return check==scope end,
            update_auth=function(_self,auth) for key,value in pairs(auth) do values[key]=value end end,
        }
        stage="client"
        local client = require("weread.lib.client"):new(settings)
        local request = client.request
        local requests = 0
        function client:request(options)
            local url=options.url
            assert(options.method=="GET" and (url=="https://weread.qq.com/api/userInfo?userVid="..session.vid
                or url=="https://weread.qq.com/api/skills/apikeyGet?only_show=1"
                or url=="https://weread.qq.com/web/shelf/sync"),"readonly_scope_required")
            requests=requests+1
            return request(self,options)
        end
        stage="login_module"
        local login=require("weread.lib.qr_login"):new({},client,settings)
        login.login_cookies=session.cookies
        stage="login_completion"
        local account=login:_complete_protocol({succeed=true,webLoginVid=session.vid,accessToken=session.cookies.wr_skey},login.generation)
        assert(account.user_vid==session.vid)
        output.key_available=values.api_key~=""
        -- Isolate the Web route even if the owner enables Skill later.
        values.api_key=""
        stage="shelf"
        local shelf=Source.fetch(client)
        assert(shelf._shelf_source=="web" and shelf._web_revision)
        shelf._shelf_source=nil; shelf._web_revision=nil
        output.native_shelf=arrays(shelf)
        output.native_http_verified=true
        output.requests=requests
    end
    return output
end)
-- Logs may precede the framed record; the caller captures all output and
-- exposes only aggregate checks. Never print an exception with private data.
io.stdout:write("\nWEREAD_PROBE_RESULT="..json.encode(ok and result or {error="probe_failed",stage=stage}).."\n")
os.exit(ok and 0 or 1)
