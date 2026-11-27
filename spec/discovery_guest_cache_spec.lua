package.path='./?.lua;./?/init.lua;'..package.path
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local public_reads,personal_reads,public_writes,personal_writes=0,0,0,0
local account,change,personal_source=nil,false,'native'
local personal_missing,public_generation,public_remembered,personal_remembered=false,'public-generation',0,0
package.preload['weread.lib.plugin_util']=function() return {tr=function(value) return value end} end
package.preload['weread.lib.discovery_cache']=function() return {new=function() return {
    read=function()
        personal_reads=personal_reads+1
        if not personal_missing then return {kind='search',source_kind=personal_source} end
    end,
    write=function() personal_writes=personal_writes+1;return 'personal-generation' end,
    remember=function() personal_remembered=personal_remembered+1;return true end,
} end} end
package.preload['weread.lib.public_discovery_cache']=function() return {new=function() return {
    read=function(_self,query,cursor)
        public_reads=public_reads+1
        if change then account='signed-in' end
        if query and query.kind~='category' then return nil end
        return {kind='category',source_kind='public',cached=true,cursor=cursor,
            _cache_view={key=query and query.category_id,generation=public_generation}}
    end,
    remember=function() public_remembered=public_remembered+1;return true end,
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
local before_public_writes=public_writes
expect(not UI.save(host,{kind='search',source_kind='public'}) and public_writes==before_public_writes,
    'guest public search persisted a query in the shared cache')
account='signed-in';local before=public_reads
expect(UI.read(host,query).account=='signed-in' and personal_reads==1 and public_reads==before,'signed-in cache routing changed')
expect(UI.read(host,{kind='search',keyword='test',public_only=true})==nil,'public search loaded a native cache')
personal_source='public'
expect(UI.read(host,{kind='search',keyword='test',public_only=true}).source_kind=='public',
    'public search could not reopen its own account-scoped cache')
state={kind='category',source_kind='public',account=account}
expect(UI.save(host,state) and personal_writes==1,'signed-in category lost account-local cache')
personal_missing=true;before=public_reads
expect(not UI.read(host) and not UI.read(host,{kind='recommend'}) and not UI.read(host,query,20) and public_reads==before,
    'signed-in account used the last guest page or fetched a public batch without an explicit first page')
value=UI.read(host,query,0)
expect(value and value._shared_public_category and value.account==account and public_reads==before+1,
    'missing account category did not open the explicit guest batch')
expect(not UI.remember(host,value,{anchor=1}) and public_remembered==0 and personal_remembered==0,
    'account browsing history was written while using guest data')
personal_missing=false;local personal_before=personal_reads
local next_batch=UI.read(host,query,20,value)
expect(next_batch and next_batch.cursor==20 and next_batch._shared_public_category and personal_reads==personal_before,
    'public continuation mixed in a new account cache')
public_generation='replaced'
expect(not UI.read(host,query,20,value),'continuation silently switched to a replaced public chain')
local owned={kind='category',account=account,cached=true}
local own_batch=UI.read(host,query,20,owned)
expect(own_batch and not own_batch._shared_public_category,'account continuation unexpectedly switched to public cache')
personal_missing=true
expect(not UI.read(host,query,20,owned),'missing account continuation spilled into public cache')
change=true;account='another-account'
expect(not UI.read(host,query,0),'guest backstop read crossed a login boundary')
account=nil;change=true
expect(UI.read(host,query)==nil,'guest read crossed login boundary')
print('discovery_guest_cache_spec: '..checks..' checks')
