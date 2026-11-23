-- Real plugin details -> native catalog -> ReaderUI; private data stays in tmpfs.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
assert(os.getenv('WEREAD_DIRECT_OWNER_TMPFS')=='1')
local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/'))
local plugin=home..'/plugins/weread.koplugin';package.path=plugin..'/?.lua;'..package.path
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua');G_defaults=require('luadefaults'):open()
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
local Device=require('device');require('document/canvascontext'):init(Device)
local json=require('json');local input=json.decode(assert(io.stdin:read('*a')))
local Settings=require('weread.lib.settings');local settings=Settings:new()
settings:set('account',{user_vid=input.credentials.vid,name='Synthetic',login_method='qr'})
settings:set('cookies',{})
local sync=settings:get('sync');sync.pull_on_open=false;sync.upload_on_close=false;sync.upload_interval_minutes=0;settings:set('sync',sync)
local cache=settings:get('cache');cache.show_annotations=false;cache.auto_prefetch_next_chapter=false
cache.download_book_images=false;cache.download_underlines_and_thoughts=false;settings:set('cache',cache)
local report=settings:get('read_report');report.enabled=false;settings:set('read_report',report);settings:flush()
local store={read=function() return input.credentials,1,nil,false end}
local Access=require('weread.lib.native_read_access');local capture=Access.capture
Access.capture=function(s,existing) return capture(s,existing or store) end
local Common=require('weread.ui.common')
Common.isNetworkOnline=function() return true end;Common.isNetworkConnected=Common.isNetworkOnline
local Client=require('weread.lib.client');local previous=Client.request
Client.request=function(self,options)
    local url,headers=options.url,options.headers or {};local base='https://i.weread.qq.com'
    assert(options.skip_cookie and options.persist_response_cookies==false and options.sensitive)
    if url==base..'/book/info?bookId='..input.book_id then assert(options.method=='GET')
    elseif url==base..'/book/chapterInfos' then
        local body=json.decode(options.body)
        assert(options.method=='POST' and #body.bookIds==1 and body.bookIds[1]==input.book_id
            and body.synckeys[1]==0 and body.updateTimes[1]==0 and body.maxfreeIdx[1]==0)
    elseif url:find(base..'/book/chapterdownload?',1,true)==1 then
        assert(options.method=='GET' and url:find('bookId='..input.book_id..'&',1,true)
            and url:find('chapters=0%2C'..input.uid..'&',1,true)
            and url:find('stopAutoPayWhenBNE=1',1,true) and url:find('preview=0',1,true))
    else
        assert(options.method=='GET' and require('weread.lib.native_chapter_remote').allowed(url)==url
            and not headers.vid and not headers.accessToken and not headers.Cookie)
    end
    if url:find(base,1,true)==1 then
        assert(headers.vid==input.credentials.vid and headers.accessToken==input.credentials.accessToken)
    end
    local count=assert(io.open(home..'/request-count','ab'));assert(count:write('1'));assert(count:close())
    return previous(self,options)
end
local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
for _,item in ipairs(Loader:_discover()) do if item.name=='weread' then Loader:_load{item} end end
assert(#Loader.enabled_plugins==1)
local UI=require('ui/uimanager');local socket=require('socket')
local FM=require('apps/filemanager/filemanager');local Reader=require('apps/reader/readerui')
local function pump(fn)
    local deadline=socket.gettime()+120
    while not fn() do
        assert(socket.gettime()<deadline,'full native home timeout')
        UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
    end
end
FM:showFiles(home);local host=assert(FM.instance.weread)
host.settings.mock_endpoint=input.mock_endpoint
host:showBookRecord({book_id=input.book_id,title='Synthetic book',author='Fixture'},{verified_metadata=true})
local view=assert(host._book_detail_view);local button
for _,item in ipairs(view._action_buttons) do
    if item.text==require('weread.lib.plugin_util').tr('Read E-Ink chapter') then button=item end
end
assert(button and button.enabled~=false);button.callback()
pump(function() return host._native_direct_reading and host._native_direct_reading.menu end)
local ctx=assert(host._native_direct_reading);local index
for i,row in ipairs(ctx.catalog.chapters) do if row.chapterUid==input.uid then assert(not index and row.downloadable);index=i end end
assert(index and ctx.menu.item_table[index].select_enabled)
ctx.menu:onMenuSelect(ctx.menu.item_table[index])
pump(function() return Reader.instance and Reader.instance.weread and Reader.instance.document end)
local reader=Reader.instance;local path=reader.document.file
assert(require('weread.lib.native_direct_path').contains(reader.weread.settings,path))
pump(function() local book=reader.weread.settings:get_book(input.book_id)
    return book and book.native_home_resume and book.native_home_resume.entry end)
local entry=reader.weread.settings:get_book(input.book_id).native_home_resume.entry
assert(entry.book_id==input.book_id and entry.chapter_uid==input.uid and entry.book_version==input.book_version
    and entry.source_sha256==input.source_sha256 and not reader.weread:detectWeReadBook())
if reader.document:getPageCount()<2 then assert(reader.font:onSetFontSize(48));UI:forceRePaint() end
assert(reader.document:getPageCount()>=2)
local first=assert(reader.document:getXPointer());reader.rolling:onGotoPage(2);UI:forceRePaint()
local anchor=assert(reader.document:getXPointer());assert(anchor~=first)
local file=assert(io.open(home..'/anchor','wb'));assert(file:write(anchor));assert(file:close())
while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=reader do UI:close(UI:getTopmostVisibleWidget()) end
reader.weread:onFlushSettings();reader:onClose(false);assert(not Reader.instance)
local count=assert(io.open(home..'/request-count','rb'));local requests=#assert(count:read('*a'));assert(count:close())
print('WEREAD_DIRECT_HOME_FULL='..json.encode{ok=true,path=path,requests=requests,source_matches=true})
