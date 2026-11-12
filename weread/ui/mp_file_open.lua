-- Intercept the native FileManager document entry before BookList/DocSettings.
-- Keep its provider and callback contract; auxiliary editors are unaffected.
local Resolve=require('weread.lib.mp_file_identity')
local Recovery=require('weread.ui.mp_record_recovery')
local Util=require('weread.lib.plugin_util')
local M={}
local adapters=setmetatable({},{__mode='k'})
local hosts=setmetatable({},{__mode='kv'})
local requests=setmetatable({},{__mode='k'})
local delegating=setmetatable({},{__mode='k'})
local function pack(...) return {n=select('#',...),...} end
local function enabled()
    if not G_reader_settings then return true end
    local disabled=G_reader_settings:readSetting('plugins_disabled',{})
    return not (type(disabled)=='table' and disabled.weread)
        and not G_reader_settings:isTrue('plugins_disable_external')
end
local function active(class,ui,host)
    return host~=nil and hosts[ui]==host and host.ui==ui and ui.weread==host
        and class.instance==ui and not ui.tearing_down and not ui.document and enabled()
end
local function delegate(original,ui,path,args)
    local prior=delegating[ui];delegating[ui]=path
    local result=pack(pcall(original,ui,path,Util.unpack_args(args,1,args.n)))
    delegating[ui]=prior
    if not result[1] then error(result[2],0) end
    return Util.unpack_args(result,2,result.n)
end
local function preserve(host,source)
    local Model=require('weread.lib.mp_record_recovery')
    local rows=Model.freeze(source.input)
    local account=host.library_db and host.library_db:accountKey()
    local store=require('weread.lib.mp_records_db').new(host.settings,account)
    return Model.preserve(store,source.input,rows)
end
function M.cancel(host)
    local ui=host and host.ui
    if ui and hosts[ui]==host then requests[ui]=(requests[ui] or 0)+1;Recovery.cancel(host) end
end
function M.detach(host)
    M.cancel(host)
    if host and hosts[host.ui]==host then hosts[host.ui]=nil end
end
function M.attach(host)
    if not host.ui or host.ui.document or type(host.ui.openFile)~='function' then return false end
    local class=require('apps/filemanager/filemanager')
    if type(class.openFile)~='function' then return false end
    hosts[host.ui]=host
    local installed=adapters[class]
    if installed and class.openFile==installed then return true end
    local original=class.openFile
    local function wrapper(ui,path,...)
        local args=pack(...);local owner=hosts[ui]
        if delegating[ui]==path or not active(class,ui,owner) then return original(ui,path,Util.unpack_args(args,1,args.n)) end
        M.cancel(owner);local token=requests[ui]
        local provider=args[1]
        if provider and (provider.order or provider.provider~='crengine') then return delegate(original,ui,path,args) end
        local ok,source=pcall(Resolve.resolve,owner.settings,path)
        if not ok then
            owner:showInfo(Util.tr('The saved article changed or is unavailable. Reopen its article list and try again.'))
            return false
        end
        if not source then return delegate(original,ui,path,args) end
        if source.input.stamped and not source.input.legacy then return delegate(original,ui,path,args) end
        -- getProvider itself opens DocSettings to read a per-file association.
        -- Keep every raw candidate before allowing that native read as well.
        local saved,good=pcall(preserve,owner,source)
        if not saved or not good then
            owner:showInfo(Util.tr('Could not complete reading record recovery. The original text and saved records are kept. Reopen the article list to check the current version before trying again.'))
            return false
        end
        if provider==nil then provider=require('document/documentregistry'):getProvider(path,true) end
        if not provider or provider.order or provider.provider~='crengine' then return delegate(original,ui,path,args) end
        local function current() return requests[ui]==token and active(class,ui,owner) end
        return Recovery.open(owner,source.book,source.article,path,{context_valid=current,open_file=function(selected)
            if not current() then return end
            owner:closeWeReadUI()
            local target=args
            if selected~=path and not args[1] then
                -- A selected snapshot can contain another per-file provider.
                -- Keep the engine selected for the original article instead.
                target=pack(Util.unpack_args(args,1,args.n));target[1]=provider;target.n=math.max(1,target.n)
            end
            return delegate(original,ui,selected,target)
        end})
    end
    adapters[class]=wrapper;class.openFile=wrapper
    return true
end
return M
