-- Synthetic native ImageViewer, account-local SQLite and offline reopen.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
assert(os.getenv('WEREAD_SYNTHETIC')=='1')
local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/'))
package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
G_reader_settings=require('luasettings'):wrap({});G_defaults=require('luadefaults'):open()
local Device=require('device');require('document/canvascontext'):init(Device)
local ffi=require('ffi');require('ffi/posix_h');local socket=require('socket')
local UI=require('ui/uimanager');local json=require('json');local mode=assert(arg[1])
local public=mode=='public' or mode=='public-offline'
local input=public and assert(json.decode(io.read('*a'))) or nil
local user=mode=='foreign' and '87654321' or '12345678';local scope={vid=user,epoch=1}
local settings={data_dir=home,get=function(_,key,default) if key=='account' then return {user_vid=user} end;return default end,
    auth_scope_matches=function(_,value) return value==scope end}
local library=require('weread.lib.library_db'):new(settings);local account=assert(library:accountKey())
local bytes=require('weread.lib.native_missing_image');local url=public and input.url or 'https://weread-picture-1258476243.file.myqcloud.com/synthetic.png'
local mem=ffi.C.mmap(nil,4096,3,0x21,-1,0);assert(mem~=ffi.cast('void *',-1));local calls=ffi.cast('int *',mem)
local client={json_encode=function(_,value) return json.encode(value) end,json_decode=function(_,value) return json.decode(value) end,
    request=function(_,options)
        assert((mode=='live' or mode=='public') and options.url==url and options.method=='GET' and options.skip_cookie and options.sensitive
            and not options.persist_response_cookies and not options.headers.Cookie and not options.headers.Authorization)
        calls[0]=calls[0]+1
        if public then return require('weread.lib.client'):new(settings):request(options) end
        assert(options.sink(bytes));options.sink(nil);return nil,200
    end}
local host={settings=settings,library_db=library,client=client}
function host:isNetworkOnline() return mode=='live' or mode=='public' end
function host:showBusy(_label,cancel) self.busy_message={cancel=cancel} end
function host:closeBusy() self.busy_message=nil end
function host:showInfo(value) self.message=value end
local owner={id='42',account=account,scope=scope,generation=1,menu={}}
local current=function() return library:accountKey()==account and settings:auth_scope_matches(scope) end
local raw={reviews={{reviewId='synthetic-review',review={reviewId='synthetic-review',bookId='42',userVid=tonumber(user),
    content='Synthetic thought',type=1,isPrivate=1,createTime=1000,pictures={{url=url,width=32,height=32}}}}},totalCount=1,hasMore=0}
local Data=require('weread.lib.my_cloud_thoughts');local Store=require('weread.lib.my_cloud_marks_store')
local snapshot=Data.project(client,raw,'42',user,1000);local store=Store:new(library,client,'thoughts')
if mode=='quota' then
    local cache=require('weread.lib.thought_image_store');local images=cache:new(library)
    local db=assert(library:open());db:exec('DELETE FROM thought_image_cache');db:close()
    local a=assert(cache.key('42','a',url));local b=assert(cache.key('42','b',url));local c=assert(cache.key('42','c',url))
    cache.MAX_ENTRIES=2
    assert(bytes:find('\0',1,true) and images:write(account,a,bytes) and images:read(account,a)==bytes)
    assert(images:write(account,b,bytes) and images:write(account,c,bytes))
    assert(not images:read(account,a) and images:read(account,b)==bytes and images:read(account,c)==bytes)
    assert(not images:read('foreign-account',b) and not images:write('foreign-account',a,bytes))
    cache.MAX_TOTAL=#bytes;assert(images:write(account,a,bytes))
    assert(images:read(account,a)==bytes and not images:read(account,b) and not images:read(account,c))
    ffi.C.munmap(mem,4096);print('WEREAD_THOUGHT_IMAGE=PASS:'..mode);return
end
if mode=='live' or mode=='public' then assert(store:write(snapshot)) end
if mode=='offline' or mode=='public-offline' then snapshot=assert(store:read('42')) end
if mode=='corrupt' then
    local db=assert(library:open());db:exec("UPDATE thought_image_cache SET body='broken'");db:close()
end
local row=snapshot.reviews[1];assert(row.attachment_state=='available' and row.attachment_urls==url)
local Popup=require('weread.ui.shelf_popup');local widget=require('ui/widget/textviewer'):new{title='Synthetic',text='Synthetic'}
Popup.show(owner.menu,widget,function(value) UI:show(value) end)
local Images=require('weread.ui.thought_images');assert(Images.open(host,owner,row,1,widget,current,1))
local deadline=socket.gettime()+45
while owner.thought_image do assert(socket.gettime()<deadline);UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01) end
if mode=='live' or mode=='offline' or public then
    local image=owner.menu._shelf_popup;assert(image and image~=widget and image.title_text=='Thought image' and image.image)
    UI:forceRePaint();assert(calls[0]==((mode=='live' or mode=='public') and 1 or 0));Popup.close(owner.menu)
    if public then
        local cache=require('weread.lib.thought_image_store');local key=assert(cache.key('42','synthetic-review',url))
        assert(require('weread.lib.crypto').sha256_hex(assert(cache:new(library):read(account,key)))==input.sha256)
    end
else
    assert(owner.menu._shelf_popup==widget and host.message and calls[0]==0)
    Popup.close(owner.menu)
end
assert(not host.busy_message);ffi.C.munmap(mem,4096)
print('WEREAD_THOUGHT_IMAGE=PASS:'..mode)
