package.path='./?.lua;./?/init.lua;'..package.path
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local public_reads,personal_reads,public_writes,personal_writes=0,0,0,0
local account,change=nil,false
package.preload['weread.lib.plugin_util']=function() return {tr=function(value) return value end} end
package.preload['weread.lib.discovery_cache']=function() return {new=function() return {
    read=function() personal_reads=personal_reads+1;return {kind='search'} end,
    write=function() personal_writes=personal_writes+1;return 'personal-generation' end,
} end} end
package.preload['weread.lib.public_discovery_cache']=function() return {new=function() return {
    read=function(_self,query)
        public_reads=public_reads+1
        if change then account='signed-in' end
        if query and query.kind~='category' then return nil end
        return {kind='category',source_kind='public',cached=true}
    end,
    write=function(_self,state)
        public_writes=public_writes+1
        if state.kind=='category' and state.source_kind=='public' then return 'public-generation' end
    end,
} end} end
local UI=require('weread.ui.discovery_cache')
local host={settings={},client={},library_db={accountKey=function() return account end},showTransientInfo=function() end}
local query={kind='category',category_id='100000',category_title='Category',rank=false}
local value=UI.read(host,query,0)
expect(value and value.kind=='category' and value.account==nil and public_reads==1 and personal_reads==0,
    'anonymous category batches cannot be reopened offline')
expect(UI.read(host,{kind='search',keyword='private'})==nil and personal_reads==0,'guest opened personal cache')
expect(UI.read(host).kind=='category','guest last category was not restored')
local state={kind='category',source_kind='public'}
expect(UI.save(host,state) and state._cache_generation=='public-generation' and public_writes==1,'guest public batch not saved')
expect(not UI.save(host,{kind='search',source_kind='native'}) and personal_writes==0,'guest saved personal query')
account='signed-in';local before=public_reads
expect(UI.read(host,query).account=='signed-in' and personal_reads==1 and public_reads==before,'signed-in cache routing changed')
state={kind='category',source_kind='public',account=account}
expect(UI.save(host,state) and personal_writes==1,'signed-in category lost account-local cache')
account=nil;change=true
expect(UI.read(host,query)==nil,'guest read crossed login boundary')
print('discovery_guest_cache_spec: '..checks..' checks')
