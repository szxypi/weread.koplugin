package.path='./?.lua;'..package.path
local Model=require('weread.lib.startup_patch')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local state,store
local function fixture()
    state={}
    local fs={symlinkattributes=function()
        if state.mode then return {mode=state.mode,size=state.size or #(state.raw or '')} end
        return nil,'missing',state.code or 2
    end}
    store=assert(Model.new('/plugin',{directory='/patches',fs=fs,read=function()
        if state.read_error then error('unavailable') end;return state.raw
    end,create=function()
        state.created=(state.created or 0)+1
        if state.failure=='create' then return end
        return {path='/patches/staging.json',
            write=function(_self,raw) state.staged=raw;return state.failure~='write' end,
            sync=function() return state.failure~='sync' end,
            accept=function(_self,n) assert(n==#state.staged);return state.failure~='accept' end,
            owns=function()
                if state.failure=='replaced' then state.mode='file';state.raw='foreign' end
                return state.failure~='ownership'
            end,
            abort=function() state.aborted=true end}
    end,rename=function()
        state.renamed=(state.renamed or 0)+1
        if state.failure=='rename' then return false end
        state.mode='file';state.raw=state.staged;return true
    end,remove=function()
        state.removed=(state.removed or 0)+1
        if state.failure=='remove' then return false end
        state.mode=nil;state.raw=nil;return true
    end,sync=function() return state.failure~='directory_sync' end}))
end
expect(Model.payload('/plugin'):find('mp_startup_open',1,true)~=nil,'bridge omitted the early entry adapter')
for _i,path in ipairs({'relative','/bad\nroot','/nul\0root',string.rep('/',3001)}) do
    expect(not Model.payload(path),'invalid plugin path was embedded in startup Lua')
end
local quoted=assert(Model.payload('/path/with "quotes" and 中文'))
expect(loadstring(quoted)~=nil and not quoted:find('cookies',1,true),'bridge was not a literal, credential-free program')
fixture();expect(store:status()=='absent' and store:enable() and store:status()=='installed','bridge did not publish and reread')
expect(state.aborted and state.renamed==1 and state.raw==store.raw,'bridge left an unowned staging path')
expect(store:enable() and state.created==1,'existing identical bridge was rewritten')
expect(store:disable() and store:status()=='absent' and state.removed==1,'owned bridge was not removed')
expect(store:disable() and state.removed==1,'already absent bridge was removed twice')
for _i,mode in ipairs({'file','link','directory'}) do
    fixture();state.mode=mode;state.raw='foreign'
    expect(store:status()=='foreign' and not store:enable() and not store:disable()
        and not state.created and not state.removed,'foreign startup entry was overwritten or deleted: '..mode)
end
fixture();state.mode='file';state.raw=store.raw;state.size=Model.MAX_BYTES+1
expect(store:status()=='foreign','oversize startup entry was trusted')
fixture();state.mode='file';state.raw=store.raw;state.read_error=true
expect(store:status()=='unavailable' and not store:disable(),'unreadable entry was removed')
fixture();state.code=13
expect(store:status()=='unavailable' and not store:enable(),'missing permission was mistaken for absent file')
for _i,failure in ipairs({'create','write','sync','accept','ownership','rename','directory_sync'}) do
    fixture();state.failure=failure
    expect(not store:enable(),'failed bridge operation was accepted: '..failure)
    if failure~='create' then expect(state.aborted,'failed bridge did not dispose its staging object: '..failure) end
    if failure~='directory_sync' then expect(store:status()=='absent','incomplete bridge became executable: '..failure) end
end
fixture();state.failure='replaced'
expect(not store:enable() and not state.renamed and state.raw=='foreign','replacement entry was overwritten')
fixture();state.mode='file';state.raw=store.raw;state.failure='remove'
expect(not store:disable() and store:status()=='installed','failed removal reported absent bridge')
for _i,mode in ipairs({'disabled','external_disabled','missing','failure','unsupported','enabled'}) do
    local called,warned=0,false
    local environment={package={path='core'},G_reader_settings={
        readSetting=function() return mode=='disabled' and {weread=true} or {} end,
        isTrue=function() return mode=='external_disabled' end},
        require=function(name)
            if name=='libs/libkoreader-lfs' then return {attributes=function() return mode~='missing' and 'file' or nil end} end
            if name=='weread.lib.logger' then return {warn=function() warned=true end} end
            assert(name=='weread.ui.mp_startup_open')
            return {install=function() called=called+1
                if mode=='failure' then error('unavailable') end
                return mode~='unsupported'
            end}
        end}
    setmetatable(environment,{__index=_G})
    local chunk=assert(loadstring(assert(Model.payload('/plugin'))));setfenv(chunk,environment);chunk()
    if mode=='enabled' then
        expect(called==1 and environment.package.path=='core;/plugin/?.lua' and not warned,
            'successful bridge lost the namespace needed before PluginLoader')
    elseif mode=='failure' or mode=='unsupported' then
        expect(called==1 and environment.package.path=='core' and warned,'failed bridge changed the global module path')
    else expect(called==0 and environment.package.path=='core' and not warned,'inactive bridge affected native startup: '..mode) end
end
print('startup_patch_spec: '..checks..' checks')
