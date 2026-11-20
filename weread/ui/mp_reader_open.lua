-- Protect reader history before provider lookup, then recover records before
-- closing the current ReaderUI. All operations use local article caches.
local Resolve=require('weread.lib.mp_file_identity')
local Recovery=require('weread.ui.mp_record_recovery')
local Util=require('weread.lib.plugin_util')
local UI=require('ui/uimanager')
local M={}
local hosts=setmetatable({},{__mode='kv'})
local requests=setmetatable({},{__mode='k'})
local adapters=setmetatable({},{__mode='k'})
local delegating={utility=setmetatable({},{__mode='k'}),switch=setmetatable({},{__mode='k'})}
local function pack(...) return {n=select('#',...),...} end
local function delegate(kind,original,ui,path,args)
    local guards=delegating[kind];local prior=guards[ui];guards[ui]=path
    local result=pack(pcall(original,ui,path,Util.unpack_args(args,1,args.n)))
    guards[ui]=prior
    if not result[1] then error(result[2],0) end
    return Util.unpack_args(result,2,result.n)
end
local function enabled()
    if not G_reader_settings then return true end
    local disabled=G_reader_settings:readSetting('plugins_disabled',{})
    return not (type(disabled)=='table' and disabled.weread) and not G_reader_settings:isTrue('plugins_disable_external')
end
local function owner_scope(host,allow_ui_close)
    return {document=host.ui.document,session=host._reader_session_gen,epoch=not allow_ui_close and host.discovery_epoch or false,
        account=host.library_db and host.library_db:accountKey()}
end
local function active(class,ui,host)
    return host and hosts[ui]==host and host.ui==ui and ui.weread==host and class.instance==ui
        and ui.document and not ui.tearing_down and enabled()
end
local function guard(class,ui,host,token,allow_ui_close)
    local scope=owner_scope(host,allow_ui_close)
    return function()
        if requests[ui]~=token or not active(class,ui,host) then return false end
        local now=owner_scope(host,allow_ui_close)
        for key,value in pairs(scope) do if now[key]~=value then return false end end
        return true
    end
end
local function protect(host,path)
    local ok,source=pcall(Resolve.resolve,host.settings,path)
    if not ok then
        host:showInfo(Util.tr('The saved article changed or is unavailable. Reopen its article list and try again.'));return false
    end
    if not source or source.input.stamped and not source.input.legacy then return nil end
    local saved,good=pcall(function()
        local Model=require('weread.lib.mp_record_recovery')
        local rows=Model.freeze(source.input)
        local account=host.library_db and host.library_db:accountKey()
        local store=require('weread.lib.mp_records_db').new(host.settings,account)
        local ui=host.ui
        if ui.doc_settings and Model.hash_directory(ui.document.file)==Model.hash_directory(source.input.path) then
            ui:handleEvent(require('ui/event'):new('SaveSettings'))
            rows[#rows+1]={kind='live',raw='return '..require('dump')(ui.doc_settings.data,nil,true)}
        end
        return Model.preserve(store,source.input,rows)
    end)
    if not saved or not good then
        host:showInfo(Util.tr('Could not complete reading record recovery. The original text and saved records are kept. Reopen the article list to check the current version before trying again.'))
        return false
    end
    return source
end
function M.cancel(host)
    local ui=host and host.ui
    if not ui or hosts[ui]~=host then return end
    requests[ui]=(requests[ui] or 0)+1
    local dialog=host._mp_reader_open_confirmation;host._mp_reader_open_confirmation=nil
    if dialog then UI:close(dialog) end
    Recovery.cancel(host)
end
function M.detach(host)
    M.cancel(host)
    if host and hosts[host.ui]==host then hosts[host.ui]=nil end
end
local function install(object,key,build)
    local installed=adapters[object]
    if installed and object[key]==installed[key] then return end
    local wrapper=build(object[key]);adapters[object]=installed or {};adapters[object][key]=wrapper;object[key]=wrapper
end
function M.attach(host)
    if not host.ui or not host.ui.document then return false end
    local class=require('apps/reader/readerui')
    local utility=require('apps/filemanager/filemanagerutil')
    if type(class.switchDocument)~='function' or type(utility.openFile)~='function' then return false end
    hosts[host.ui]=host
    install(utility,'openFile',function(original) return function(ui,path,...)
        local args=pack(...);local owner=hosts[ui]
        if delegating.utility[ui]==path or not active(class,ui,owner) then return original(ui,path,Util.unpack_args(args,1,args.n)) end
        M.cancel(owner)
        if ui.document.file==path then return delegate('utility',original,ui,path,args) end
        local source=protect(owner,path)
        if source==false then return end
        if not source then return delegate('utility',original,ui,path,args) end
        local current=guard(class,ui,owner,requests[ui]);local consumed=false
        local function open()
            if consumed or not current() then return end;consumed=true
            local matched,valid=pcall(require('weread.lib.mp_record_recovery').matches,owner.settings,source.book,source.article,source.input)
            if not matched or not valid then
                M.cancel(owner);owner:showInfo(Util.tr('The saved article changed or is unavailable. Reopen its article list and try again.'));return
            end
            args[2]=true;args.n=math.max(2,args.n)
            return delegate('utility',original,ui,path,args)
        end
        if not args[2] and G_reader_settings and G_reader_settings:isTrue('file_ask_to_open') then
            local dialog
            dialog=require('ui/widget/confirmbox'):new{keep_dialog_open=true,
                text=Util.tr('Open this file?')..'\n\n'..require('ui/bidi').filename(path:match('([^/]+)$')),
                ok_text=Util.tr('Open'),ok_callback=function()
                    if owner._mp_reader_open_confirmation~=dialog or not current() then return end
                    owner._mp_reader_open_confirmation=nil;UI:close(dialog);open()
                end,cancel_callback=function() if owner._mp_reader_open_confirmation==dialog then M.cancel(owner) end end}
            local on_close=dialog.onCloseWidget
            dialog.onCloseWidget=function(instance,...)
                if owner._mp_reader_open_confirmation==dialog then owner._mp_reader_open_confirmation=nil;M.cancel(owner) end
                if on_close then return on_close(instance,...) end
            end
            owner._mp_reader_open_confirmation=dialog;UI:show(dialog)
        else return open() end
    end end)
    install(class,'switchDocument',function(original) return function(ui,path,...)
        local args=pack(...);local owner=hosts[ui]
        if delegating.switch[ui]==path or not active(class,ui,owner) then return original(ui,path,Util.unpack_args(args,1,args.n)) end
        M.cancel(owner)
        local provider=args[3]
        if provider and (provider.order or provider.provider~='crengine') then return delegate('switch',original,ui,path,args) end
        local source=protect(owner,path)
        if source==false then return end
        if not source then return delegate('switch',original,ui,path,args) end
        local forced=args[4]
        if not provider then provider,forced=require('document/documentregistry'):getProvider(path,true) end
        if not provider or provider.order or provider.provider~='crengine' then return delegate('switch',original,ui,path,args) end
        -- Recovery closes plugin views itself and captures the resulting UI
        -- epoch; the outer guard keeps the reader/session/request identity.
        local current=guard(class,ui,owner,requests[ui],true)
        Recovery.open(owner,source.book,source.article,path,{context_valid=current,open_file=function(selected)
            if not current() then return end
            owner:closeWeReadUI();requests[ui]=(requests[ui] or 0)+1
            if selected~=path and not args[3] then args[3],args[4]=provider,forced;args.n=math.max(4,args.n) end
            return delegate('switch',original,ui,selected,args)
        end})
    end end)
    return true
end
return M
