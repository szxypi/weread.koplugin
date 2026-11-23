-- Read-only owner position probe. Credentials and captured text stay in pipes.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
assert(os.getenv('WEREAD_DIRECT_OWNER_TMPFS')=='1')
package.path=assert(arg[1])..'/?.lua;'..package.path
G_reader_settings=require('luasettings'):wrap({});G_defaults=require('luadefaults'):open()
local Device=require('device');require('document/canvascontext'):init(Device)
local json=require('json');local input=json.decode(assert(io.stdin:read('*a')))
local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/'))
local scope={vid=input.credentials.vid,epoch=1}
local settings={data_dir=home,cache_dir=home,mock_endpoint=type(input.mock_endpoint)=='string' and input.mock_endpoint or nil,get=function(_,key,default)
    if key=='cookies' then return input.web_cookies end
    if key=='account' then return {user_vid=scope.vid} end
    return default
end,get_book=function() return nil end,get_auth_scope=function() return scope end,
    auth_scope_matches=function(_,value) return value==scope end}
local store={read=function() return input.credentials,1,nil,false end}
local Access=require('weread.lib.native_read_access');local capture=Access.capture
Access.capture=function(s,existing) return capture(s,existing or store) end
local client=require('weread.lib.client'):new(settings);local request=client.request;local online=true
client.request=function(self,options)
    assert(online,'offline draft attempted a network request')
    local url,headers=options.url,options.headers or {};local native='https://i.weread.qq.com';local web='https://weread.qq.com'
    assert(options.skip_cookie and options.persist_response_cookies==false and options.sensitive)
    if url==native..'/book/info?bookId='..input.book_id then assert(options.method=='GET')
    elseif (input.upload_preview or input.upload_dry_run) and url==native..'/shelf/sync' then assert(options.method=='GET')
    elseif input.upload_dry_run and url==native..'/feature?synckey=0' then assert(options.method=='GET')
    elseif input.upload_dry_run and url==native..'/book/read' then
        assert(options.method=='POST' and options.sensitive and options.skip_cookie and options.persist_response_cookies==false)
        local body=json.decode(options.body)
        assert(body.bookId==input.book_id and body.chapterUid==tonumber(input.uid) and body.readingTime==0
            and type(body.summary)=='string' and #body.summary>0)
        error('owner_dry_run/blocked',0) -- Never forward a progress write to the network.
    elseif input.annotation_preview and (url==native..'/book/bookmarklist?bookId='..input.book_id..'&synckey=0'
        or url==native..'/review/list?bookId='..input.book_id..'&listType=11&listMode=0&mine=1&synckey=0&count=20') then
        assert(options.method=='GET')
    elseif input.cloud and url==native..'/book/getProgress?bookId='..input.book_id then assert(options.method=='GET')
    elseif url==native..'/book/chapterInfos' then
        local body=json.decode(options.body);assert(options.method=='POST' and #body.bookIds==1 and body.bookIds[1]==input.book_id
            and body.synckeys[1]==0 and body.updateTimes[1]==0 and body.maxfreeIdx[1]==0)
    elseif url:find(native..'/book/chapterdownload?',1,true)==1 then
        assert(options.method=='GET' and url:find('bookId='..input.book_id..'&',1,true)
            and (url:find('chapters=0%2C'..input.uid..'&',1,true)
                or input.cloud_cross and url:find('chapters=0%2C'..input.target_uid..'&',1,true))
            and url:find('stopAutoPayWhenBNE=1',1,true)
            and url:find('preview=0',1,true))
    elseif url==web..'/api/userInfo?userVid='..scope.vid then assert(options.method=='GET')
    elseif url==web..'/web/book/chapterInfos' then
        local body=json.decode(options.body);assert(options.method=='POST' and #body.bookIds==1 and body.bookIds[1]==input.book_id)
        for key in pairs(body) do assert(key=='bookIds') end
    elseif (input.upload_preview or input.upload_dry_run) and url:find(web..'/web/book/getProgress?',1,true)==1 then
        assert(options.method=='GET' and url:find('bookId='..input.book_id..'&',1,true))
    elseif url==require('weread.lib.protocol').reader_url(input.book_id,input.uid)
        or input.cloud_cross and url==require('weread.lib.protocol').reader_url(input.book_id,input.target_uid) then assert(options.method=='GET')
    elseif url==web..'/web/book/chapter/e_0' or url==web..'/web/book/chapter/e_1' or url==web..'/web/book/chapter/e_3' then
        local body=json.decode(options.body);local p=require('weread.lib.protocol')
        assert(options.method=='POST' and body.b==p.e(input.book_id)
            and (body.c==p.e(input.uid) or input.cloud_cross and body.c==p.e(input.target_uid))
            and body.sc==1 and body.prevChapter==false and body.st==0)
        local allowed={b=true,c=true,r=true,ct=true,ps=true,pc=true,sc=true,prevChapter=true,st=true,s=true}
        local count=0;for key in pairs(body) do assert(allowed[key]);count=count+1 end;assert(count==10)
    else error('unexpected request') end
    if url:find(native,1,true)==1 then assert(headers.vid==scope.vid and headers.accessToken==input.credentials.accessToken) end
    return request(self,options)
end
local UI=require('ui/uimanager');local socket=require('socket');local Reader=require('apps/reader/readerui')
local function wait(predicate)
    local deadline=socket.gettime()+150
    while not predicate() do assert(socket.gettime()<deadline,'timeout');UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01) end
end
Reader:showReader(input.path);wait(function() return Reader.instance and Reader.instance.document end)
local reader=Reader.instance
if input.start_page and input.start_page>1 then
    assert(reader.rolling and reader.document:getPageCount()>=input.start_page)
    reader.rolling:onGotoPage(input.start_page);UI:forceRePaint()
end
local entry=assert(require('weread.lib.native_direct_cache').identify(settings,scope.vid,input.path,function() return true end))
assert(entry.book_id==input.book_id and entry.chapter_uid==input.uid and entry.file_id)
local library=(input.upload_dry_run or input.selection) and require('weread.lib.library_db'):new(settings) or {accountKey=function() return 'owner' end}
local host={ui=reader,settings=settings,client=client,library_db=library,
    _reader_session_gen=1,isNetworkConnected=function() return online end,isNetworkOnline=function() return online end,
    showBusy=function(self,label,cancel)
        self.busy_message=require('ui/widget/infomessage'):new{text=label,callback=cancel};UI:show(self.busy_message)
    end,closeBusy=function(self) UI:close(self.busy_message);self.busy_message=nil end,
    showInfo=function(self,message) self.checked_message=message end,showInputDialog=require('weread.ui.common').showInputDialog,
    detectWeReadBook=function() return nil end,
    showList=require('weread.ui.common').showList}
if input.selection then
    assert(type(input.selection_text)=='string' and #input.selection_text>0 and #input.selection_text<=4096)
    local matches=assert(reader.document:findAllText(input.selection_text,false,0,10,false,0))
    assert(#matches>0 and matches[1].start and matches[1]['end'])
    local first,last=matches[1].start,matches[1]['end']
    reader.rolling:onGotoXPointer(first);UI:forceRePaint()
    local chosen=assert(reader.document:getTextFromXPointers(first,last))
    assert(chosen==input.selection_text)
    local selection=require('weread.ui.selection_thought');assert(selection.attach(host))
    reader.highlight.selected_text={text=chosen,pos0=first,pos1=last}
    reader.highlight:onShowHighlightMenu();UI:forceRePaint()
    assert(reader.highlight.highlight_dialog.buttontable:getButtonById('weread_selection_thought')):onTapSelectButton()
    wait(function() return host._selection_thought_owner~=nil or host.checked_message~=nil end)
    local owner=assert(host._selection_thought_owner)
    wait(function() return owner.reference~=nil or host.checked_message~=nil end)
    if not owner.reference then
        local allowed={invalid=true,unavailable=true,source_changed=true,file_changed=true,session_changed=true,
            auth_expired=true,web_expired=true,rate_limited=true,
            ['selection_reference/selection']=true,['selection_reference/start_unmatched']=true,['selection_reference/end_unmatched']=true,
            ['selection_reference/quote_boundary']=true,['selection_reference/quote_ambiguous']=true,['selection_reference/source_changed']=true,
            ['selection_reference/source']=true,['selection_reference/catalog']=true,['selection_reference/reference']=true,
            ['selection_reference/unavailable']=true}
        print('WEREAD_DIRECT_OWNER_POSITION='..json.encode{ok=false,reason=allowed[owner.error] and owner.error or 'unavailable'});return
    end
    local reference=owner.reference
    assert(require('weread.lib.selection_reference').valid(reference,input.book_id) and reference.markText==chosen)
    local report={ok=true,selection=chosen,quote=reference.markText,range=reference.range}
    if input.annotation_preview then
        local worker=require('weread.lib.memory_worker'):new{scheduler=UI,codec=client,max_bytes=65536,timeout=140}
        local result
        assert(worker:start(function()
            local selected=assert(Access.capture(settings))
            local base={book_id=input.book_id,operation='create',reference=reference,source_file=input.path}
            local mark=require('weread.lib.mark_edit_task').preview(client,settings,selected,base)
            base.content='Private preflight only'
            local thought=require('weread.lib.thought_edit_task').preview(client,settings,selected,base)
            assert(mark.body.bookId==input.book_id and mark.body.range==reference.range and mark.body.markText==chosen)
            assert(thought.body.bookId==input.book_id and thought.body.range==reference.range
                and thought.body.abstract==chosen and thought.body.isPrivate==1 and thought.body.content==base.content)
            return {mark_preview=true,thought_preview=true}
        end,function(value) result=value end))
        wait(function() return result~=nil end)
        assert(result.mark_preview==true and result.thought_preview==true)
        report.mark_preview=true;report.thought_preview=true
    end
    if input.offline_draft then
        -- Force the offline path to use the downloaded native source, even
        -- though the online comparison above populated a verified cache.
        local cache=require('weread.lib.native_direct_cache')
        assert(cache.read_raw_source(input.path,entry))
        local db=assert(library:open());db:exec('DELETE FROM native_direct_mark_source');db:close()
        selection.cancel(host);online=false;host.checked_message=nil
        assert(selection.open(host,{text=chosen,pos0=first,pos1=last}))
        local offline=assert(host._selection_thought_owner)
        wait(function() return offline.reference~=nil or host.checked_message~=nil end)
        assert(offline.offline_source and offline.reference and require('weread.lib.selection_reference').same(reference,offline.reference))
        local tr=require('weread.lib.plugin_util').tr;local write,drafts
        for _,item in ipairs(offline.menu.item_table) do
            if item.text==tr('Write private thought') then write=item.callback end
            if item.text==tr('Local thought drafts') then drafts=item.callback end
            assert(item.text~=tr('Save highlight'))
        end
        assert(write and drafts);write();assert(offline.editor and offline.editor.input)
        offline.editor.input:setInputText('Synthetic offline draft')
        UI:forceRePaint();assert(offline.menu._shelf_popup.button_table:getButtonById('save_thought_draft')):onTapSelectButton()
        wait(function() return not offline.editor end);assert(host.checked_message==tr('Thought draft saved on this device.'))
        host.checked_message=nil;drafts();assert(offline.editor and offline.editor.dialog.item_table[1])
        offline.editor.dialog.item_table[1].callback();UI:forceRePaint()
        assert(offline.menu._shelf_popup.button_table:getButtonById('resume_thought_draft')):onTapSelectButton()
        wait(function() return offline.editor and offline.editor.input end)
        assert(offline.editor.input:getInputText()=='Synthetic offline draft')
        require('weread.ui.thought_editor').cancel(host,offline);selection.cancel(host)
        report.offline_draft=true
    end
    print('WEREAD_DIRECT_OWNER_POSITION='..json.encode(report))
    selection.cancel(host);return
end
local worker=require('weread.lib.memory_worker'):new{scheduler=UI,codec=client,max_bytes=65536,timeout=140}
local anchor,point,reason,comparison,target_anchor,destination_host
if input.cloud_cross then
    host.openFile=function(self,path,callback)
        self._reader_session_gen=self._reader_session_gen+1
        reader:switchDocument(path,nil,function(next_reader)
            destination_host={ui=next_reader,settings=settings,client=client,library_db=host.library_db,
                _reader_session_gen=1,isNetworkConnected=function() return true end,
                showBusy=host.showBusy,closeBusy=host.closeBusy,showInfo=host.showInfo}
            local destination_worker=require('weread.lib.memory_worker'):new{scheduler=UI,codec=client,max_bytes=65536,timeout=140}
            destination_host._native_direct_cloud_open_worker={cancel=function() destination_worker:cancel() end,
                start=function(_,task,done)
                    return destination_worker:start(task,function(value)
                        if type(value)=='table' and type(value.value)=='table' then target_anchor=value.value.anchor end
                        done(value)
                    end)
                end}
            next_reader.weread=destination_host
            return callback(next_reader)
        end)
    end
end
host._native_direct_position_worker={cancel=function() worker:cancel() end,start=function(_,task,callback)
    local ctx=assert(host._native_direct_position);anchor={text=ctx.input.text,point_offset=ctx.input.point_offset}
    if input.upload_preview then
        task=function()
            local value,why=require('weread.lib.native_direct_upload_preview').prepare(client,settings,entry,
                ctx.file,ctx.input,ctx.native,ctx.web,function() return true end)
            if value then
                assert(value.dispatch_authorized==false and value.desired.summary and value.desired.chapter_offset==value.position.chapter_offset)
                return {position=value.position}
            end
            return {error=why}
        end
    end
    return worker:start(task,function(value)
        point=value.position or value.comparison and value.comparison.position or value.preview and value.preview.position or point
        comparison=comparison or value.comparison;reason=value.error;callback(value)
    end)
end}
assert(require('weread.ui.native_direct_position').start(host,entry,{cloud=input.cloud==true and not input.upload_preview and not input.upload_dry_run,
    upload=input.upload_dry_run==true}))
wait(function() return host.checked_message~=nil or not host._native_direct_position
    or host._native_direct_position.confirm~=nil end)
local tr=require('weread.lib.plugin_util').tr
local opened,denied,cancelled=false,false,false
if input.upload_dry_run then
    assert(host._native_direct_position and host._native_direct_position.confirm,'upload confirmation missing')
    host._native_direct_position.confirm.ok_callback()
    wait(function() return host.checked_message~=nil or not host._native_direct_position end)
    assert(host.checked_message==tr('The sync result could not be confirmed. Choose sync again to review it.'))
    local pending=assert(require('weread.lib.native_position_store'):new(library,client):read())
    assert(pending.phase=='pending' and pending.metadata.basis=='filtered_xhtml_utf16')
end
if input.cloud and not input.upload_preview and not input.upload_dry_run and host._native_direct_position and host._native_direct_position.confirm then
    assert(comparison and (comparison.relation=='different' or comparison.relation=='other_chapter'))
    if comparison.relation=='other_chapter' and not input.cloud_denied and not input.cloud_cross then
        host._native_direct_position.confirm.cancel_callback();cancelled=not host._native_direct_position
    else
        assert(comparison.relation=='other_chapter' or comparison.anchor)
        host._native_direct_position.confirm.ok_callback()
        if input.cloud_cross then
            wait(function() return host.checked_message~=nil or destination_host and destination_host.checked_message~=nil end)
            opened=destination_host and destination_host.checked_message==tr('Opened the cloud reading position in this chapter.') or false
        else
            wait(function() return host.checked_message~=nil or not host._native_direct_position end)
            opened=host.checked_message==tr('Opened the cloud reading position in this chapter.')
        end
        denied=input.cloud_denied and host.checked_message==tr('The cloud chapter is not available to this account.') or false
    end
end
local expected=input.cloud and not input.upload_preview and not input.upload_dry_run and comparison and ({same='The current page matches the cloud reading position.',
    no_chapter='There is no cloud reading position yet. Your current page is kept.',
    other_chapter='The cloud reading position is in another chapter. Your current page is kept.',
    target_unavailable='The cloud position could not be located in this chapter. Your current page is kept.',
    different='Opened the cloud reading position in this chapter.'})[comparison.relation]
    or 'The local reading position was checked against the chapter source.'
if not input.upload_dry_run and not cancelled and not denied and not opened and host.checked_message~=tr(expected) then
    local allowed={invalid=true,unavailable=true,source_changed=true,anchor_unavailable=true,source_unsupported=true,
        file_changed=true,session_changed=true,auth_expired=true,web_expired=true,rate_limited=true,cloud_changed=true,
        baseline_unavailable=true,summary_unavailable=true}
    print('WEREAD_DIRECT_OWNER_POSITION='..json.encode{ok=false,reason=allowed[reason] and reason or 'unavailable'});return
end
assert(point and point.upload_verified==false and point.source_current and point.basis=='filtered_xhtml_utf16')
local report={ok=true,text=anchor.text,point_offset=anchor.point_offset,offset=point.chapter_offset}
if input.upload_dry_run then report.upload_dry_run=true
elseif input.upload_preview then report.upload_preview=true
elseif input.cloud then
    assert(comparison and comparison.relation);report.relation=comparison.relation;report.opened=opened
    if input.cloud_denied then report.denied=denied end
    if opened then
        local target=input.cloud_cross and target_anchor or comparison.anchor;assert(target)
        report.target={ok=true,text=target.text,point_offset=target.point_offset,offset=target.co}
    end
end
print('WEREAD_DIRECT_OWNER_POSITION='..json.encode(report))
