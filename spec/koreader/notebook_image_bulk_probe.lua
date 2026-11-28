-- Actual KOReader menu, background workers, SQLite quotas and offline reopen.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
assert(os.getenv('WEREAD_SYNTHETIC')=='1')
local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/'))
package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
G_reader_settings=require('luasettings'):wrap({});G_defaults=require('luadefaults'):open()
local Device=require('device');require('document/canvascontext'):init(Device)
local ffi=require('ffi');require('ffi/posix_h');local socket=require('socket');local json=require('json')
local UI=require('ui/uimanager');local mode=assert(arg[1]);local user=mode=='foreign' and '87654321' or '12345678'
local public=os.getenv('WEREAD_PUBLIC_NOTE_IMAGE')=='1';local input=public and assert(json.decode(io.read('*a'))) or nil
local scope={vid=user,epoch=1};local settings={data_dir=home,get=function(_,key,default)
    if key=='account' then return {user_vid=user} end;return default end,
    auth_scope_matches=function(_,value) return value==scope end}
local library=require('weread.lib.library_db'):new(settings);local account=assert(library:accountKey())
local bytes=require('weread.lib.native_missing_image')
local root='https://weread-picture-1258476243.file.myqcloud.com/'
local urls={root..'one.png',root..'two.png',root..'quota.png',root..'cancel.png',root..'changed.png'}
if public then urls[2]=input.url end
local mem=ffi.C.mmap(nil,4096,3,0x21,-1,0);assert(mem~=ffi.cast('void *',-1));local calls=ffi.cast('int *',mem)
local client
client={json_encode=function(_,value) return json.encode(value) end,json_decode=function(_,value) return json.decode(value) end,
    request=function(_,options)
        local allowed=false;for _,url in ipairs(urls) do if options.url==url then allowed=true end end
        assert(allowed and options.method=='GET' and options.skip_cookie and options.sensitive
            and not options.persist_response_cookies and not options.headers.Cookie and not options.headers.Authorization)
        calls[0]=calls[0]+1;if mode=='cancel' then socket.sleep(3) end
        if mode=='changed' then
            local raw={reviews={{reviewId='r6',review={reviewId='r6',bookId='46',userVid=tonumber(user),
                content='updated elsewhere',type=1,isPrivate=1,createTime=1000,pictures={{url=urls[5]}}}}},totalCount=1,hasMore=0}
            local value=require('weread.lib.my_cloud_thoughts').project(client,raw,'46',user,1000)
            assert(require('weread.lib.my_cloud_marks_store'):new(library,client,'thoughts'):write(value))
        end
        if public and options.url==urls[2] then return require('weread.lib.client'):new(settings):request(options) end
        assert(options.sink(bytes));options.sink(nil);return nil,200
    end}
local Data=require('weread.lib.my_cloud_thoughts');local Notes=require('weread.lib.my_cloud_marks_store')
local Images=require('weread.lib.thought_image_store');local image_store=Images:new(library)
local function snapshot(book,review,pictures)
    local raw={reviews={{reviewId=review,review={reviewId=review,bookId=book,userVid=tonumber(user),content='synthetic',
        type=1,isPrivate=1,createTime=1000,pictures=pictures}}},totalCount=1,hasMore=0}
    return Data.project(client,raw,book,user,1000)
end
local notes=Notes:new(library,client,'thoughts')
local function key(book,review,url) return assert(Images.key(book,review,url)) end
local one,two=key('41','r1',urls[1]),key('41','r1',urls[2])
local function valid_second()
    local data=image_store:read(account,two)
    return public and data and require('weread.lib.crypto').sha256_hex(data)==input.sha256 or not public and data==bytes
end
if mode=='offline' then
    local host={settings=settings,library_db=library,client=client}
    function host:isNetworkOnline() return false end
    function host:showBusy(_,cancel) self.busy_message={cancel=cancel} end
    function host:closeBusy() self.busy_message=nil end
    function host:showInfo() error('offline image unavailable') end
    local row=assert(notes:read('41')).reviews[1]
    local owner={id='41',account=account,scope=scope,menu={},generation=1}
    local Popup=require('weread.ui.shelf_popup')
    local viewer=require('ui/widget/textviewer'):new{title='Synthetic',text='Synthetic'}
    Popup.show(owner.menu,viewer,function(value) UI:show(value) end)
    assert(require('weread.ui.thought_images').open(host,owner,row,2,viewer,function() return true end,1))
    local deadline=socket.gettime()+45
    while owner.thought_image do
        assert(socket.gettime()<deadline);UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
    end
    assert(owner.menu._shelf_popup~=viewer and owner.menu._shelf_popup.image and calls[0]==0 and not host.busy_message)
    UI:forceRePaint();Popup.close(owner.menu)
    print('WEREAD_NOTE_IMAGE_BULK=PASS:'..mode);return
elseif mode=='foreign' then
    assert(not image_store:read(account,one) and not notes:read('41') and calls[0]==0)
    assert(image_store:clear(account)==0)
    print('WEREAD_NOTE_IMAGE_BULK=PASS:'..mode);return
elseif mode=='online' then
    assert(notes:write(snapshot('41','r1',{{url=urls[1]},{url=urls[2]}})))
    assert(notes:write(snapshot('43','r3',{{url='https://untrusted.invalid/picture'}})))
    local old=snapshot('47','r7',{{url=urls[3]}});old.reviews[1].attachment_digest=nil;assert(notes:write(old))
    assert(image_store:write(account,one,bytes))
elseif mode=='quota' then
    assert(image_store:read(account,one)==bytes and valid_second())
    Images.MAX_ENTRIES=3
    local visits=0;local function cancelled() visits=visits+1;return visits==1 end
    assert(not image_store:write(account,key('44','r4',urls[3]),bytes,{preserve_existing=true,current=cancelled}))
    assert(not image_store:read(account,key('44','r4',urls[3])) and image_store:read(account,one)==bytes and valid_second())
    visits=0;assert(image_store:clear(account,cancelled)==nil)
    assert(image_store:read(account,one)==bytes and valid_second(),'cancelled clear did not roll back')
    Images.MAX_ENTRIES=2;assert(notes:write(snapshot('44','r4',{{url=urls[3]}})))
elseif mode=='cancel' then
    assert(notes:write(snapshot('45','r5',{{url=urls[4]}})))
elseif mode=='changed' then
    assert(notes:write(snapshot('46','r6',{{url=urls[5]}})))
elseif mode=='clear' or mode=='empty' or mode=='clear_failure' then
    if mode~='empty' then assert(image_store:read(account,one)==bytes and valid_second())
    else assert(not image_store:read(account,one) and not image_store:read(account,two)) end
    if mode=='clear_failure' then
        local db=assert(library:open());local trigger=db:prepare([[CREATE TRIGGER fixture_image_delete_failure BEFORE DELETE ON thought_image_cache
            BEGIN SELECT RAISE(ABORT,'fixture'); END]])
        trigger:step();trigger:close();db:close()
    end
else error('unsupported fixture mode') end
local host={settings=settings,library_db=library,client=client}
function host:isNetworkOnline() return true end
function host:showInfo(value) self.message=value end
function host:showOffline(value) self.message=value end
function host:showTransientInfo(value) self.message=value end
function host:showBusy(value,cancel)
    self.busy_message=require('ui/widget/infomessage'):new{text=value,dismissable=true,dismiss_callback=cancel}
    UI:show(self.busy_message)
end
local menu=require('ui/widget/menu'):new{title='Synthetic',item_table={}}
local books=mode=='online' and {{bookId='41'},{bookId='42'},{bookId='43'},{bookId='47'}}
    or {{bookId=mode=='quota' and '44' or mode=='changed' and '46' or '45'}}
local owner={account=account,scope=scope,menu=menu,value={books=books}}
local active=true;local function current() return active and library:accountKey()==account and settings:auth_scope_matches(scope) end
local bulk=require('weread.ui.notebook_image_bulk')
local clearing=mode=='clear' or mode=='empty' or mode=='clear_failure'
menu.item_table={{text='Synthetic image batch',callback=function()
    assert(clearing and bulk.clear(host,owner,current) or not clearing and bulk.start(host,owner,current))
end}}
UI:show(menu);menu:onMenuSelect(menu.item_table[1])
if clearing then
    local confirm=assert(owner.menu._shelf_popup);assert(confirm.text and confirm.ok_callback)
    assert(not owner.image_bulk_context);confirm.ok_callback()
end
local job=assert(owner.image_bulk_context)
local deadline=socket.gettime()+60
local function tick() assert(socket.gettime()<deadline);UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01) end
if mode=='cancel' then
    while calls[0]==0 do tick() end
    job.dialog.buttons[1][1].callback();assert(not owner.image_bulk_context and not host.busy_message)
    assert(not image_store:read(account,key('45','r5',urls[4])))
elseif clearing then
    while owner.image_bulk_context do tick() end
    if mode=='clear_failure' then
        assert(image_store:read(account,one)==bytes and valid_second() and host.message)
        local db=assert(library:open());db:exec('DROP TRIGGER fixture_image_delete_failure');db:close()
    else
        assert(not image_store:read(account,one) and not image_store:read(account,two) and notes:read('41') and calls[0]==0)
    end
else
    while owner.image_bulk_context do tick() end
    if mode=='online' then
        assert(job.done==4 and job.saved==1 and job.cached==1 and job.missing==1 and job.partial==1 and job.unverified==1 and calls[0]==1)
        assert(image_store:read(account,one)==bytes and valid_second())
    elseif mode=='changed' then
        assert(job.saved==0 and job.done==0 and calls[0]==1 and host.message)
        assert(not image_store:read(account,key('46','r6',urls[5])) and notes:read('46').reviews[1].content=='updated elsewhere')
        assert(image_store:read(account,one)==bytes and valid_second())
    else
        assert(job.saved==0 and job.done==0 and calls[0]==1 and host.message)
        assert(image_store:read(account,one)==bytes and valid_second()
            and not image_store:read(account,key('44','r4',urls[3])))
    end
end
assert(host.message and not host.busy_message);active=false;UI:close(menu);ffi.C.munmap(mem,4096)
print('WEREAD_NOTE_IMAGE_BULK=PASS:'..mode)
