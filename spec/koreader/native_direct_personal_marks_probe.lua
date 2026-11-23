-- Installed plugin, actual native ReaderUI and one closed synthetic account.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
assert(os.getenv('WEREAD_SYNTHETIC')=='1')
local home=assert(os.getenv('KO_HOME'));local plugin=home..'/plugins/weread.koplugin'
package.path=plugin..'/?.lua;'..package.path
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua');G_defaults=require('luadefaults'):open()
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
local Device=require('device');require('document/canvascontext'):init(Device)
local json=require('json');local input=json.decode(assert(io.stdin:read('*a')))
local settings=require('weread.lib.settings'):new()
settings:set('account',{user_vid=input.credentials.vid,name='Synthetic',login_method='qr'})
settings:set('cookies',{wr_vid = input.credentials.vid,wr_skey = 'synthetic-web-access'});settings:flush()
local scope=assert(settings:get_auth_scope())
local credentials=require('weread.lib.native_credentials'):new(settings)
local existing,revision=credentials:read()
if existing then
    assert(existing.vid==input.credentials.vid and existing.accessToken==input.credentials.accessToken)
else assert(credentials:save(input.credentials,scope,revision or 0,1)) end
local fallback_count=0
if input.force_fallback then
    local Dom=require('weread.lib.source_dom');local open=Dom.open_direct_prepared
    Dom.open_direct_prepared=function(...)
        local index,why=open(...)
        if index then
            index.locate_span=function(self) self.invalid='walk_diverged';return nil,'source_dom/walk_diverged' end
            local search=index.locate_span_search
            index.locate_span_search=function(self,...)
                fallback_count=fallback_count+1;return search(self,...)
            end
            local point=index.locate_point_search
            index.locate_point_search=function(self,...)
                fallback_count=fallback_count+1;return point(self,...)
            end
        end
        return index,why
    end
end
local loader=require('pluginloader');loader.enabled_plugins,loader.disabled_plugins,loader.loaded_plugins={},{},{}
for _,item in ipairs(loader:_discover()) do if item.name=='weread' then loader:_load{item} end end
assert(#loader.enabled_plugins==1)
local UI=require('ui/uimanager');local socket=require('socket');local Reader=require('apps/reader/readerui')
local diagnostic
local function wait(predicate)
    local deadline=socket.gettime()+15
    while not predicate() do
        if socket.gettime()>=deadline then if diagnostic then diagnostic() end;error('personal direct timeout',0) end;UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01) end
end
local function configure(active)
    active.settings.mock_endpoint=input.mock_endpoint
    active.isNetworkConnected=function() return not input.offline end
    active.isNetworkOnline=function() return not input.offline end
    local previous=active.client.request
    active.client.request=function(self,options)
        assert(not input.offline,'offline personal mark requested network')
        local url=options.url;assert(options.sensitive and options.skip_cookie and options.persist_response_cookies==false)
        local native='https://i.weread.qq.com';local web='https://weread.qq.com'
        assert(url==native..'/book/info?bookId=42' or url==native..'/book/chapterInfos'
            or url==native..'/book/bookmarklist?bookId=42&synckey=0'
            or url:find(native..'/book/chapterdownload?',1,true)==1
            or url==web..'/api/userInfo?userVid=12345678' or url==web..'/web/book/chapterInfos'
            or url:find(web..'/web/reader/',1,true)==1 or url:find(web..'/web/book/chapter/e_',1,true)==1,
            'personal direct request outside scope')
        return previous(self,options)
    end
end
local Display=require('weread.ui.personal_marks');local attach=Display.attach
Display.attach=function(active) configure(active);return attach(active) end
Reader:showReader(input.path);wait(function() return Reader.instance and Reader.instance.document and Reader.instance.weread end)
local reader=Reader.instance;local host=reader.weread
diagnostic=function()
    local value=host._personal_marks
    print('WEREAD_DIRECT_PERSONAL_DIAG='..json.encode{attached=value~=nil,direct=value and value.direct or false,
        loading=value and value.loading or false,loaded=value and value.loaded or false,complete=value and value.complete or false,
        entry=value and value.entry~=nil or false,job=value and value.job~=nil or false,task=value and value.task~=nil or false,
        snapshot=value and value.snapshot~=nil or false,records=value and #value.records or 0})
end
local notes=host.client:json_encode(reader.annotation.annotations)
local state
if input.expect_missing then
    wait(function() state=host._personal_marks;return state and state.loaded and not state.loading and not state.job and not state.task end)
    assert(#state.records==0 and #state.bookmarks==0,'corrupt cached source displayed')
else
    wait(function() state=host._personal_marks;return state and state.complete end)
    assert(state.direct and #state.records==1 and state.records[1].bookmarkId=='synthetic-direct-mark')
    assert(#state.bookmarks==1 and state.bookmarks[1].bookmarkId=='synthetic-direct-point','direct bookmark missing')
    if input.force_fallback then assert(fallback_count>0,'verified search fallback was not used') end
    local row=state.records[1]
    local text=assert(reader.document:getTextFromXPointers(row.pos0,row.pos1))
    assert(require('weread.lib.source_dom').normalize(text)==require('weread.lib.source_dom').normalize('Unique paragraph 0001'))
    reader.document:clearSelection();UI:forceRePaint()
    assert(#state.overlay.visible>0,'direct personal mark has no visible native boxes')
    reader.rolling:onGotoXPointer(state.bookmarks[1].pos0);UI:forceRePaint()
    assert(#state.indicator.visible==1,'direct cloud bookmark has no visible corner')
    Display.suspend(host);UI:forceRePaint();assert(not state.overlay.enabled)
    Display.wake(host);wait(function() return state.complete end);UI:forceRePaint()
    assert(state.overlay.enabled and #state.overlay.visible>0,'direct personal mark not restored')
end
assert(host.client:json_encode(reader.annotation.annotations)==notes,'native notes modified')
print('WEREAD_DIRECT_PERSONAL='..json.encode{ok=true,offline=input.offline==true,missing=input.expect_missing==true})
