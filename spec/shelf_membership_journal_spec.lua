package.path='./?.lua;'..package.path
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local root=os.tmpname();os.remove(root);assert(os.execute('mkdir -p '..string.format('%q',root)))
local function dump(value)
    if type(value)=='string' then return string.format('%q',value) end
    if type(value)~='table' then return tostring(value) end
    local parts={'{'};for key,item in pairs(value) do parts[#parts+1]='['..dump(key)..']='..dump(item)..',' end;return table.concat(parts)..'}'
end
local function read(path) local file=io.open(path,'rb');if not file then return nil end;local raw=file:read('*a');file:close();return raw end
local function write(path,raw) local file=assert(io.open(path,'wb'));assert(file:write(raw));file:close() end
local mode
package.preload['libs/libkoreader-lfs']=function() return {symlinkattributes=function(path)
    if mode then return mode end
    if read(path) then return 'file' end
end} end
local scope={vid='900000',epoch=1}
local settings={data_dir=root,auth_scope_matches=function(_self,owner) return owner and owner.vid==scope.vid and owner.epoch==scope.epoch end}
local codec={json_encode=function(_self,value) return 'return '..dump(value) end,
    json_decode=function(_self,raw) local fn=assert(loadstring(raw));setfenv(fn,{});return fn() end}
local serial,fail_create,fail_file,fail_sync=0,false,false,false
local deps={nonce=function() serial=serial+1;return string.format('%032x',serial) end,
    sync=function() return not fail_sync end,create=function(directory)
        if fail_create then return nil end
        serial=serial+1;local path=directory..'/output-'..serial;local file=assert(io.open(path,'wb'))
        return {path=path,write=function(_self,raw) return file:write(raw)~=nil end,
            sync=function() return not fail_file and file:flush()~=nil end,
            accept=function(_self,bytes) file:close();return #assert(read(path))==bytes end,
            abort=function(self) pcall(file.close,file);os.remove(self.path) end}
    end}
local Journal=require('weread.lib.shelf_membership_journal')
local journal=Journal:new(settings,codec,deps)
expect(journal:read(scope).phase=='idle','new account did not start without a pending write')
local first=assert(journal:begin(scope,'42','add'))
expect(journal:owns(scope,first) and first.phase=='pending','intent not read back before dispatch')
local reopened=Journal:new(settings,codec,deps)
expect(not reopened:begin(scope,'43','remove') and reopened:owns(scope,first),'restart or other target bypassed pending intent')
expect(reopened:finish(scope,first) and journal:read(scope).phase=='idle','confirmed intent not completed')
local second=assert(journal:begin(scope,'42','remove'))
expect(not journal:finish(scope,first) and journal:owns(scope,second),'old receipt cleared a newer attempt')
local old_scope={vid=scope.vid,epoch=scope.epoch};scope={vid='900000',epoch=2}
expect(not journal:finish(old_scope,second),'old login cleared a pending change')
expect(journal:read(scope).phase=='pending' and not journal:begin(scope,'43','add'),'fresh login replayed an older pending operation')
expect(journal:finish(scope,second),'explicit current-login resolution could not finish older pending attempt')
for _i,kind in ipairs({'create','file','sync'}) do
    fail_create=kind=='create';fail_file=kind=='file';fail_sync=kind=='sync'
    expect(not journal:begin(scope,'42','add'),'failed durability confirmation allowed dispatch: '..kind)
    fail_create,fail_file,fail_sync=false,false,false
    local record=assert(journal:read(scope))
    if kind=='sync' then expect(record.phase=='pending' and not journal:begin(scope,'42','add'),'visible uncertain intent was automatically retried');assert(journal:finish(scope,record))
    else expect(record.phase=='idle','pre-rename failure replaced the primary journal') end
end
local path=journal:path(scope);local good=assert(read(path))
for _i,raw in ipairs({'broken',string.rep('x',2049),'return {schema=1,revision=1,phase="pending"}'}) do
    write(path,raw);expect(not journal:read(scope) and not journal:begin(scope,'42','add'),'corrupt primary was overwritten or dispatched');write(path,good)
end
for _i,value in ipairs({'link','directory'}) do mode=value;expect(not journal:read(scope),'nonregular primary was accepted') end
mode=nil
scope={vid='900001',epoch=1};expect(journal:read(scope).phase=='idle','another account inherited pending state')
expect(not journal:begin(scope,'MP_1','add') and not journal:begin(scope,'42','finish'),'unvalidated operation entered durable journal')
assert(os.execute('rm -rf '..string.format('%q',root)))
print(('shelf_membership_journal_spec: %d checks'):format(checks))
