-- BookList metadata loading can remove invalid DocSettings candidates.
-- Protect old article candidates at the actual native read, including the
-- first FileManager layout, without intercepting unrelated DocSettings calls.
local Resolve = require('weread.lib.mp_file_identity')
local Model = require('weread.lib.mp_record_recovery')
local Store = require('weread.lib.mp_records_db')
local Util = require('weread.lib.plugin_util')
local M = {}
local hosts = setmetatable({}, {__mode='kv'})
local newest = setmetatable({}, {__mode='v'})
local adapters = setmetatable({}, {__mode='k'})
local frame
local unavailable = {}
local function pack(...) return {n=select('#', ...), ...} end
local function enabled()
    if not G_reader_settings then return true end
    local disabled = G_reader_settings:readSetting('plugins_disabled', {})
    return not (type(disabled)=='table' and disabled.weread)
        and not G_reader_settings:isTrue('plugins_disable_external')
end
local function valid(host)
    local ui = host and host.ui
    if not ui or hosts[ui]~=host or ui.weread~=host or ui.tearing_down or not enabled() then return false end
    local class = package.loaded[ui.document and 'apps/reader/readerui' or 'apps/filemanager/filemanager']
    -- FileManager builds its first list before assigning class.instance.
    return class and (class.instance==ui or class.instance==nil and newest[1]==host)
end
local function owner()
    for _i, key in ipairs({'apps/reader/readerui', 'apps/filemanager/filemanager'}) do
        local class = package.loaded[key]
        local host = class and hosts[class.instance]
        if valid(host) then return host end
    end
    if valid(newest[1]) then return newest[1] end
end
local function account(host)
    return host.library_db and host.library_db:accountKey() or false
end
local function protect(scope, path)
    if scope.inspect then error(unavailable, 0) end
    scope.inspect = true
    local ok, good = pcall(function()
        local host = scope.host
        if not valid(host) or account(host)~=scope.account then return false end
        local source = Resolve.resolve(host.settings, path)
        if not source or source.input.stamped and not source.input.legacy then return true end
        local rows = Model.freeze(source.input)
        local store = Store.new(host.settings, scope.account)
        if not Model.preserve(store, source.input, rows) then return false end
        return valid(host) and account(host)==scope.account
            and Model.matches(host.settings, source.book, source.article, source.input)
    end)
    scope.inspect = nil
    if not ok or not good then error(unavailable, 0) end
end
local function install(object, key, build)
    local installed = adapters[object]
    if installed and object[key]==installed[key] then return end
    local wrapper = build(object[key])
    adapters[object] = installed or {}; adapters[object][key] = wrapper
    object[key] = wrapper
end
function M.detach(host)
    if host and hosts[host.ui]==host then hosts[host.ui]=nil end
    if newest[1]==host then newest[1]=nil end
end
function M.attach(host)
    if not host.ui or not host.ui.document and type(host.ui.openFile)~='function' then return false end
    local list, doc = require('ui/widget/booklist'), require('docsettings')
    if type(list.getBookInfo)~='function' or type(doc.open)~='function' then return false end
    hosts[host.ui], newest[1] = host, host
    install(doc, 'open', function(original) return function(self, path, ...)
        local scope = frame
        if not scope or scope.path~=path or scope.delegating then return original(self, path, ...) end
        protect(scope, path)
        scope.delegating = true
        local result = pack(pcall(original, self, path, ...))
        scope.delegating = nil
        if not result[1] then error(result[2], 0) end
        return Util.unpack_args(result, 2, result.n)
    end end)
    install(list, 'getBookInfo', function(original) return function(path, ...)
        local current_host = owner()
        if not current_host then return original(path, ...) end
        local prior = frame
        frame = {host=current_host, path=path, account=account(current_host)}
        local result = pack(pcall(original, path, ...))
        frame = prior
        if not result[1] then
            if result[2]==unavailable then
                -- Do not cache a failed inspection as a real progress value.
                -- Use BookList's empty-metadata appearance: progress shows a
                -- dash. An unknown status would break native history counts,
                -- while been_opened=true would display a fabricated 0%.
                return {been_opened=false, _weread_metadata_unavailable=true}
            end
            error(result[2], 0)
        end
        return Util.unpack_args(result, 2, result.n)
    end end)
    return true
end
return M
