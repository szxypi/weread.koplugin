-- Read-only owner position probe. Credentials and captured text stay in pipes.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
assert(os.getenv('WEREAD_DIRECT_OWNER_TMPFS')=='1')
package.path=assert(arg[1])..'/?.lua;'..package.path
G_reader_settings=require('luasettings'):wrap({});G_defaults=require('luadefaults'):open()
local Device=require('device');require('document/canvascontext'):init(Device)
local json=require('json');local input=json.decode(assert(io.stdin:read('*a')))
local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/'))
local scope={vid=input.credentials.vid,epoch=1}
local settings={data_dir=home,cache_dir=home,get=function(_,key,default)
    if key=='cookies' then return input.web_cookies end
    if key=='account' then return {user_vid=scope.vid} end
    return default
end,get_book=function() return nil end,get_auth_scope=function() return scope end,
    auth_scope_matches=function(_,value) return value==scope end}
local store={read=function() return input.credentials,1,nil,false end}
local Access=require('weread.lib.native_read_access');local capture=Access.capture
Access.capture=function(s,existing) return capture(s,existing or store) end
local client=require('weread.lib.client'):new(settings);local request=client.request
client.request=function(self,options)
    local url,headers=options.url,options.headers or {};local native='https://i.weread.qq.com';local web='https://weread.qq.com'
    assert(options.skip_cookie and options.persist_response_cookies==false and options.sensitive)
    if url==native..'/book/info?bookId='..input.book_id then assert(options.method=='GET')
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
local host={ui=reader,settings=settings,client=client,library_db={accountKey=function() return 'owner' end},
    _reader_session_gen=1,isNetworkConnected=function() return true end,
    showBusy=function(self,label,cancel)
        self.busy_message=require('ui/widget/infomessage'):new{text=label,callback=cancel};UI:show(self.busy_message)
    end,closeBusy=function(self) UI:close(self.busy_message);self.busy_message=nil end,
    showInfo=function(self,message) self.checked_message=message end}
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
    return worker:start(task,function(value)
        point=value.position or value.comparison and value.comparison.position or point
        comparison=comparison or value.comparison;reason=value.error;callback(value)
    end)
end}
assert(require('weread.ui.native_direct_position').start(host,entry,{cloud=input.cloud==true}))
wait(function() return host.checked_message~=nil or not host._native_direct_position
    or host._native_direct_position.confirm~=nil end)
local tr=require('weread.lib.plugin_util').tr
local opened,denied,cancelled=false,false,false
if input.cloud and host._native_direct_position and host._native_direct_position.confirm then
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
local expected=input.cloud and comparison and ({same='The current page matches the cloud reading position.',
    no_chapter='There is no cloud reading position yet. Your current page is kept.',
    other_chapter='The cloud reading position is in another chapter. Your current page is kept.',
    target_unavailable='The cloud position could not be located in this chapter. Your current page is kept.',
    different='Opened the cloud reading position in this chapter.'})[comparison.relation]
    or 'The local reading position was checked against the chapter source. Cloud sync is not enabled yet.'
if not cancelled and not denied and not opened and host.checked_message~=tr(expected) then
    local allowed={invalid=true,unavailable=true,source_changed=true,anchor_unavailable=true,source_unsupported=true,
        file_changed=true,session_changed=true,auth_expired=true,web_expired=true,rate_limited=true,cloud_changed=true}
    print('WEREAD_DIRECT_OWNER_POSITION='..json.encode{ok=false,reason=allowed[reason] and reason or 'unavailable'});return
end
assert(point and point.upload_verified==false and point.source_current and point.basis=='filtered_xhtml_utf16')
local report={ok=true,text=anchor.text,point_offset=anchor.point_offset,offset=point.chapter_offset}
if input.cloud then
    assert(comparison and comparison.relation);report.relation=comparison.relation;report.opened=opened
    if input.cloud_denied then report.denied=denied end
    if opened then
        local target=input.cloud_cross and target_anchor or comparison.anchor;assert(target)
        report.target={ok=true,text=target.text,point_offset=target.point_offset,offset=target.co}
    end
end
print('WEREAD_DIRECT_OWNER_POSITION='..json.encode(report))
