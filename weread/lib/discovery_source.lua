-- Session-bound, display-only bookstore routing. Native first, then Skill.
local Crypto = require("weread.lib.crypto")
local Data = require("weread.lib.discovery_data")
local Native = require("weread.lib.native_read_access")
local Auth = require("weread.lib.native_authorization")
local M = {}
local function fail(reason) error("discovery/" .. reason, 0) end

function M.capture(settings, store)
    if not settings then return nil,"login_required" end
    local scope = settings.get_auth_scope and settings:get_auth_scope()
    if settings.get_auth_scope and (not scope or not settings:auth_scope_matches(scope)) then return nil,"login_required" end
    local key = settings:get("api_key", "")
    if type(key) ~= "string" or key == "" or #key > 4096 or key:find("[%z%c%s]") then key = nil end
    local native = Native.capture(settings, store)
    if not native and not key then return nil,"native_required" end
    local base = Crypto.sha256_hex((key or "") .. "\0" .. (scope and scope.vid or "") .. "\0" .. tostring(scope and scope.epoch or ""))
    return { native = native, api_key = key, base_revision = base,
        revision = Crypto.sha256_hex((native and native.fingerprint or "") .. "\0" .. (key or "")
            .. "\0" .. (scope and scope.vid or "") .. "\0" .. tostring(scope and scope.epoch or "")) }
end

function M.matches(settings, selected)
    if not selected then return false end
    local current = M.capture(settings, selected.native and selected.native.store)
    return current ~= nil and current.revision == selected.revision
end

local function array(value)
    if type(value) ~= "table" or #value > 100 then return false end
    for key in pairs(value) do if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #value then return false end end
    return true
end
local function bounded(value, limit)
    return type(value)=="string" and #value<=limit and not value:find("[%z%c]")
end

function M.project(client, kind, data, cursor)
    if type(data) ~= "table" or (data.errcode ~= nil and tonumber(data.errcode) ~= 0)
        or (data.errCode ~= nil and tonumber(data.errCode) ~= 0)
        or (data.succ ~= nil and data.succ ~= true and tonumber(data.succ) ~= 1) then fail("invalid_page") end
    local container = kind=="similar" and data.booksimilar or data
    if type(container)~="table" then fail("invalid_page") end
    local lists={}
    local mt = client.json_decode and getmetatable(client:json_decode("[]"))
    if kind=="search" and data.results~=nil then
        if not array(data.results) or (#data.results==0 and mt and getmetatable(data.results)~=mt) then fail("invalid_page") end
        for _,group in ipairs(data.results) do
            if type(group)~="table" or not array(group.books) then fail("invalid_page") end
            lists[#lists+1]=group.books
        end
    else lists[1]=container.books end
    local count=0
    if #lists==0 and not (kind=="search" and data.results~=nil) then fail("invalid_page") end
    for _,rows in ipairs(lists) do
        if not array(rows) or (#rows==0 and mt and getmetatable(rows)~=mt) then fail("invalid_page") end
        count=count+#rows
    end
    if count>100 then fail("invalid_page") end
    local value=Data.page(kind,data,cursor)
    if not bounded(value.session_id or "",512) then fail("invalid_page") end
    for _,book in ipairs(value.books) do
        if not bounded(book.bookId,256) or book.bookId=="" or not bounded(book.title,4096)
            or not bounded(book.author,4096) or not bounded(book.category,4096) or not bounded(book.cover,8192) then fail("invalid_page") end
    end
    if value.next_cursor<0 or value.next_cursor>2147483647 or value.next_cursor%1~=0 then fail("invalid_page") end
    return value
end

function M.fetch(client, request, selected, options)
    options = options or {}
    if request.kind=="category" then
        local value=M.project(client,"category",client:get_category_books(request.category_id,request.cursor,request.rank),request.cursor)
        value.source_kind,value.source_revision="public","public"
        return value
    end
    selected=selected or M.capture(client.settings)
    if not selected then fail("access_required") end
    local function current() if not M.matches(client.settings,selected) then fail("session_changed") end end
    current()
    if request.source_revision and request.source_revision~=selected.revision then fail("source_changed") end
    local kind=request.source_kind or (not options.skip_native and selected.native and "native" or "gateway")
    if kind=="native" then
        if not selected.native then fail("source_changed") end
        local auth=Auth:new(client,{expected_vid=selected.native.scope.vid,is_current=function() return M.matches(client.settings,selected) end})
        local ok,data=pcall(auth.read_discovery,auth,selected.native.credentials,request.kind,request)
        auth:cancel();current()
        if not ok then
            local reason=tostring(data)
            if reason=="native_auth/discovery_"..request.kind.."/http_401" and options.recover_auth
                and not selected.native.renewal_pending then fail("native_expired") end
            local fallback=reason:match("/http_50%d$") or reason:match("/http_40[13]$")
                or reason:match("/transport$") or reason:match("/timeout$")
            if selected.api_key and (request.cursor or 0)==0 and not request.source_kind and fallback then
                local payload=client:get_gateway_discovery(request.kind,request,selected.api_key)
                current()
                local value=M.project(client,request.kind,payload,request.cursor)
                value.source_kind,value.source_revision="gateway",selected.revision
                return value
            end
            fail("native_unavailable")
        end
        local value=M.project(client,request.kind,data,request.cursor)
        value.source_kind,value.source_revision="native",selected.revision
        return value
    elseif kind=="gateway" and selected.api_key then
        local data=client:get_gateway_discovery(request.kind,request,selected.api_key)
        current()
        local value=M.project(client,request.kind,data,request.cursor)
        value.source_kind,value.source_revision="gateway",selected.revision
        return value
    end
    fail("source_changed")
end

return M
