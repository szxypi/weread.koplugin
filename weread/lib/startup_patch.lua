-- A generated, credential-free bridge to KOReader's supported late userpatch.
local Output=require('weread.lib.notes_export_file')
local M={NAME='2-weread-startup-records.lua',MAX_BYTES=16384}
M.__index=M
function M.payload(root)
    if type(root)~='string' or root:sub(1,1)~='/' or #root>3000 or root:find('[%z%c]') then return end
    return '-- WeRead startup record protection v1\nlocal root='..string.format('%q',root)..[=[

local disabled=G_reader_settings:readSetting('plugins_disabled',{})
if type(disabled)=='table' and disabled.weread or G_reader_settings:isTrue('plugins_disable_external') then return end
local fs=require('libs/libkoreader-lfs')
if fs.attributes(root..'/main.lua','mode')~='file' or fs.attributes(root..'/weread/ui/mp_startup_open.lua','mode')~='file' then return end
local prior=package.path
package.path=prior..';'..root..'/?.lua'
local ok,active=pcall(function() return require('weread.ui.mp_startup_open').install() end)
if not ok or not active then
    local logged,logger=pcall(require,'weread.lib.logger')
    if logged then logger.warn('startup record protection could not be loaded') end
    package.path=prior
end
]=]
end
function M.new(root,dependencies)
    dependencies=dependencies or {}
    local fs=dependencies.fs or require('libs/libkoreader-lfs')
    local patches=dependencies.directory or require('datastorage'):getPatchesDir()
    local raw=M.payload(root)
    if not raw or type(patches)~='string' then return end
    return setmetatable({raw=raw,fs=fs,directory=patches,path=patches..'/'..M.NAME,
        read=dependencies.read or function(path,max)
            local file=io.open(path,'rb');if not file then return end
            local content=file:read(max);file:close();return content
        end,
        create=dependencies.create or Output.create,rename=dependencies.rename or os.rename,
        remove=dependencies.remove or os.remove,sync=dependencies.sync or function(path)
            return require('ffi/util').fsyncDirectory(path)==true
        end},M)
end
function M:status()
    local info,_,code=self.fs.symlinkattributes(self.path)
    if not info then return code==2 and 'absent' or 'unavailable' end
    if info.mode~='file' or info.size>M.MAX_BYTES then return 'foreign' end
    local ok,raw=pcall(self.read,self.path,M.MAX_BYTES+1)
    if not ok or raw==nil then return 'unavailable' end
    return raw==self.raw and 'installed' or 'foreign'
end
function M:enable()
    local state=self:status()
    if state=='installed' then return true end
    if state~='absent' then return false end
    local stage
    local ok,good=pcall(function()
        stage=self.create(self.directory,'weread-startup','json')
        if not stage or not stage:write(self.raw) or not stage:sync() or not stage:accept(#self.raw)
            or not stage:owns() or self:status()~='absent' then return false end
        if not self.rename(stage.path,self.path) then return false end
        return self.sync(self.path) and self:status()=='installed'
    end)
    if stage then stage:abort() end
    return ok and good or false
end
function M:disable()
    local state=self:status()
    if state=='absent' then return true end
    if state~='installed' then return false end
    if not self.remove(self.path) then return false end
    return self.sync(self.path) and self:status()=='absent'
end
return M
