-- Private one-shot direct-chapter thought lifecycle, supervised by the host.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
assert(os.getenv('WEREAD_DIRECT_OWNER_TMPFS')=='1')
package.path=assert(arg[1])..'/?.lua;'..package.path
G_reader_settings=require('luasettings'):wrap({});G_defaults=require('luadefaults'):open()
local Device=require('device');require('document/canvascontext'):init(Device)
local json=require('json');local size=assert(tonumber(io.stdin:read('*l')));assert(size>0 and size<=262144)
local input=json.decode(assert(io.stdin:read(size)));local trial=assert(input.trial);local cfg=assert(input.selection_preview)
local txt=input.plain_text==true
assert(not txt or input.book_version==0)
_G._direct_trial_error_token=trial.rpc_token
local ffi=require('ffi');local parent=tonumber(ffi.C.getpid())
local function rpc(kind,seq,extra)
    local value=extra or {};value.kind,value.seq=kind,seq
    local raw=json.encode(value);assert(#raw<16000)
    io.stdout:write('\nWEREAD_NATIVE_THOUGHT_'..trial.rpc_token..'_STEP='..raw..'\n');io.stdout:flush()
    local line=assert(io.stdin:read('*l'));assert(#line<=16384);local answer=json.decode(line)
    assert(answer.kind==kind and answer.seq==seq and answer.ok==true,'direct_selection_trial/rejected')
end
local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/'))
local scope={vid=input.credentials.vid,epoch=1}
local settings={data_dir=home,cache_dir=home,mock_endpoint=type(input.mock_endpoint)=='string' and input.mock_endpoint or nil,get=function(_,key,default)
    if key=='cookies' then return input.web_cookies end
    if key=='account' then return {user_vid=scope.vid} end
    return default
end,get_book=function() return nil end,get_auth_scope=function() return scope end,
    auth_scope_matches=function(_,value) return value==scope end}
local credentials={read=function() return input.credentials,1,nil,false end}
local Access=require('weread.lib.native_read_access');local capture=Access.capture
Access.capture=function(s,existing) return capture(s,existing or credentials) end
local client=require('weread.lib.client'):new(settings);local request=client.request
local gate;local sequence=1;local online=not trial.offline_draft
local native='https://i.weread.qq.com';local web='https://weread.qq.com'
local writes={[native..'/review/add']='create',[native..'/review/useredit']='edit',[native..'/review/delete']='delete'}
client.request=function(self,options)
    assert(online,'direct_selection_trial/offline_network')
    local url,headers=options.url,options.headers or {};assert(options.skip_cookie and options.persist_response_cookies==false and options.sensitive)
    local operation=writes[url]
    if operation then
        assert(options.method=='POST' and tonumber(ffi.C.getpid())~=parent and gate and type(options.body)=='string')
        local body=json.decode(options.body);local permit=gate:claim(operation,body)
        rpc(trial.armed and 'claim' or 'dry_body',sequence,{body=body})
        if not permit then error('direct_selection_trial/blocked',0) end
    elseif url==native..'/book/info?bookId='..input.book_id
        or url==native..'/book/bookmarklist?bookId='..input.book_id..'&synckey=0'
        or url==native..'/review/list?bookId='..input.book_id..'&listType=11&listMode=0&mine=1&synckey=0&count=20' then assert(options.method=='GET')
    elseif url==native..'/book/chapterInfos' then
        local body=json.decode(options.body);assert(options.method=='POST' and #body.bookIds==1 and body.bookIds[1]==input.book_id
            and body.synckeys[1]==0 and body.updateTimes[1]==0 and body.maxfreeIdx[1]==0)
    elseif url:find(native..'/book/chapterdownload?',1,true)==1 then
        local query=txt and 'chapters='..input.uid..'&bookType=txt&bookVersion=0&' or 'chapters=0%2C'..input.uid..'&'
        assert(options.method=='GET' and url:find('bookId='..input.book_id..'&',1,true)
            and url:find(query,1,true) and url:find('stopAutoPayWhenBNE=1',1,true))
    elseif url==web..'/api/userInfo?userVid='..scope.vid then assert(options.method=='GET')
    elseif url==web..'/web/book/chapterInfos' then
        local body=json.decode(options.body);assert(options.method=='POST' and #body.bookIds==1 and body.bookIds[1]==input.book_id)
        for key in pairs(body) do assert(key=='bookIds') end
    elseif url==require('weread.lib.protocol').reader_url(input.book_id,input.uid) then assert(options.method=='GET')
    elseif url==web..'/web/book/chapter/e_0'
        or txt and (url==web..'/web/book/chapter/t_0' or url==web..'/web/book/chapter/t_1')
        or not txt and (url==web..'/web/book/chapter/e_1' or url==web..'/web/book/chapter/e_3') then
        local body=json.decode(options.body);local p=require('weread.lib.protocol')
        assert(options.method=='POST' and body.b==p.e(input.book_id) and body.c==p.e(input.uid)
            and body.sc==1 and body.prevChapter==false and body.st==0)
        local allowed={b=true,c=true,r=true,ct=true,ps=true,pc=true,sc=true,prevChapter=true,st=true,s=true}
        local count=0;for key in pairs(body) do assert(allowed[key]);count=count+1 end;assert(count==10)
    else error('direct_selection_trial/unexpected_request',0) end
    if url:find(native,1,true)==1 then assert(headers.vid==scope.vid and headers.accessToken==input.credentials.accessToken and not headers.Cookie) end
    return request(self,options)
end
local UI=require('ui/uimanager');local socket=require('socket');local Reader=require('apps/reader/readerui')
local function wait(predicate)
    local deadline=socket.gettime()+150
    while not predicate() do assert(socket.gettime()<deadline,'direct_selection_trial/timeout');UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01) end
end
Reader:showReader(input.path);wait(function() return Reader.instance and Reader.instance.document end)
local reader=Reader.instance;local library=require('weread.lib.library_db'):new(settings)
local entry=assert(require('weread.lib.native_direct_cache').identify(settings,scope.vid,input.path,function() return true end))
assert(entry.book_id==input.book_id and entry.chapter_uid==input.uid and entry.source_sha256==input.source_sha256)
local host={ui=reader,settings=settings,client=client,library_db=library,_reader_session_gen=1,
    isNetworkConnected=function() return online end,isNetworkOnline=function() return online end,
    showBusy=function(self,label,cancel) self.busy_message=require('ui/widget/infomessage'):new{text=label,callback=cancel};UI:show(self.busy_message) end,
    closeBusy=function(self) UI:close(self.busy_message);self.busy_message=nil end,
    showInputDialog=function(_,dialog) UI:show(dialog) end,showInfo=function(self,message) self.checked_message=message end,
    detectWeReadBook=function() return nil end,showList=require('weread.ui.common').showList}
local gatepath=assert(arg[3]);gate=dofile(gatepath):new({permit_writes=trial.armed,book_id=input.book_id,
    original_ids=trial.original_ids,create_body=cfg.body,edited_text=trial.edited_text,
    source_format=txt and 'web_txt' or nil},library,client,home)
local text=txt and cfg.body.abstract or cfg.reference.markText
local matches=assert(reader.document:findAllText(text,false,0,3,false,0))
assert(#matches==1 and matches[1].start and matches[1]['end'])
local first,last=matches[1].start,matches[1]['end'];reader.rolling:onGotoXPointer(first);UI:forceRePaint()
local selected=reader.document:getTextFromXPointers(first,last)
assert(selected==text,'selected native text differs from source')
local Selection=require('weread.ui.selection_thought');assert(Selection.attach(host))
reader.highlight.selected_text={text=selected,pos0=first,pos1=last};reader.highlight:onShowHighlightMenu();UI:forceRePaint()
assert(reader.highlight.highlight_dialog.buttontable:getButtonById('weread_selection_thought')):onTapSelectButton()
wait(function() return host._selection_thought_owner~=nil or host.checked_message~=nil end)
local owner=assert(host._selection_thought_owner);wait(function() return owner.reference~=nil or host.checked_message~=nil end)
local row=assert(owner.reference)
if txt then
    assert(row.range==cfg.body.range and row.markText==cfg.body.abstract and row.chapterUid==tonumber(input.uid)
        and row.chapterIdx==input.chapter_idx and row.source.book_id==input.book_id
        and row.source.chapter_uid==input.uid and row.source.raw_sha256==input.source_sha256
        and row.source.raw_bytes==input.source_bytes,'TXT thought differs from the independent raw-source check')
else
    local expected=cfg.reference
    assert(row.range==expected.range and row.markText==expected.markText and row.bookmarkId==expected.bookmarkId
        and row.chapterUid==expected.chapterUid and row.source.book_id==expected.source.book_id
        and row.source.chapter_uid==expected.source.chapter_uid and row.source.raw_sha256==expected.source.raw_sha256
        and row.source.raw_bytes==expected.source.raw_bytes)
end
local tr=require('weread.lib.plugin_util').tr
local function tap(id)
    UI:forceRePaint();assert(owner.menu._shelf_popup.button_table:getButtonById(id)):onTapSelectButton()
end
if trial.offline_draft then
    assert(owner.offline_source and require('weread.lib.native_direct_cache').read_raw_source(input.path,entry,txt and 'txt' or nil))
    local action;for _,item in ipairs(owner.menu.item_table) do if item.text==tr('Write private thought') then action=item.callback end end
    assert(action);action();wait(function() return owner.editor and owner.editor.input or host.checked_message end);assert(owner.editor and owner.editor.input)
    owner.editor.input:setInputText(cfg.body.content);tap('save_thought_draft')
    wait(function() return not owner.editor end);assert(host.checked_message==tr('Thought draft saved on this device.'))
    Selection.cancel(host);online=true;host.checked_message=nil
    assert(Selection.open(host,{text=selected,pos0=first,pos1=last}))
    owner=assert(host._selection_thought_owner);wait(function() return owner.reference~=nil or host.checked_message~=nil end)
    assert(owner.reference and require('weread.lib.selection_reference').same(row,owner.reference))
end
local function perform(kind,content,reference)
    host.checked_message=nil
    if kind=='create' then
        local action;for _,item in ipairs(owner.menu.item_table) do if item.text==tr('Write private thought') then action=item.callback end end
        assert(action);action();wait(function() return owner.editor and owner.editor.input or host.checked_message end)
    elseif txt then
        local action
        for _,item in ipairs(owner.menu.item_table) do
            if item.my_note_id==reference.reviewId then action=item.callback;break end
        end
        assert(action,'new private thought missing from the list')()
        tap('thought_'..kind)
        if kind=='edit' then wait(function() return owner.editor and owner.editor.input or host.checked_message end) end
    else
        local editor=require('weread.ui.thought_editor')
        assert(editor.start(host,owner,kind,reference,function(h,o) return h._selection_thought_owner==o end))
    end
    if kind~='delete' then
        assert(owner.editor and owner.editor.input)
        if kind=='create' and trial.offline_draft then assert(owner.editor.input:getInputText()==content) end
        owner.editor.input:setInputText(content);tap('submit_thought')
    end
    wait(function() return not owner.editor or owner.editor.service.preview end);assert(owner.editor and owner.editor.service.preview)
    tap('confirm_thought_change');wait(function() return not owner.editor end)
end
perform('create',cfg.body.content,row)
local journal=require('weread.lib.thought_edit_store'):new(library,client)
if not trial.armed then
    assert(gate:read().phase=='blocked' and journal:read().phase=='pending')
    if trial.offline_draft then assert(#assert(journal:drafts())==1) end
    print('WEREAD_NATIVE_THOUGHT_'..trial.rpc_token..'_RESULT='..json.encode{result='PASS',steps=0,posts=0,blocked=true});return
end
assert(host.checked_message==tr('Cloud thought change verified.') and journal:read().phase=='idle')
if trial.offline_draft then assert(#assert(journal:drafts())==0) end
local cache=require('weread.lib.my_cloud_marks_store'):new(library,client,'thoughts');local target
for _,item in ipairs(assert(cache:read(input.book_id)).reviews) do
    if item.content==cfg.body.content and item.isPrivate==1 then assert(not target);target=item end
end
assert(target);rpc('verified',1,{created_id=target.reviewId});gate:advance(1,target.reviewId);sequence=2
local Marks
if txt then
    Selection.cancel(host);host.checked_message=nil
    Marks=require('weread.ui.my_cloud_marks')
    host.showMyCloudThoughts=function(self,id) return Marks.show(self,id,'thoughts') end
    assert(require('weread.ui.native_direct_navigation').open_notes(host,'thoughts'))
    wait(function() return host._my_marks_owner or host.checked_message~=nil end)
    owner=assert(host._my_marks_owner)
end
perform('edit',trial.edited_text,target)
assert(host.checked_message==tr('Cloud thought change verified.') and journal:read().phase=='idle')
for _,item in ipairs(assert(cache:read(input.book_id)).reviews) do if item.reviewId==target.reviewId then target=item end end
assert(target.content==trial.edited_text);rpc('verified',2,{created_id=target.reviewId});gate:advance(2,target.reviewId);sequence=3
perform('delete',nil,target)
assert(host.checked_message==tr('Cloud thought change verified.') and journal:read().phase=='idle')
rpc('verified',3,{created_id=target.reviewId})
if Marks then Marks.cancel(host) end
Selection.cancel(host)
print('WEREAD_NATIVE_THOUGHT_'..trial.rpc_token..'_RESULT='..json.encode{result='PASS',steps=3,posts=3,blocked=false})
