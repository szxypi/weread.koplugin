package.path='./?.lua;'..package.path
package.preload['luasettings']=function() return {} end
package.preload['socket']=function() return {sleep=function() end} end
package.preload['weread.lib.native_credentials']=function()
    return {new=function(_self,settings) return settings.native_store end}
end
package.preload['ui/uimanager']=function() return {close=function() end,show=function() end} end
package.preload['ui/widget/confirmbox']=function() return {new=function(_self,options) return options end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(value) return value end} end
package.preload['ffi/util']=function() return {template=function(text,value) return (text:gsub('%%1',value)) end} end
package.preload['weread.ui.shelf_state']=function() return {show=function(host) host.status_shown=true end} end
local Auth=require('weread.lib.native_authorization')
local Renewal=require('weread.lib.native_renewal')
local Service=require('weread.lib.shelf_membership_service')
local View=require('weread.ui.shelf_membership_write')
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local function fixture(options)
    options=options or {}
    local f={revision=1,pending=false,auth_posts=0,data_posts=0,reads=0,current=true,present=false,
        queue={},codes=options.codes or {},record={revision=0,phase='idle'},saved=0,cancelled=0,
        credentials={vid='900000',accessToken='synthetic-old',refreshToken='synthetic-refresh',
            deviceId='eink334691225'..string.rep('1',19)}}
    local scope={vid='900000',epoch=1}
    local settings={data_dir='/unused',get_auth_scope=function() return scope end,
        auth_scope_matches=function(_self,value) return f.current and value==scope end}
    local store={read=function() return f.credentials,f.revision,nil,f.pending end,
        begin_renewal=function(_self,_scope,revision)
            if f.pending then return false,'renewal_unconfirmed' end
            assert(revision==f.revision);f.revision=f.revision+1;f.pending=true;return true,f.revision
        end,
        release_renewal=function() f.revision=f.revision+1;f.pending=false;return true,f.revision end,
        save=function(_self,credentials,_scope,revision)
            assert(revision==f.revision);f.credentials=credentials;f.revision=f.revision+1;f.pending=false;return true,f.revision
        end}
    settings.native_store=store
    local function worker(label)
        return {start=function(_self,task,callback) f.queue[#f.queue+1]={label=label,task=task,callback=callback};return true end,
            cancel=function() f.cancelled=f.cancelled+1 end}
    end
    local journal={read=function() if f.corrupt then return nil,'storage' end;return f.record end,
        begin=function(_self,_scope,id,operation)
            if f.record.phase~='idle' then return nil end
            f.record={revision=f.record.revision+1,phase='pending',book_id=id,operation=operation,epoch=1};return f.record
        end,
        owns=function(_self,_scope,receipt) return f.record==receipt and receipt.phase=='pending' end,
        finish=function(_self,_scope,receipt)
            if f.fail_finish or receipt~=f.record then return false end
            f.record={revision=f.record.revision+1,phase='idle'};return true
        end}
    local decoded
    local client={json_encode=function() return 'encoded' end,json_decode=function() return decoded end,
        request=function(_self,request)
            if request.url=='https://i.weread.qq.com/login' then
                expect(f.pending and f.record.phase=='idle','renewal started with no durable auth intent or uncertain data intent')
                f.auth_posts=f.auth_posts+1
                if options.lost_auth then error('synthetic lost receipt') end
                decoded={vid='900000',accessToken='synthetic-new'};return 'fixture',200
            elseif request.url=='https://i.weread.qq.com/shelf/sync' then
                f.reads=f.reads+1
                local code=table.remove(f.codes,1) or 200
                decoded={books={{bookId='41',title='Other'}}}
                if f.present then decoded.books[2]={bookId='42',title='Synthetic'} end
                return 'fixture',code
            end
            assert(request.url=='https://i.weread.qq.com/shelf/add')
            expect(f.record.phase=='pending','membership POST preceded its journal')
            f.data_posts=f.data_posts+1
            decoded={succ=1}
            if options.write401 then return 'fixture',401 end
            f.present=true;return 'fixture',200
        end}
    local host={settings=settings,client=client,ui={document={}},_book_detail_view={},_shelf_state_menu={},
        discovery_epoch=1,_reader_session_gen=1,
        library_db={accountKey=function() return 'synthetic-owner' end,getBook=function() return {title='Synthetic'} end,
            cacheShelf=function() f.saved=f.saved+1;return true end},
        isNetworkConnected=function() return true end,
        showBusy=function(self,_text,cancel) self.busy_message={};self.busy_cancel=cancel end,
        closeBusy=function(self) self.busy_message=nil end,showInfo=function(_self,text) f.message=text end,
        applyShelfSnapshot=function() end}
    host.shelf_membership=Service:new{settings=settings,client=client,scheduler={},store=store,journal=journal,worker=worker('shelf')}
    host.native_renewal=Renewal:new{settings=settings,client=client,scheduler={},store=store,worker=worker('renew'),
        make_auth=function(_client,opts)
            opts.digits=function(n) return string.rep('1',n) end;opts.now_ms=function() return 1794100000123 end
            return Auth:new(client,opts)
        end}
    f.host=host
    function f.open(resolve) return View.open(host,'42',resolve) end
    function f.tick(label)
        local job=assert(table.remove(f.queue,1),'missing worker')
        expect(job.label==label,'unexpected phase: '..job.label)
        job.callback(job.task())
    end
    function f.dialog() return host._shelf_membership_ui and host._shelf_membership_ui.dialog end
    function f.confirm() assert(f.dialog()).ok_callback() end
    return f
end
local f=fixture{codes={401}}
f.open();f.tick('shelf')
expect(f.pending and f.auth_posts==0 and f.data_posts==0,'preview401 failed to reserve one auth attempt')
f.tick('renew');f.tick('shelf')
expect(f.revision==3 and not f.pending and f.dialog() and f.data_posts==0,'renewal must return to a fresh explicit confirmation')
f.confirm();f.tick('shelf')
expect(f.auth_posts==1 and f.data_posts==1 and f.saved==1 and not f.host._shelf_membership_ui,'confirmed renewed preview did not complete once')

f=fixture{codes={200,401}}
f.open();f.tick('shelf');local previous=f.dialog();f.confirm();f.tick('shelf')
expect(f.record.phase=='idle' and f.pending and f.data_posts==0,'preflight401 must finish proven-unsent data intent before renewal')
f.tick('renew');f.tick('shelf')
expect(f.dialog() and f.dialog()~=previous and f.auth_posts==1 and f.data_posts==0,'old confirmation carried through renewal')
previous.ok_callback();expect(f.data_posts==0 and #f.queue==0,'stale confirmation replayed after renewal')
f.confirm();f.tick('shelf');expect(f.data_posts==1 and f.saved==1,'new confirmation could not apply once')

for _i,codes in ipairs({{401,200,401},{200,401,200,401},{401,200,200,401}}) do
    f=fixture{codes=codes};f.open();f.tick('shelf')
    if f.dialog() then f.confirm();f.tick('shelf') end
    f.tick('renew');f.tick('shelf')
    if f.dialog() then f.confirm();f.tick('shelf') end
    expect(f.auth_posts==1 and f.data_posts==0 and #f.queue==0 and not f.host._shelf_membership_ui,
        'second401 repeated recovery or automatically sent data')
end
for _i,code in ipairs({403,429}) do
    f=fixture{codes={code}};f.open();f.tick('shelf')
    expect(f.auth_posts==0 and f.data_posts==0 and #f.queue==0,'non401 triggered renewal')
end
f=fixture{codes={200,401}};f.open();f.tick('shelf');f.fail_finish=true;f.confirm();f.tick('shelf')
expect(f.auth_posts==0 and #f.queue==0 and f.record.phase=='pending','failed journal completion allowed renewal')
for _i,options in ipairs({{write401=true},{codes={200,200,401,401,401}}}) do
    f=fixture(options);f.open();f.tick('shelf');f.confirm();f.tick('shelf')
    expect(f.data_posts==1 and f.auth_posts==0 and f.record.phase=='pending' and #f.queue==0,
        'possibly sent change renewed/replayed or lost uncertainty')
end
f=fixture{codes={401}};f.record={revision=1,phase='pending',book_id='42',operation='add',epoch=1}
f.open(true);f.tick('shelf')
expect(f.record.phase=='pending' and f.auth_posts==0 and #f.queue==0,'pending resolution automatically renewed authentication')

for _i,event in ipairs({'cancel','suspend','account','document','status','detail','grant'}) do
    f=fixture{codes={401}};f.open();f.tick('shelf')
    if event=='cancel' then View.cancel(f.host)
    elseif event=='suspend' then f.host._reader_session_gen=2
    elseif event=='account' then f.current=false
    elseif event=='document' then f.host.ui.document={}
    elseif event=='status' then f.host._shelf_state_menu={}
    elseif event=='detail' then f.host._book_detail_view={}
    else f.revision=f.revision+1;f.pending=false;f.credentials={vid='900000',accessToken='synthetic-external'} end
    f.tick('renew')
    expect(f.data_posts==0 and f.saved==0 and #f.queue==0 and not f.dialog(),'stale recovery produced a confirmation: '..event)
end
f=fixture{codes={401},lost_auth=true};f.open();f.tick('shelf');f.tick('renew')
expect(f.auth_posts==1 and f.pending and f.data_posts==0 and #f.queue==0,'lost auth receipt replayed or dropped its marker')
f.open();expect(f.auth_posts==1 and #f.queue==0,'reopening UI replayed an uncertain renewal')

f=fixture{codes={401}};f.open();f.tick('shelf');local old=f.host._shelf_membership_ui
View.cancel(f.host);f.pending=false;f.revision=f.revision+1;f.open();local busy=f.host.busy_message
f.tick('renew');expect(f.host.busy_message==busy and f.host._shelf_membership_ui~=old,'old renewal cancelled newer UI')
f.tick('shelf');expect(f.dialog() and f.data_posts==0,'newer preview lost to a cancelled renewal')
print(('shelf_membership_recovery_spec: %d checks'):format(checks))
