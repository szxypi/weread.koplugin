-- Real-account, read-only cross-chapter note navigation in a tmpfs profile.
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
local function wait(predicate)
    local deadline=socket.gettime()+(input.mock_endpoint and 30 or 120)
    while not predicate() do
        assert(socket.gettime()<deadline,'cross owner timeout')
        UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
    end
end
local native='https://i.weread.qq.com';local web='https://weread.qq.com';local proto=require('weread.lib.protocol')
local Display=require('weread.ui.personal_marks');local attach=Display.attach
Display.attach=function(host)
    host.settings.mock_endpoint=type(input.mock_endpoint)=='string' and input.mock_endpoint or nil
    local original_get=host.settings.get
    host.settings.get=function(self,key,default)
        if key=='cookies' then return input.web_cookies end
        return original_get(self,key,default)
    end
    host.isNetworkConnected=function() return not input.offline end
    host.isNetworkOnline=function() return not input.offline end
    local request=host.client.request
    host.client.request=function(self,options)
        assert(not input.offline and options.sensitive and options.skip_cookie and options.persist_response_cookies==false)
        local url,method=options.url,options.method;local headers=options.headers or {}
        if url==native..'/book/info?bookId='..input.book_id or url==native..'/book/bookmarklist?bookId='..input.book_id..'&synckey=0' then
            assert(method=='GET')
        elseif input.expect_thoughts and url:find(native..'/review/list?bookId='..input.book_id..'&listType=11&listMode=0&mine=1&synckey=0&count=',1,true)==1 then
            local count=url:match('&count=(%d+)$');local allowed={['20']=true,['40']=true,['80']=true,['160']=true,
                ['320']=true,['640']=true,['1280']=true,['2560']=true,['5000']=true}
            assert(method=='GET' and allowed[count])
        elseif url==native..'/book/chapterInfos' then
            local body=json.decode(options.body)
            assert(method=='POST' and #body.bookIds==1 and body.bookIds[1]==input.book_id and body.synckeys[1]==0
                and body.updateTimes[1]==0 and body.maxfreeIdx[1]==0)
        elseif url:find(native..'/book/chapterdownload?',1,true)==1 then
            assert(method=='GET' and url:find('bookId='..input.book_id..'&',1,true)
                and (url:find('chapters=0%2C'..input.uid..'&',1,true) or url:find('chapters=0%2C'..input.origin_uid..'&',1,true))
                and url:find('stopAutoPayWhenBNE=1',1,true) and url:find('preview=0',1,true))
        elseif url==web..'/api/userInfo?userVid='..input.credentials.vid then assert(method=='GET')
        elseif url==web..'/web/book/chapterInfos' then
            local body=json.decode(options.body);assert(method=='POST' and #body.bookIds==1 and body.bookIds[1]==input.book_id)
            for key in pairs(body) do assert(key=='bookIds') end
        elseif url==proto.reader_url(input.book_id,input.uid) or url==proto.reader_url(input.book_id,input.origin_uid) then assert(method=='GET')
        elseif url==web..'/web/book/chapter/e_0' or url==web..'/web/book/chapter/e_1' or url==web..'/web/book/chapter/e_3' then
            local body=json.decode(options.body)
            assert(method=='POST' and body.b==proto.e(input.book_id)
                and (body.c==proto.e(input.uid) or body.c==proto.e(input.origin_uid))
                and body.sc==1 and body.prevChapter==false and body.st==0)
            local allowed={b=true,c=true,r=true,ct=true,ps=true,pc=true,sc=true,prevChapter=true,st=true,s=true}
            local count=0;for key in pairs(body) do assert(allowed[key]);count=count+1 end;assert(count==10)
        else
            assert(method=='GET' and require('weread.lib.native_chapter_remote').allowed(url)==url
                and not headers.vid and not headers.accessToken and not headers.Cookie)
        end
        if url:find(native,1,true)==1 then assert(headers.vid==input.credentials.vid and headers.accessToken==input.credentials.accessToken) end
        return request(self,options)
    end
    local show=host.showInfo
    host.showInfo=function(self,message) host.test_failure=message;return show(self,message) end
    return attach(host)
end
Reader:showReader(input.path);wait(function() return Reader.instance and Reader.instance.document and Reader.instance.weread end)
assert(not (input.expect_thoughts and input.expect_bookmarks),'cross owner variant')
local first=Reader.instance;local host=first.weread
local label=input.expect_thoughts and 'My cloud thoughts' or input.expect_bookmarks and 'My cloud bookmarks' or 'My cloud highlights'
local tr=require('weread.lib.i18n').tr;local action
for _,item in ipairs(host:getMainMenuItems()) do if item.text==tr(label) then action=item.callback end end
assert(action,'cross owner entry');action()
wait(function() return host._my_marks_owner~=nil or host.test_failure~=nil end)
assert(not host.test_failure,'cross owner list')
local owner=host._my_marks_owner;local choice
wait(function()
    if host._my_marks_owner~=owner or host.test_failure then return true end
    for _,item in ipairs(owner.menu.item_table) do if item.my_note_id==input.expected_id then choice=item end end
    return choice~=nil
end)
assert(choice,'cross owner note missing')
local thought_hash
if input.expect_thoughts then
    for _,row in ipairs(owner.value.reviews or {}) do
        if row.reviewId==input.expected_id then thought_hash=require('weread.lib.crypto').sha256_hex(assert(row.content)) end
    end
    assert(thought_hash,'cross owner thought missing')
end
choice.callback();UI:forceRePaint();local popup=assert(owner.menu._shelf_popup)
assert(popup.button_table:getButtonById(input.expect_thoughts and 'open_thought_quote'
    or input.expect_bookmarks and 'open_bookmark' or 'open_highlight')):onTapSelectButton()
wait(function() return Reader.instance~=first or host.test_failure~=nil end)
assert(not host.test_failure,'cross owner prepare failed')
local second=Reader.instance;wait(function()
    if not second or not second.document or not second.weread then return false end
    local active=second.weread._personal_marks
    if second.weread.test_failure then return true end
    if not active or not active.complete then return false end
    for _,row in ipairs(input.expect_bookmarks and active.bookmarks or active.records) do
        if (row.thoughtId or row.bookmarkId)==input.expected_id and second.document:isXPointerInCurrentPage(row.pos0) then return true end
    end
    return false
end)
assert(not second.weread.test_failure and second.document.file~=input.path,'cross owner target failed')
local record
for _,row in ipairs(input.expect_bookmarks and second.weread._personal_marks.bookmarks or second.weread._personal_marks.records) do
    if (row.thoughtId or row.bookmarkId)==input.expected_id then record=row end
end
assert(record and second.document:isXPointerInCurrentPage(record.pos0))
local text=input.expect_bookmarks and assert(input.expected_preview) or assert(second.document:getTextFromXPointers(record.pos0,record.pos1))
local result={id=input.expected_id,range=record.range,text=text}
if input.expect_thoughts then result.content_sha256=thought_hash end
local indicator
if input.expect_bookmarks then
    local target_host=second.weread;local state=target_host._personal_marks
    local annotations=target_host.client:json_encode(second.annotation.annotations)
    UI:forceRePaint()
    local corner=assert(state.indicator.rect,'bookmark corner missing');local visible=false
    for _,item in ipairs(state.indicator.visible) do if item.bookmarkId==input.expected_id then visible=true end end
    assert(visible,'bookmark corner not visible')
    local selected;local open=target_host.showMyCloudBookmarks
    target_host.showMyCloudBookmarks=function(current,...)
        local opened=open(current,...);local list=current._my_marks_owner
        for _,item in ipairs(list and list.menu.item_table or {}) do
            local callback,id=item.callback,item.my_note_id
            if callback and id then item.callback=function(...) selected=id;return callback(...) end end
        end
        return opened
    end
    local position={x=corner.x+1,y=corner.y+1}
    assert(Display.tap(target_host,{pos=position},true),'bookmark corner tap failed')
    if state.picker then
        local wanted
        for _,item in ipairs(state.picker.item_table) do if item.my_note_id==input.expected_id then wanted=item end end
        assert(wanted,'bookmark corner choice missing');wanted.callback()
    end
    local bookmark_owner=assert(target_host._my_marks_owner)
    local viewer=assert(bookmark_owner.menu._shelf_popup,'bookmark corner popup missing')
    assert(bookmark_owner.bookmarks and selected==input.expected_id and viewer.button_table:getButtonById('open_bookmark'),
        'bookmark corner opened a different record')
    for _,row in ipairs(bookmark_owner.value.updated or {}) do
        if row.bookmarkId==input.expected_id and row.markText and row.markText~='' then
            assert(viewer.text:find(row.markText,1,true),'bookmark corner preview mismatch')
        end
    end
    require('weread.ui.my_cloud_marks').cancel(target_host)
    assert(target_host.client:json_encode(second.annotation.annotations)==annotations,'bookmark tap changed local annotations')
    indicator=true
end
print('WEREAD_DIRECT_PERSONAL_OWNER='..json.encode{ok=true,offline=input.offline==true,rows={result},navigation=true,indicator=indicator})
