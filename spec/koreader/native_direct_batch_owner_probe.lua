-- Account data and chapter text remain in an isolated tmpfs profile/stdin.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
assert(os.getenv('WEREAD_DIRECT_OWNER_TMPFS')=='1')
local plugin=assert(arg[1]);package.path=plugin..'/?.lua;'..package.path
local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/'))
local json=require('json');local input=json.decode(assert(io.stdin:read('*a')))
local vid=assert(input.vid or input.credentials and input.credentials.vid)
local expected=assert(input.sources);local book_id=assert(input.book_id)
local scope={vid=vid,epoch=1}
local settings={data_dir=home,cache_dir=home,mock_endpoint=input.mock_endpoint,
    get=function(_,_,default) return default end,get_auth_scope=function() return scope end,
    auth_scope_matches=function(_,value) return value==scope end}
local count=0;for uid,value in pairs(expected) do
    assert(type(uid)=='string' and uid:match('^[1-9]%d*$') and type(value.sha256)=='string' and #value.sha256==64)
    count=count+1
end
assert(count>=1 and count<=8 and input.total>=count and input.total<=200)
G_reader_settings=require('luasettings'):wrap({});G_defaults=require('luadefaults'):open()
local Device=require('device');require('document/canvascontext'):init(Device)
local Cache=require('weread.lib.native_direct_cache')
if input.mode=='offline' then
    assert(dofile(assert(arg[3])..'/spec/koreader/offline_network_guard.lua')())
    local rows=assert(Cache.list(settings,vid,book_id,function() return true end));assert(#rows==count)
    local seen={};local tokens=0
    for _,entry in ipairs(rows) do
        local reference=assert(expected[entry.chapter_uid]);assert(not seen[entry.chapter_uid]);seen[entry.chapter_uid]=true
        assert(entry.book_version==input.version and entry.source_sha256==reference.sha256)
        local saved=assert(Cache.open(settings,vid,book_id,entry,function() return true end))
        local doc=assert(require('document/documentregistry'):openDocument(saved.path))
        assert(doc:loadDocument());doc:setFontFace('Noto Sans');doc:setFontSize(Device.screen:scaleBySize(24));doc:render()
        assert(doc:getPageCount()>0)
        if reference.token then
            local hits=assert(doc:findAllText(reference.token,false,0,8,false,0));assert(hits[1]);tokens=tokens+1
        end
        doc:close()
    end
    print('WEREAD_BATCH_OWNER='..json.encode{ok=true,mode='offline',chapters=count,tokens=tokens,network_blocked=true})
    return
end
assert((input.mode=='online' or input.mode=='repeat') and input.credentials and input.credentials.vid==vid)
local store={read=function() return input.credentials,1,nil,false end}
local Access=require('weread.lib.native_read_access');local original=Access.capture
Access.capture=function(s,existing) return original(s,existing or store) end
local client=require('weread.lib.client'):new(settings);local request=client.request;local requested={}
client.request=function(self,options)
    local url,headers=options.url,options.headers or {};local base='https://i.weread.qq.com'
    assert(options.skip_cookie and options.persist_response_cookies==false and options.sensitive)
    if url==base..'/book/info?bookId='..book_id then assert(options.method=='GET')
    elseif url==base..'/book/chapterInfos' then
        assert(options.method=='POST');local body=json.decode(options.body)
        assert(#body.bookIds==1 and body.bookIds[1]==book_id and body.synckeys[1]==0
            and body.updateTimes[1]==0 and body.maxfreeIdx[1]==0)
    elseif url:find(base..'/book/chapterdownload?',1,true)==1 then
        local uid=url:match('[?&]chapters=0%%2C([1-9]%d*)&')
        assert(input.mode=='online' and options.method=='GET' and url:find('bookId='..book_id..'&',1,true)
            and uid and expected[uid] and not requested[uid]
            and url:find('stopAutoPayWhenBNE=1',1,true) and url:find('preview=0',1,true))
        requested[uid]=true
    else
        assert(options.method=='GET' and require('weread.lib.native_chapter_remote').allowed(url)==url
            and not headers.vid and not headers.accessToken and not headers.Cookie)
    end
    if url:find(base,1,true)==1 then assert(headers.vid==vid and headers.accessToken==input.credentials.accessToken) end
    local ledger=home..'/request-count';local previous=io.open(ledger,'rb');local n=0
    if previous then n=#assert(previous:read('*a'));assert(previous:close()) end
    assert(n<200);local output=assert(io.open(ledger,'ab'));assert(output:write('1'));assert(output:close())
    return request(self,options)
end
local UI=require('ui/uimanager');local socket=require('socket')
local function wait(predicate)
    local deadline=socket.gettime()+300
    while not predicate() do
        assert(socket.gettime()<deadline,'owner batch timeout')
        UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
    end
end
local result
local worker=require('weread.lib.memory_worker'):new{scheduler=UI,codec=client,max_bytes=8*1024*1024,timeout=3600}
local host={settings=settings,client=client,discovery_epoch=1,_reader_session_gen=1,
    library_db={accountKey=function() return 'fixture' end,getChapters=function() return {} end},ui={},
    isNetworkConnected=function() return true end,
    showBusy=function(self,label,cancel)
        self.busy_message=require('ui/widget/infomessage'):new{text=label,callback=cancel};UI:show(self.busy_message)
    end,
    closeBusy=function(self) UI:close(self.busy_message);self.busy_message=nil end,
    showInfo=function(self) self.completed=true end,showOffline=function(self) self.completed=true end,
    showList=require('weread.ui.common').showList,showBookMenu=require('weread.ui.library').showBookMenu,
    getFullBookCachePath=function() return home..'/missing.epub' end,bookRecordHasDownload=function() return false end,
    safeCallback=function(_,_,callback) return callback end,openFile=function() error('unexpected reader') end,
    _native_direct_worker={cancel=function() worker:cancel() end,start=function(_,task,callback,progress)
        return worker:start(task,function(value) result=value;callback(value) end,progress)
    end}}
host:showBookMenu({book_id=book_id,title='Verification',author='Fixture',chapters={}})
local view=assert(host._book_detail_view);local action
for _,button in ipairs(view._action_buttons) do
    if button.text==require('weread.lib.plugin_util').tr('Download E-Ink chapters') then action=button end
end
assert(action);action.callback()
wait(function() return host.completed or host._native_direct_reading and host._native_direct_reading.confirm end)
if host.completed then print('WEREAD_BATCH_OWNER='..json.encode{ok=false,phase='catalog'});return end
local ctx=assert(host._native_direct_reading);local catalog=assert(ctx.catalog)
assert(catalog.version==input.version and #catalog.chapters==input.total)
local live_count=0
for _,row in ipairs(catalog.chapters) do
    if row.downloadable then assert(expected[row.chapterUid]);live_count=live_count+1 end
end
assert(live_count==count)
local confirm=assert(ctx.confirm);confirm.ok_callback();UI:close(confirm)
wait(function() return host.completed end)
if type(result)~='table' or result.ok~=true then
    local allowed={auth_expired=true,rate_limited=true,session_changed=true,catalog_changed=true,
        unavailable=true,not_entitled=true,storage=true,invalid_source=true,invalid=true}
    print('WEREAD_BATCH_OWNER='..json.encode{ok=false,phase='download',reason=allowed[result and result.error] and result.error or 'other'})
    return
end
assert(result.downloaded==(input.mode=='online' and count or 0)
    and result.saved==(input.mode=='repeat' and count or 0) and result.unavailable==input.total-count)
local rows=assert(Cache.list(settings,vid,book_id,function() return true end));assert(#rows==count)
local missing=0
for _,entry in ipairs(rows) do
    local reference=assert(expected[entry.chapter_uid])
    assert(entry.book_version==input.version and entry.source_sha256==reference.sha256)
    assert(Cache.open(settings,vid,book_id,entry,function() return true end))
    if entry.missing_images>0 then missing=missing+1 end
end
assert(missing==result.missing and not host._native_direct_reading and not host.busy_message)
local ledger=assert(io.open(home..'/request-count','rb'));local requests=#assert(ledger:read('*a'));assert(ledger:close())
print('WEREAD_BATCH_OWNER='..json.encode{ok=true,mode=input.mode,chapters=count,unavailable=input.total-count,
    missing=missing,requests=requests,source_matches=true})
