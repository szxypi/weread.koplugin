-- Owner-only private ReaderUI probe; credentials and output cross pipes/tmpfs.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
assert(os.getenv('WEREAD_DIRECT_OWNER_TMPFS')=='1')
local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/'))
local plugin=home..'/plugins/weread.koplugin';package.path=plugin..'/?.lua;'..package.path
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua');G_defaults=require('luadefaults'):open()
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
local Device=require('device');require('document/canvascontext'):init(Device)
local json=require('json');local input=json.decode(assert(io.stdin:read('*a')))
local settings=require('weread.lib.settings'):new()
settings:set('account',{user_vid=input.credentials.vid,login_method='qr'});settings:set('cookies',{});settings:flush()
local store={read=function() return input.credentials,1,nil,false end}
local Access=require('weread.lib.native_read_access');local capture=Access.capture
Access.capture=function(s,existing) return capture(s,existing or store) end
local loader=require('pluginloader');loader.enabled_plugins,loader.disabled_plugins,loader.loaded_plugins={},{},{}
for _,item in ipairs(loader:_discover()) do if item.name=='weread' then loader:_load{item} end end
assert(#loader.enabled_plugins==1)
local UI=require('ui/uimanager');local socket=require('socket');local Reader=require('apps/reader/readerui')
local diagnostic
local function wait(predicate)
    local deadline=socket.gettime()+(input.mock_endpoint and 20 or 120)
    while not predicate() do
        if socket.gettime()>=deadline then if diagnostic then diagnostic() end;error('personal owner timeout',0) end
        UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
    end
end
local native='https://i.weread.qq.com';local web='https://weread.qq.com';local proto=require('weread.lib.protocol')
local function configure(host)
    host.settings.mock_endpoint=type(input.mock_endpoint)=='string' and input.mock_endpoint or nil
    local original_get=host.settings.get
    host.settings.get=function(self,key,default)
        if key=='cookies' then return input.web_cookies end
        return original_get(self,key,default)
    end
    host.isNetworkConnected=function() return not input.offline end
    host.isNetworkOnline=function() return not input.offline end
    local previous=host.client.request
    host.client.request=function(self,options)
        assert(not input.offline and options.sensitive and options.skip_cookie and options.persist_response_cookies==false)
        local url=options.url;local headers=options.headers or {}
        if url==native..'/book/info?bookId='..input.book_id
            or url==native..'/book/bookmarklist?bookId='..input.book_id..'&synckey=0' then assert(options.method=='GET')
        elseif input.expect_thoughts and url:find(native..'/review/list?bookId='..input.book_id..'&listType=11&listMode=0&mine=1&synckey=0&count=',1,true)==1 then
            local count=url:match('&count=(%d+)$')
            local allowed={['20']=true,['40']=true,['80']=true,['160']=true,['320']=true,['640']=true,
                ['1280']=true,['2560']=true,['5000']=true}
            assert(options.method=='GET' and allowed[count])
        elseif url==native..'/book/chapterInfos' then
            local body=json.decode(options.body);assert(options.method=='POST' and #body.bookIds==1 and body.bookIds[1]==input.book_id
                and body.synckeys[1]==0 and body.updateTimes[1]==0 and body.maxfreeIdx[1]==0)
        elseif url:find(native..'/book/chapterdownload?',1,true)==1 then
            assert(options.method=='GET' and url:find('bookId='..input.book_id..'&',1,true)
                and url:find('chapters=0%2C'..input.uid..'&',1,true) and url:find('stopAutoPayWhenBNE=1',1,true)
                and url:find('preview=0',1,true))
        elseif url==web..'/api/userInfo?userVid='..input.credentials.vid then assert(options.method=='GET')
        elseif url==web..'/web/book/chapterInfos' then
            local body=json.decode(options.body);assert(options.method=='POST' and #body.bookIds==1 and body.bookIds[1]==input.book_id)
            for key in pairs(body) do assert(key=='bookIds') end
        elseif url==proto.reader_url(input.book_id,input.uid) then assert(options.method=='GET')
        elseif url==web..'/web/book/chapter/e_0' or url==web..'/web/book/chapter/e_1' or url==web..'/web/book/chapter/e_3' then
            local body=json.decode(options.body)
            assert(options.method=='POST' and body.b==proto.e(input.book_id) and body.c==proto.e(input.uid)
                and body.sc==1 and body.prevChapter==false and body.st==0)
            local allowed={b=true,c=true,r=true,ct=true,ps=true,pc=true,sc=true,prevChapter=true,st=true,s=true}
            local count=0;for key in pairs(body) do assert(allowed[key]);count=count+1 end;assert(count==10)
        else error('personal_owner/unexpected_request',0) end
        if url:find(native,1,true)==1 then assert(headers.vid==input.credentials.vid and headers.accessToken==input.credentials.accessToken) end
        return previous(self,options)
    end
end
local function trace(value)
    local file=io.open(home..'/personal-flow-diagnostic','ab');if file then file:write(value..'\n');file:close() end
end
local Task=require('weread.lib.personal_mark_task');local direct_prepare,verify=Task.prepare_direct,Task.verify
Task.prepare_direct=function(...)
    local result=direct_prepare(...);trace('prepared_'..#result.rows);return result
end
Task.verify=function(rows)
    local result=verify(rows);trace('verify_'..#rows..'_'..#result);return result
end
local Dom=require('weread.lib.source_dom');local open_direct=Dom.open_direct_prepared
Dom.open_direct_prepared=function(...)
    local index,why=open_direct(...)
    if not index then trace('index_failed');return nil,why end
    local locate=index.locate_span
    index.locate_span=function(self,...)
        local value,reason=locate(self,...)
        local allowed={['source_dom/anchor_missing']=true,['source_dom/anchor_ambiguous']=true,['source_dom/walk_diverged']=true,
            ['source_dom/invalid_anchor']=true,['source_dom/invalid_span']=true,['source_dom/cancelled']=true,['source_dom/file_changed']=true}
        trace(value and 'span_ok' or allowed[reason] and 'span_'..reason:sub(12) or 'span_failed');return value,reason
    end
    local search=index.locate_span_search
    index.locate_span_search=function(self,...)
        local value,reason=search(self,...)
        local allowed={['source_dom/anchor_missing']=true,['source_dom/anchor_ambiguous']=true,['source_dom/walk_diverged']=true,
            ['source_dom/invalid_anchor']=true,['source_dom/invalid_span']=true,['source_dom/search_ambiguous']=true,
            ['source_dom/cancelled']=true,['source_dom/file_changed']=true,['source_dom/native_failure']=true}
        trace(value and 'search_ok' or allowed[reason] and 'search_'..reason:sub(12) or 'search_failed');return value,reason
    end
    return index,why
end
local Span=require('weread.lib.my_mark_span');local prepare_span=Span.prepare
local allowed_span={['my_mark_span/scope']=true,['my_mark_span/range']=true,['my_mark_span/quote']=true,
    ['my_mark_span/source']=true,['my_mark_span/boundary']=true,['my_mark_span/anchor']=true,['my_mark_span/unavailable']=true}
local function record_span_error(why)
    if allowed_span[why] then
        local file=io.open(home..'/personal-span-diagnostic','ab');if file then file:write(why..'\n');file:close() end
    end
end
Span.prepare=function(...)
    local value,why=prepare_span(...)
    if not value then record_span_error(why) end
    return value,why
end
local prepare_batch=Span.prepare_batch
Span.prepare_batch=function(...)
    local values,reasons=prepare_batch(...)
    if type(reasons)=='table' then for _,why in pairs(reasons) do record_span_error(why) end end
    return values,reasons
end
local Display=require('weread.ui.personal_marks');local attach=Display.attach;local attach_diag={called=false}
Display.attach=function(host)
    configure(host)
    local doc=host.ui and host.ui.document;local scope=host.settings:get_auth_scope()
    if doc and type(doc.findAllText)=='function' then
        local find=doc.findAllText
        doc.findAllText=function(self,...)
            local rows=find(self,...);trace('hits_'..(type(rows)=='table' and math.min(#rows,2) or 3));return rows
        end
    end
    local identity=doc and require('weread.lib.book_file_identity').read_document(doc,input.book_id)
    attach_diag={called=true,document=doc~=nil,path=doc and require('weread.lib.native_direct_path').contains(host.settings,doc.file) or false,
        identity=identity and identity.file_id~='' or false,scope=scope~=nil,scope_matches=scope and host.settings:auth_scope_matches(scope) or false,
        account=host.library_db and host.library_db:accountKey()~=nil or false,document_info=doc and doc.info~=nil or false,
        view=host.ui and host.ui.view and host.ui.view.registerViewModule~=nil or false}
    local result=attach(host);attach_diag.result=result==true;return result
end
Reader:showReader(input.path);wait(function() return Reader.instance and Reader.instance.document and Reader.instance.weread end)
local reader=Reader.instance;local host=reader.weread;local notes=host.client:json_encode(reader.annotation.annotations)
diagnostic=function()
    local s=host._personal_marks
    local total,selected=0,0
    for _,row in ipairs(s and s.snapshot and s.snapshot.updated or {}) do
        total=total+1;if s.entry and tostring(row.chapterUid)==s.entry.chapter_uid and row.type==1 then selected=selected+1 end
    end
    print('WEREAD_DIRECT_PERSONAL_STATE='..json.encode{total=total,selected=selected,attached=s~=nil,direct=s and s.direct or false,
        loading=s and s.loading or false,loaded=s and s.loaded or false,entry=s and s.entry~=nil or false,
        snapshot=s and s.snapshot~=nil or false,job=s and s.job~=nil or false,task=s and s.task~=nil or false,
        complete=s and s.complete or false,attach=attach_diag})
end
local state;wait(function() state=host._personal_marks;return state and state.complete end)
if not state.direct or #state.records==0 or #state.records>100 then diagnostic();error('personal owner empty',0) end
local rows=json.decode('[]')
for _,row in ipairs(state.records) do
    if (input.expect_thoughts and row.thoughtId) or (not input.expect_thoughts and not row.thoughtId) then
    assert(type(row.bookmarkId)=='string' and type(row.range)=='string')
    reader.rolling:onGotoXPointer(row.pos0);UI:forceRePaint()
    local text=assert(reader.document:getTextFromXPointers(row.pos0,row.pos1))
    assert(#text>0 and #text<=4096)
    local visible
    for _,item in ipairs(state.overlay.visible) do
        if item.record==row then
            local rect=item.rect;local pos={x=rect.x+math.floor(rect.w/2),y=rect.y+math.floor(rect.h/2)}
            if not state.indicator:hitTest(pos) then visible=pos;break end
        end
    end
    assert(visible,'personal owner mark not visible')
    local result={id=row.thoughtId or row.bookmarkId,range=row.range,text=text}
    if input.expect_thoughts then
        assert(Display.tap(host,{pos=visible}),'personal thought tap failed')
        if state.picker then
            local choice
            for _,item in ipairs(state.picker.item_table) do
                if item.my_note_kind=='thought' and item.my_note_id==row.thoughtId then choice=item end
            end
            assert(choice,'personal thought choice missing');choice.callback()
        end
        wait(function() return not host._my_marks_loading_source end)
        local owner=host._my_marks_owner
        assert(owner and owner.thoughts and owner.menu and owner.menu._shelf_popup,'personal thought popup missing')
        local original
        for _,item in ipairs(owner.value and owner.value.reviews or {}) do if item.reviewId==row.thoughtId then original=item end end
        assert(original and type(original.content)=='string','personal thought cache mismatch')
        local popup=owner.menu._shelf_popup;local shown=popup.text
        local tr=require('weread.lib.i18n').tr
        assert(type(shown)=='string' and (original.content=='' and shown:find(tr('No thought text was returned.'),1,true)
            or original.content~='' and shown:find(tr('Thought')..'\n'..original.content,1,true)),'personal thought content missing')
        result.content_sha256=require('weread.lib.crypto').sha256_hex(original.content)
        require('weread.ui.my_cloud_marks').cancel(host)
    end
    -- Reopen through this native chapter's menu from a different page.
    local target_page=reader.document:getCurrentPage();local pages=reader.document:getPageCount()
    assert(pages>=2,'personal note chapter is too short for navigation check')
    reader.rolling:onGotoPage(target_page==1 and 2 or 1);UI:forceRePaint()
    assert(not reader.document:isXPointerInCurrentPage(row.pos0),'personal note origin did not move')
    local tr=require('weread.lib.i18n').tr;local action
    for _,item in ipairs(host:getMainMenuItems()) do
        if item.text==tr(input.expect_thoughts and 'My cloud thoughts' or 'My cloud highlights') then action=item.callback end
    end
    assert(action,'personal note menu entry missing');action()
    wait(function() return host._my_marks_owner~=nil end)
    local note_owner=host._my_marks_owner;local target
    for _,item in ipairs(note_owner.menu.item_table) do if item.my_note_id==(row.thoughtId or row.bookmarkId) then target=item end end
    assert(target,'personal note list entry missing');target.callback();UI:forceRePaint()
    local viewer=assert(note_owner.menu._shelf_popup)
    assert(viewer.button_table:getButtonById(input.expect_thoughts and 'open_thought_quote' or 'open_highlight')):onTapSelectButton()
    wait(function() return not host._my_marks_owner end)
    assert(reader.document:isXPointerInCurrentPage(row.pos0),'personal note navigation missed its quote')
    rows[#rows+1]=result;reader.document:clearSelection()
    end
end
assert(#rows>0,'personal owner requested mark kind missing')
assert(host.client:json_encode(reader.annotation.annotations)==notes)
print('WEREAD_DIRECT_PERSONAL_OWNER='..json.encode{ok=true,offline=input.offline==true,rows=rows,navigation=true})
