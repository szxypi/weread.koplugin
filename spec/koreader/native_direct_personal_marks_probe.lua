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
local ffi=require('ffi');local reader_pid=ffi.C.getpid()
local diagnostic
local function wait(predicate)
    local deadline=socket.gettime()+15
    while not predicate() do
        if socket.gettime()>=deadline then if diagnostic then diagnostic() end;error('personal direct timeout',0) end;UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01) end
end
local function configure(active)
    active.settings.mock_endpoint=input.mock_endpoint
    active.isNetworkConnected=function() return not input.offline end
    active.isNetworkOnline=function()
        local caller=debug.getinfo(2,'S')
        if caller and caller.source:find('weread/ui/personal_marks.lua',1,true) then
            assert(ffi.C.getpid()~=reader_pid,'personal marks performed a network check on the reader process')
        end
        return not input.offline
    end
    local previous=active.client.request
    active.client.request=function(self,options)
        assert(not input.offline,'offline personal mark requested network')
        local url=options.url;assert(options.sensitive and options.skip_cookie and options.persist_response_cookies==false)
        local native='https://i.weread.qq.com';local web='https://weread.qq.com'
        assert(url==native..'/book/info?bookId=42' or url==native..'/book/chapterInfos'
            or url==native..'/book/bookmarklist?bookId=42&synckey=0'
            or url==native..'/review/list?bookId=42&listType=11&listMode=0&mine=1&synckey=0&count=20'
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
    reader.rolling:onGotoPage(3);UI:forceRePaint();local before=reader.document:getCurrentPage()
    local tr=require('weread.lib.plugin_util').tr;local action
    for _,item in ipairs(host:getMainMenuItems()) do if item.text==tr('My cloud highlights') then action=item.callback end end
    assert(action);action();wait(function() return host._my_marks_owner~=nil end)
    local owner=host._my_marks_owner;local target
    for _,item in ipairs(owner.menu.item_table) do if item.my_note_id=='synthetic-direct-mark' then target=item end end
    assert(target);target.callback();UI:forceRePaint()
    local failed=false;host.showInfo=function() failed=true end
    assert(owner.menu._shelf_popup.button_table:getButtonById('open_highlight')):onTapSelectButton()
    wait(function() return failed end)
    assert(reader.document:getCurrentPage()==before and host._my_marks_owner==owner,'corrupt source changed the reading position')
    require('weread.ui.my_cloud_marks').cancel(host)
else
    wait(function() state=host._personal_marks;return state and state.complete end)
    assert(state.direct and #state.records==2,'direct mark and thought did not both appear')
    local mark,thought
    for _,item in ipairs(state.records) do
        if item.bookmarkId=='synthetic-direct-mark' then mark=item end
        if item.thoughtId=='synthetic-direct-thought' then thought=item end
    end
    assert(mark and thought and thought.style==3,'thought identity or distinct style missing')
    assert(#state.bookmarks==2,'direct same-page bookmarks missing')
    if input.force_fallback then assert(fallback_count>0,'verified search fallback was not used') end
    for _,row in ipairs({mark,thought}) do
        local text=assert(reader.document:getTextFromXPointers(row.pos0,row.pos1))
        assert(require('weread.lib.source_dom').normalize(text)==require('weread.lib.source_dom').normalize('Unique paragraph 0001'))
    end
    reader.document:clearSelection();UI:forceRePaint()
    assert(#state.overlay.visible>0,'direct personal mark has no visible native boxes')
    local rect=state.overlay.visible[1].rect
    assert(Display.tap(host,{pos={x=rect.x+1,y=rect.y+1}}),'overlapping notes did not open')
    assert(state.picker and #state.picker.item_table==2,'overlapping notes were not offered separately')
    local choices=state.picker.item_table
    local thought_choice
    for _,item in ipairs(choices) do if item.my_note_kind=='thought' then thought_choice=item end end
    assert(thought_choice,'thought choice missing');thought_choice.callback()
    assert(host._my_marks_owner and host._my_marks_owner.thoughts and host._my_marks_owner.menu._shelf_popup,
        'thought choice did not open its content')
    require('weread.ui.my_cloud_marks').cancel(host)
    reader.rolling:onGotoXPointer(state.bookmarks[1].pos0);UI:forceRePaint()
    assert(#state.indicator.visible==2,'direct cloud bookmarks do not share a visible corner')
    for _,id in ipairs({'synthetic-direct-point','synthetic-direct-point-two'}) do
        local corner=assert(state.indicator.rect)
        assert(Display.tap(host,{pos={x=corner.x+1,y=corner.y+1}},true),'bookmark corner did not open')
        local picker=assert(state.picker);local choice
        for _,item in ipairs(picker.item_table) do if item.my_note_kind=='bookmark' and item.my_note_id==id then choice=item end end
        assert(choice and choice.text:find('paragraph 0001',1,true),'bookmark preview missing');choice.callback()
        local owner=assert(host._my_marks_owner);assert(owner.bookmarks and owner.menu._shelf_popup,'chosen bookmark popup missing')
        local expected=id=='synthetic-direct-point' and 'Unique paragraph 0001' or 'nique paragraph 0001'
        assert(owner.menu._shelf_popup.text:find(expected,1,true),'wrong bookmark opened')
        require('weread.ui.my_cloud_marks').cancel(host);UI:forceRePaint()
    end
    local first_bookmark
    for _,item in ipairs(state.bookmarks) do if item.bookmarkId=='synthetic-direct-point' then first_bookmark=item end end
    assert(first_bookmark)
    local notes_cases={
        {label='My cloud highlights',id='synthetic-direct-mark',button='open_highlight',target=mark.pos0},
        {label='My cloud thoughts',id='synthetic-direct-thought',button='open_thought_quote',target=thought.pos0},
        {label='My cloud bookmarks',id='synthetic-direct-point',button='open_bookmark',target=first_bookmark.pos0},
    }
    for _,case in ipairs(notes_cases) do
        reader.rolling:onGotoPage(3);UI:forceRePaint()
        local menu_action;local tr=require('weread.lib.plugin_util').tr
        for _,item in ipairs(host:getMainMenuItems()) do if item.text==tr(case.label) then menu_action=item.callback end end
        assert(menu_action,'direct cloud notes entry missing');menu_action()
        wait(function() return host._my_marks_owner~=nil end)
        local owner=host._my_marks_owner;local item
        for _,candidate in ipairs(owner.menu.item_table) do if candidate.my_note_id==case.id then item=candidate end end
        assert(item,'direct cloud note missing');item.callback();UI:forceRePaint()
        local popup=assert(owner.menu._shelf_popup)
        assert(popup.button_table:getButtonById(case.button),'direct note navigation action missing'):onTapSelectButton()
        wait(function() return not host._my_marks_owner end)
        assert(reader.document:isXPointerInCurrentPage(case.target),'direct cloud note did not navigate to its original page')
    end
    -- Exercise the actual CREngine boxes with the installed personal painter.
    -- Repeat paints must preserve every draw command and hit target while
    -- preparing their merged geometry only once per cached page.
    do
        reader.rolling:onGotoXPointer(mark.pos0);UI:forceRePaint()
        local layer=state.overlay;local original=layer.prepare_painter;local preparations=0
        layer.prepare_painter=function(boxes) preparations=preparations+1;return original(boxes) end
        layer:invalidate()
        local commands={};local canvas={paintRect=function(_,x,y,w,h) commands[#commands+1]={'p',x,y,w,h} end,
            darkenRect=function(_,x,y,w,h,alpha) commands[#commands+1]={'d',x,y,w,h,alpha} end}
        layer:paintTo(canvas,0,0);local first=json.encode(commands)
        assert(#commands>0 and preparations==1 and #layer.visible>0)
        local mark_rect=layer.visible[1].rect;local hits=#layer:hitTestAll{x=mark_rect.x+1,y=mark_rect.y+1}
        commands={};layer:paintTo(canvas,0,0)
        assert(json.encode(commands)==first and preparations==1 and #layer:hitTestAll{x=mark_rect.x+1,y=mark_rect.y+1}==hits,
            'cached personal marks changed their drawing or hit targets')
        layer.prepare_painter=original
    end
    -- A real CREngine viewport must keep the same bookmark results when a
    -- reader revisits a recently painted page, without another full scan.
    do
        local document=reader.document;local pointer=state.bookmarks[1].pos0
        reader.rolling:onGotoXPointer(pointer);UI:forceRePaint()
        local page=document:getCurrentPage();local other=page<document:getPageCount() and page+1 or page-1
        assert(other>=1 and other~=page)
        local layer=require('weread.ui.bookmark_indicator'):new{color=0};layer.ui=reader;layer.view=reader.view
        local points={};for i=1,512 do points[i]={pos0=pointer,bookmarkId='cache-test-'..i} end
        layer:setRecords(points)
        local original=document.isXPointerInCurrentPage;local own=rawget(document,'isXPointerInCurrentPage');local queries=0
        document.isXPointerInCurrentPage=function(self,xp) queries=queries+1;return original(self,xp) end
        local canvas={paintRect=function() end}
        local before=queries;layer:paintTo(canvas,0,0);assert(queries-before==512 and #layer.visible==512)
        reader.rolling:onGotoPage(other);UI:forceRePaint()
        before=queries;layer:paintTo(canvas,0,0);assert(queries-before==512 and #layer.visible==0)
        reader.rolling:onGotoXPointer(pointer);UI:forceRePaint()
        before=queries;layer:paintTo(canvas,0,0);assert(queries-before==0 and #layer.visible==512,
            'returning to a recently viewed page repeated native bookmark scans')
        document.isXPointerInCurrentPage=own
    end
    Display.suspend(host);UI:forceRePaint();assert(not state.overlay.enabled)
    Display.wake(host);wait(function() return state.complete end);UI:forceRePaint()
    assert(state.overlay.enabled and #state.overlay.visible>0,'direct personal mark not restored')
end
assert(host.client:json_encode(reader.annotation.annotations)==notes,'native notes modified')
print('WEREAD_DIRECT_PERSONAL='..json.encode{ok=true,offline=input.offline==true,missing=input.expect_missing==true})
