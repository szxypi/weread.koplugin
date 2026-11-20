-- Loaded by an opt-in late userpatch, before ReaderUI's first provider read.
-- Existing FileManager/reader entry adapters own all later document switches.
local M = {}
local installed
local pending
local delegating
local function pack(...) return {n=select('#', ...), ...} end
local function enabled()
    if not G_reader_settings then return false end
    local disabled=G_reader_settings:readSetting('plugins_disabled', {})
    return not (type(disabled)=='table' and disabled.weread)
        and not G_reader_settings:isTrue('plugins_disable_external')
end
function M.install()
    local Reader=require('apps/reader/readerui')
    if installed and Reader.showReader==installed then return true end
    if type(Reader.showReader)~='function' then return false end
    local Resolve=require('weread.lib.mp_file_identity')
    local Model=require('weread.lib.mp_record_recovery')
    local Store=require('weread.lib.mp_records_db')
    local Util=require('weread.lib.plugin_util')
    local original=Reader.showReader
    local function delegate(class,path,args)
        local prior=delegating;delegating=true
        local result=pack(pcall(original,class,path,Util.unpack_args(args,1,args.n)))
        delegating=prior
        if not result[1] then error(result[2],0) end
        return Util.unpack_args(result,2,result.n)
    end
    installed=function(class,path,...)
        local args=pack(...)
        local manager_class=package.loaded['apps/filemanager/filemanager']
        if delegating or not enabled() or Reader.instance or manager_class and manager_class.instance then
            return delegate(class,path,args)
        end
        local provider=args[1]
        if provider and (provider.order or provider.provider~='crengine') then return delegate(class,path,args) end
        local settings,source
        local ok,needs_choice=pcall(function()
            settings=require('weread.lib.settings'):new()
            source=Resolve.resolve(settings,path)
            if not source or source.input.stamped and not source.input.legacy then return false end
            local rows=Model.freeze(source.input)
            local account=require('weread.lib.library_db'):new(settings):accountKey()
            local store=Store.new(settings,account)
            if not Model.preserve(store,source.input,rows) then error('startup_records_unavailable',0) end
            if not Model.matches(settings,source.book,source.article,source.input) then error('startup_source_changed',0) end
            local saved={}
            if store then saved=store:list(source.input.key) end
            if not saved then error('startup_records_unavailable',0) end
            local needed=#rows>0 or #saved>0
            if needed and args[1]==nil then
                args[1]=require('document/documentregistry'):getProvider(path)
                args.n=math.max(1,args.n)
                if not args[1] or args[1].order or args[1].provider~='crengine' then return false end
            end
            return needed
        end)
        if ok and not needs_choice then return delegate(class,path,args) end
        -- Seed preservation precedes FileManager's own first metadata preview.
        -- Its normal plugin instance then owns confirmation/copy/cancellation.
        local request={};pending=request
        local FM=require('apps/filemanager/filemanager')
        FM:showFiles(type(path)=='string' and path:match('^(.*)/[^/]+$') or nil)
        local manager=FM.instance
        local host=manager and manager.weread
        if not host or not enabled() then pending=nil;return false end
        if not ok then
            pending=nil
            host:showInfo(Util.tr('Could not complete reading record recovery. The original text and saved records are kept. Reopen the article list to check the current version before trying again.'))
            return false
        end
        local account=host.library_db:accountKey()
        local function current()
            return pending==request and not request.cancelled and FM.instance==manager and manager.weread==host
                and not manager.tearing_down and not Reader.instance and enabled()
                and host.library_db:accountKey()==account
        end
        local result=require('weread.ui.mp_record_recovery').open(host,source.book,source.article,path,{
            context_valid=current,on_cancel=function() request.cancelled=true end,open_file=function(selected)
                if not current() then return end
                pending=nil
                -- The original engine was captured only after preservation,
                -- before a snapshot's provider association can be restored.
                host:closeWeReadUI()
                return delegate(class,selected,args)
            end})
        -- A cancelled startup stays in FileManager, whose ordinary open guard
        -- handles subsequent choices. Do not block future normal core entries.
        if not host.mp_records_job then pending=nil end
        return result
    end
    Reader.showReader=installed
    return true
end
return M
