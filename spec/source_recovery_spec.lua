package.path='./?.lua;'..package.path
local Recovery=require('weread.lib.source_recovery')
local Access=require('weread.lib.read_access')
local Auth=require('weread.lib.web_authorization')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message or ('check '..checks)) end
local function copy(value)
    if type(value)~='table' then return value end
    local out={};for key,item in pairs(value) do out[key]=copy(item) end;return out
end
local function fixture()
    local f={scope={vid='900000',epoch=1},cookie='synthetic-before',key='synthetic-key',revision='before',valid=true,
        frame=true,pending=false,posts=0,cancelled=0,callbacks=0}
    local settings={get_auth_scope=function() return copy(f.scope) end,
        auth_scope_matches=function(_self,scope) return f.valid and scope.vid==f.scope.vid and scope.epoch==f.scope.epoch end,
        get=function(_self,key,default)
            if key=='cookies' then return {['wr_vid']=f.scope.vid,['wr_skey']=f.cookie} end
            if key=='api_key' then return f.key end
            return default
        end}
    Auth.memory=function() assert(f.valid);return {scope=copy(f.scope),revision=f.revision} end
    Auth.capture=function() error('primary reconciliation belongs to the renewal service') end
    Auth.current=function(_settings,value) return value.revision==f.revision and value.scope.vid==f.scope.vid and value.scope.epoch==f.scope.epoch end
    f.service=Recovery:new{settings=settings,can_recover=function() return not f.pending end,
        renew=function(options,callback)
            expect(options.is_current(),'renewal started with an invalid frame')
            f.posts=f.posts+1;f.guard,f.ready=options.is_current,callback;return true,{}
        end,cancel=function() f.cancelled=f.cancelled+1 end}
    function f.start()
        f.access=Access.capture(settings)
        return f.service:start('900001',f.access,function() return f.frame end,function(fresh,reason)
            f.callbacks=f.callbacks+1;f.fresh,f.reason=fresh,reason
        end)
    end
    function f.finish(success)
        f.cookie,f.revision='synthetic-after','after'
        f.ready(success~=false,{scope=copy(f.scope),revision=f.revision,cookies={wr_skey='forged-child-cookie'}})
    end
    return f
end
local f=fixture();local started,job=f.start()
expect(started and job and f.posts==1 and f.guard(),'valid source read did not start parent recovery')
expect(not f.start() and f.posts==1,'concurrent source reads duplicated renewal')
f.finish()
expect(f.callbacks==1 and f.fresh and f.fresh.web.cookies.wr_skey=='synthetic-after','verified settings were not adopted')
expect(f.fresh.revision~=f.access.revision and not f.service.job,'source read retained old cookies or helper ownership')
expect(not f.reason,'successful recovery returned an error')
f.ready(true,{scope=f.scope,revision='after'})
expect(f.callbacks==1,'completed renewal called source reader twice')
for _i,mode in ipairs({'frame','account','epoch','key','pending','invalid','unverified','wrong_receipt'}) do
    f=fixture();expect(f.start())
    if mode=='frame' then f.frame=false end
    if mode=='account' then f.scope.vid='900099' end
    if mode=='epoch' then f.scope.epoch=2 end
    if mode=='key' then f.key='changed-key' end
    if mode=='pending' then f.pending=true end
    if mode=='invalid' then f.valid=false end
    if mode=='wrong_receipt' then f.ready(true,{scope=copy(f.scope),revision='forged'}) else f.finish(mode~='unverified') end
    expect(f.callbacks==1 and not f.fresh and f.posts==1,'invalid renewal was adopted: '..mode)
end
f=fixture();f.pending=true;expect(not f.start() and f.posts==0,'uncertain position dispatch renewed credentials')
f=fixture();started,job=f.start();f.service:cancel(job);f.finish()
expect(started and not f.service.job and f.callbacks==0 and f.cancelled==1,'cancelled source recovery survived a late receipt')
f.service:cancel(nil)
f=fixture();f.service.renew=function() return false,'busy' end
expect(not f.start() and not f.service.job and f.callbacks==0,'busy renewal retained a source job')
f=fixture();f.service.renew=function() return false,'session_changed' end
expect(not f.start() and not f.service.job and not f.fresh,'refused primary reconciliation adopted credentials')
f=fixture();Auth.memory=function() error('invalid memory') end
expect(not f.start() and not f.service.job and f.posts==0,'invalid memory scope reached credential maintenance')
print(('source_recovery_spec: %d checks'):format(checks))
