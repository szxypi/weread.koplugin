package.path='./?.lua;'..package.path
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local root=os.tmpname();os.remove(root);assert(os.execute('mkdir -p '..string.format('%q',root)))
local mode,serial='normal',0
local function dump(value)
    if type(value)=='string' then return string.format('%q',value) end
    if type(value)~='table' then return tostring(value) end
    local items={'{'};for key,item in pairs(value) do items[#items+1]='['..dump(key)..']='..dump(item)..',' end
    return table.concat(items)..'}'
end
local function write(path,data)
    local file=assert(io.open(path,'wb'));assert(file:write(data));file:close()
end
local function read(path) local file=io.open(path,'rb');if not file then return nil end;local data=file:read('*a');file:close();return data end
local function decode(raw) local fn=assert(loadstring(raw));setfenv(fn,{});return fn() end
package.preload['luasettings']=function() return {open=function(_self,path)
    return {flush=function(self)
        if mode=='raise' then error('private storage error') end
        if mode=='silent' then return end
        write(path,'return '..dump(self.data))
    end}
end} end
package.preload['libs/libkoreader-lfs']=function() return {symlinkattributes=function(path,key)
    if read(path) then return key=='mode' and 'file' or {mode='file'} end
end} end
local Auth=require('weread.lib.web_authorization')
local Store=require('weread.lib.web_renewal_store')
local codec={json_encode=function(_self,value) return 'return '..dump(value) end,json_decode=function(_self,raw) return decode(raw) end}
local settings={data_dir=root,settings_file=root..'/settings.lua',store={data={cookies={wr_vid='123',wr_skey='XXXinitial',wr_rt='XXXrefresh',ptcz='XXXextra'},
    account={user_vid='123'},auth_epoch=1,wr_ticket='ticket-old',wr_wrpa='protection-old',api_key='old-key',preference='old',books={}}}}
local function flush() write(settings.settings_file,'return '..dump(settings.store.data)) end
function settings:get(key,default) local value=self.store.data[key];if value==nil then return default end;return value end
function settings:get_auth_scope()
    local data=self.store.data;return {vid=tostring(data.account.user_vid),epoch=data.auth_epoch}
end
function settings:auth_scope_matches(owner)
    if not owner then return false end
    local mem=self:get_auth_scope();local raw=read(self.settings_file);local primary=raw and decode(raw)
    return mem.vid==owner.vid and mem.epoch==owner.epoch and primary and tostring(primary.account.user_vid)==owner.vid
        and primary.auth_epoch==owner.epoch and primary.cookies.wr_vid == owner.vid
end
flush()
local sync_failed=false;local fail_done=false;local fail_create=false
local dependencies={sync=function(path)
    if sync_failed then return false end
    if fail_done and path:match('web%-renewal%.json$') and decode(read(path)).phase=='done' then return false end
    return true
end,create=function(directory)
    if fail_create then return nil end
    serial=serial+1;local path=directory..'/exclusive-'..serial..'.json';local file=assert(io.open(path,'wb'))
    return {path=path,write=function(_self,bytes) return file:write(bytes)~=nil end,sync=function() return file:flush()~=nil end,
        accept=function(_self,bytes) file:close();return #assert(read(path))==bytes end,
        abort=function(self) pcall(file.close,file);os.remove(self.path) end}
end}
local store=Store:new(settings,codec,dependencies)
local original=Auth.capture(settings);local pending=assert(store:begin(original))
expect(pending.phase=='pending' and pending.revision==1,'intent not persisted before dispatch')
local other=Store:new(settings,codec,dependencies)
local blocked,reason=other:begin(original);expect(not blocked and reason=='renewal_unconfirmed','reopened store replayed pending intent')
settings.store.data.cookies.wr_skey='XXXdifferent';flush();local changed=Auth.capture(settings)
blocked,reason=other:begin(changed);expect(not blocked and reason=='renewal_unconfirmed','same login Cookie edit bypassed unknown receipt')
settings.store.data.auth_epoch=2;flush();original=Auth.capture(settings);pending=assert(store:begin(original))
expect(pending.scope.epoch==2 and not pending.candidate,'fresh login failed to discard old-scope intent')
local candidate=Auth.receipt(original,{succ=1},{['set-cookie']='wr_skey=XXXrenewed; Path=/', ['x-wr-ticket']='new-ticket'})
local verified=assert(store:receipt(original,pending,candidate,true))
expect(verified.phase=='verified' and verified.target_revision==candidate.revision,'verified receipt not durable')
-- A second local settings object changed unrelated data while HTTP was running.
local fresh=decode(read(settings.settings_file));fresh.preference='new';fresh.api_key='new-key';fresh.books={['42']={cache_dir='/new/cache'}}
write(settings.settings_file,'return '..dump(fresh))
local saved,current=store:apply(original,verified)
expect(saved and current.revision==candidate.revision and settings:get('preference')=='new' and settings:get('api_key')=='new-key'
    and settings:get('books')['42'].cache_dir=='/new/cache','auth save overwrote latest settings/indexes')
expect(settings:get('cookies').wr_rt=='XXXrefresh' and settings:get('cookies').ptcz=='XXXextra' and settings:get('wr_wrpa')=='protection-old','omitted or unrelated auth fields erased')
expect(other:read().phase=='done' and not read(store.path):find('XXXrenewed',1,true),'completed intent retained duplicate credentials')
local function stage()
    local input=Auth.capture(settings);local intent=assert(store:begin(input))
    local next_value=Auth.receipt(input,{succ=1},{['set-cookie']='wr_skey=XXXnext'..serial..'; Path=/'})
    return input,assert(store:receipt(input,intent,next_value,true)),next_value
end
local input,record=stage();mode='raise'
saved=store:apply(input,record);expect(not saved and store:read().phase=='verified' and Auth.capture(settings).revision==input.revision,'failed settings write consumed receipt or changed authority')
mode='normal';expect(store:apply(input,record),'save-only retry failed')
input,record=stage();mode='silent'
expect(not store:apply(input,record) and Auth.capture(settings).revision==input.revision,'silent settings save failure claimed renewed')
mode='normal';expect(store:apply(input,record),'retry after silent failure repeated/blocked receipt')
local next_value;input,record,next_value=stage();fail_done=true
expect(not store:apply(input,record) and Auth.capture(settings).revision==next_value.revision and store:read().phase=='done','post-commit marker-sync failure discarded valid credentials')
fail_done=false;expect(store:apply(input,record),'idempotent completion retry failed')
input=Auth.capture(settings);pending=assert(store:begin(input));candidate=Auth.receipt(input,{succ=1},{})
sync_failed=true;expect(not store:receipt(input,pending,candidate,true),'unsynced receipt claimed durable')
sync_failed=false;record=assert(store:receipt(input,pending,candidate,true));expect(record.phase=='verified','receipt-sync retry could not reuse existing generation')
expect(store:apply(input,record),'same-credential receipt did not complete')
input,record,next_value=stage();settings.store.data.auth_epoch=settings.store.data.auth_epoch+1;flush()
expect(not store:apply(input,record) and Auth.capture(settings).revision~=next_value.revision,'old login receipt overwrote new login')
local before=read(store.path);fail_create=true;input=Auth.capture(settings)
expect(not store:begin(input) and read(store.path)==before,'exclusive output failure destroyed older receipt')
fail_create=false;expect(store:begin(input),'new scope could not safely replace old receipt')
write(store.path..'.old',read(store.path));write(store.path,'broken')
expect(not store:read(),'corrupt primary resurrected backup receipt')
os.remove(store.path);sync_failed=true;input=Auth.capture(settings)
expect(not store:begin(input),'unsynced intent allowed network dispatch')
sync_failed=false;blocked,reason=store:begin(input);expect(not blocked and reason=='renewal_unconfirmed','visible unsynced intent allowed another renewal')
assert(os.execute('rm -rf '..string.format('%q',root)))
print('PASS: Web renewal durable intent, receipt, fresh settings and save-only recovery ('..checks..' checks)')
