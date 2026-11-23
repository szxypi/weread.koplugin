-- Real account UI probe. Credentials and source text remain in memory/tmpfs;
-- only fixed flags and stage names may be printed.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
assert(os.getenv('WEREAD_DIRECT_OWNER_TMPFS')=='1')
local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/'))
local plugin=home..'/plugins/weread.koplugin';package.path=plugin..'/?.lua;'..package.path
local ffi=require('ffi');local json=require('json');local input=json.decode(assert(io.stdin:read('*a')))
assert(type(input.web_cookies)=='table' and input.web_cookies.wr_vid == input.credentials.vid
    and type(input.allowed)=='table' and #input.allowed>=1 and #input.allowed<=4)
pcall(ffi.cdef,'int memfd_create(const char *, unsigned int); void *mmap(void *, unsigned long, int, int, int, long);')
local auth={auth_schema_version=1,auth_epoch=1,account={user_vid=input.credentials.vid,name=''},cookies=input.web_cookies,api_key=''}
local fd=tonumber(ffi.C.memfd_create('weread-native-online-auth',1));assert(fd>=0)
local encoded='return '..require('dump')(auth,nil,true);local offset=0
while offset<#encoded do local n=tonumber(ffi.C.write(fd,ffi.cast('const char *',encoded)+offset,#encoded-offset));assert(n>0);offset=offset+n end
local auth_path='/proc/self/fd/'..fd
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua');G_defaults=require('luadefaults'):open()
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
local Device=require('device');require('document/canvascontext'):init(Device)
Device.screen.shot=function() error('screenshots_disabled',0) end
local Settings=require('weread.lib.settings');local new=Settings.new
function Settings:new()
    local value=new(self)
    local flush=value.store.flush
    value.store.flush=function(store,...)
        local held={};local secrets={'account','cookies','api_key','wr_ticket','wr_wrpa','device_fingerprint'}
        for _,key in ipairs(secrets) do held[key]=store.data[key];store.data[key]=nil end
        local result={pcall(flush,store,...)}
        for _,key in ipairs(secrets) do store.data[key]=held[key] end
        assert(result[1]);return unpack(result,2)
    end
    for key,item in pairs(auth) do value.store:saveSetting(key,item) end
    value.settings_file=auth_path
    local sync=value:get('sync');sync.pull_on_open=false;sync.upload_on_close=false;sync.upload_interval_minutes=0;value:set('sync',sync)
    local cache=value:get('cache');cache.show_annotations=false;cache.auto_prefetch_next_chapter=false
    cache.download_book_images=false;cache.download_underlines_and_thoughts=false;value:set('cache',cache)
    local report=value:get('read_report');report.enabled=false;value:set('read_report',report)
    if input.mock_endpoint then value.mock_endpoint=input.mock_endpoint end
    return value
end
local store={read=function() return input.credentials,1,nil,false end}
local Native=require('weread.lib.native_read_access');local original_capture=Native.capture
Native.capture=function(settings,existing) return original_capture(settings,existing or store) end
local memory=ffi.C.mmap(nil,4096,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1));local counters=ffi.cast('int *',memory)
local Protocol=require('weread.lib.protocol');local allowed={}
for _,cursor in ipairs(input.allowed) do
    allowed['https://weread.qq.com/web/book/search_v2?'..Protocol.sorted_query({bookId=input.book_id,
        chapterUid=cursor.chapter,keyword=input.keyword,posBegin=cursor.start,posEnd=cursor.finish,mode='scrollDown',count=50})]=true
end
local Client=require('weread.lib.client');local request=Client.request
function Client:request(options)
    local url=options.url;local method=options.method or 'GET';local native='https://i.weread.qq.com';local web='https://weread.qq.com'
    local accepted=false
    if url==native..'/book/info?bookId='..input.book_id then accepted=method=='GET'
    elseif url==native..'/book/chapterInfos' then
        local body=json.decode(options.body);accepted=method=='POST' and #body.bookIds==1 and body.bookIds[1]==input.book_id
            and body.synckeys[1]==0 and body.updateTimes[1]==0 and body.maxfreeIdx[1]==0
    elseif type(url)=='string' and url:find(native..'/book/chapterdownload?',1,true)==1 then
        accepted=method=='GET' and url:find('bookId='..input.book_id..'&',1,true)~=nil
            and url:find('chapters=0%2C'..input.uid..'&',1,true)~=nil
            and url:find('stopAutoPayWhenBNE=1',1,true)~=nil and url:find('preview=0',1,true)~=nil
    elseif url==web..'/api/userInfo?userVid='..input.credentials.vid then accepted=method=='GET'
    elseif url==web..'/web/book/chapterInfos' then
        local body=json.decode(options.body);accepted=method=='POST' and #body.bookIds==1 and body.bookIds[1]==input.book_id
        for key in pairs(body) do if key~='bookIds' then accepted=false end end
    elseif url==Protocol.reader_url(input.book_id) or url==Protocol.reader_url(input.book_id,input.uid) then accepted=method=='GET'
    elseif url==web..'/web/book/chapter/e_0' or url==web..'/web/book/chapter/e_1' or url==web..'/web/book/chapter/e_3' then
        local body=json.decode(options.body);accepted=method=='POST' and body.b==Protocol.e(input.book_id)
            and body.c==Protocol.e(input.uid) and body.sc==1 and body.prevChapter==false and body.st==0
        local keys={b=true,c=true,r=true,ct=true,ps=true,pc=true,sc=true,prevChapter=true,st=true,s=true};local count=0
        for key in pairs(body) do if not keys[key] then accepted=false end;count=count+1 end
        accepted=accepted and count==10
    elseif allowed[url] then accepted=method=='GET';counters[1]=counters[1]+1;accepted=accepted and counters[1]<=#input.allowed
    elseif type(url)=='string' and require('weread.lib.native_chapter_remote').allowed(url)==url then
        local headers=options.headers or {};accepted=method=='GET' and not headers.vid and not headers.accessToken and not headers.Cookie
    end
    counters[0]=counters[0]+1
    if not accepted or counters[0]>100 then counters[2]=counters[2]+1;error('read_only_scope',0) end
    return request(self,options)
end
local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
for _,item in ipairs(Loader:_discover()) do if item.name=='weread' then Loader:_load{item} end end
assert(#Loader.enabled_plugins==1)
local UI=require('ui/uimanager');local socket=require('socket');local Reader=require('apps/reader/readerui')
local stage='reader'
local function wait(predicate)
    local deadline=socket.gettime()+150
    while not predicate() do
        if socket.gettime()>deadline then print('WEREAD_DIRECT_ONLINE_STAGE='..stage);error('online_search_timeout') end
        UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
    end
end
Reader:showReader(input.path);wait(function() return Reader.instance and Reader.instance.weread end)
local reader=Reader.instance;local host=reader.weread
local function configure(active)
    active.isNetworkOnline=function() return true end;active.isNetworkConnected=active.isNetworkOnline
    active.showInfo=function(self) self.failed=true end
end
configure(host)
local open=host.openFile
host.openFile=function(self,path,callback,...)
    return open(self,path,function(next_reader) configure(assert(next_reader.weread));return callback(next_reader) end,...)
end
assert(host:onShowWeReadQuickMenu())
stage='quick';wait(function() local top=UI:getTopmostVisibleWidget();return top and type(top.getButtonById)=='function' and top:getButtonById('search_book') end)
local button=assert(UI:getTopmostVisibleWidget():getButtonById('search_book'));assert(button.enabled~=false);button:onTapSelectButton()
stage='input';wait(function() return host._book_search_owner and host._book_search_owner.input end)
local owner=host._book_search_owner;owner.input:setInputText(input.keyword);owner.input.buttons[1][2].callback()
local chosen,chosen_index
for _=1,#input.allowed do
    stage='results';wait(function() return host.failed or owner.state and not owner.job and not owner.recovery end)
    assert(not host.failed)
    for index,hit in ipairs(owner.value) do
        if hit.chapter_uid==input.uid and hit.start==input.start and hit.finish==input.finish and hit.text==input.keyword then
            chosen,chosen_index=hit,index;break
        end
    end
    if chosen then break end
    local more
    for _,item in ipairs(owner.menu.item_table) do if item.text==require('weread.lib.plugin_util').tr('Load more results') then more=item end end
    assert(more);owner.menu:onMenuSelect(more)
end
assert(chosen)
local target=owner.menu.item_table[#owner.menu.item_table-#owner.value+chosen_index]
assert(target and target.select_enabled~=false and target.text:find(input.keyword,1,true));owner.menu:onMenuSelect(target)
local destination
if input.cross then stage='switch';wait(function() return host.failed or Reader.instance and Reader.instance~=reader end)
    assert(not host.failed);destination=Reader.instance
else destination=reader end
local next_host=assert(destination.weread)
stage='locate';wait(function() return host.failed or next_host.failed
    or not owner.navigation and not next_host._native_online_search_incoming and not next_host._native_online_search_open end)
assert(not host.failed and not next_host.failed)
local matches=assert(destination.document:findAllText(input.keyword,false,0,64,false,0));local visible=false
for _,match in ipairs(matches) do if match.start and destination.document:isXPointerInCurrentPage(match.start) then visible=true end end
assert(visible and counters[1]>=1 and counters[2]==0)
print('WEREAD_DIRECT_OWNER_ONLINE_SEARCH='..json.encode{ok=true,cross=input.cross,installed_plugin=true,
    independent_text=true,blocked_requests=0,search_requests=tonumber(counters[1])})
