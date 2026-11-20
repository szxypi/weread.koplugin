-- Native reader menu and background-job handoff, entirely synthetic.
require('setupkoenv')
local home=assert(os.getenv('KO_HOME'))
local integrated=os.getenv('WEREAD_GENERATION_INTEGRATED')=='1'
local cancel_after=os.getenv('WEREAD_GENERATION_CANCEL')=='1'
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
require('gettext').changeLang('zh_CN')
local Device=require('device');require('document/canvascontext'):init(Device)
local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
for _,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
assert(#Loader.enabled_plugins==1)
package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
local UI=require('ui/uimanager')
local Reader=require('apps/reader/readerui')
local Content=require('weread.lib.content')
local Source=require('weread.lib.position_source')
local Identity=require('weread.lib.book_file_identity')
local settings=require('weread.lib.settings'):new()
local tr=require('weread.lib.i18n').tr
local chapter={chapterUid=1,chapterIdx=1,title='Chapter One',wordCount=1800}
local raw='<html><body><p>'..string.rep('Synthetic native reading paragraph. ',12)..'</p></body></html>'
local book={book_id='900001',bookVersion=7,title='合成译文验证',author='Synthetic',chapters={chapter}}
local source=assert(Source.capture(book,chapter,raw,'web_xhtml'))
local path=Content.save_chapter_epub(settings,book,chapter,raw,nil,nil,Identity.capture(book),source)
book.cached_chapters={['1']=path};settings:set('books',{['900001']=book})
settings:set('cookies',{wr_vid='900000',wr_skey='synthetic-cookie'});settings:set('account',{user_vid='900000'})
settings:set('sync',{pull_on_open=false,upload_on_close=false});settings:set('read_report',{enabled=false})
local cache=settings:get('cache');cache.auto_prefetch_next_chapter=false;cache.show_annotations=false;cache.download_book_images=false
settings:set('cache',cache);settings:flush()
local function bytes() local f=assert(io.open(path,'rb'));local value=assert(f:read('*a'));f:close();return value end
local original=bytes()
local socket,ffi=require('socket'),require('ffi');local parent=tonumber(ffi.C.getpid())
UI:setRunForeverMode();UI:setInputTimeout(0)
local function pump(check,seconds)
    local deadline=socket.gettime()+(seconds or 45)
    repeat UI:handleInput();if check() then return end;assert(socket.gettime()<deadline,'translation request UI deadline');socket.sleep(.01) until false
end
local reader=Reader:new{dimen=Device.screen:getSize(),document=require('document/documentregistry'):openDocument(path)}
UI:show(reader);local plugin=assert(reader.weread)
while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=reader do UI:close(UI:getTopmostVisibleWidget()) end
local native_read=reader.document.getDocumentFileContent
reader.document.getDocumentFileContent=function(self,name)
    assert(tonumber(ffi.C.getpid())==parent,'background job used inherited reader DOM')
    return native_read(self,name)
end
plugin.isNetworkOnline=function() return true end
local access=require('weread.lib.native_read_access')
local web=require('weread.lib.read_access')
local scope=plugin.settings:get_auth_scope()
local credentials={vid='900000',accessToken='synthetic-access',refreshToken='synthetic-refresh',deviceId='eink3346912251234567890123456789'}
local selected={scope=scope,credentials=credentials,fingerprint=string.rep('a',64)}
local web_selection={web={kind='web',cookies={wr_vid='900000',wr_skey='synthetic-cookie'}},revision='synthetic'}
access.capture=function() return selected end
web.capture=function() return web_selection end
local Fetch=require('weread.ui.translation_fetch')
local handoffs=0
if not integrated then Fetch.start=function() handoffs=handoffs+1;return true end end
local mode='available'
if integrated then
    local Task=require('weread.lib.translation_generation_task')
    local run=Task.run
    Task.run=function(client,child_settings,child_selected,child_web,input,journal,options)
        local generated=false;local mode_calls,generation_calls=0,0
        local trace={steps={},requests={}}
        Content.ensure_reader_state=function() end
        Content.fetch_catalog=function() return {{chapterUid=1,title='Chapter One',wordCount=1800}},7 end
        Content.fetch_chapter_xhtml=function(_client,_settings,target,target_chapter)
            local body=generated and raw:gsub('</p>','</p><p class="wr-translation">合成译文</p>') or raw
            return body,assert(Source.capture(target,target_chapter,body,'web_xhtml'))
        end
        client.request=function(self,request)
            local url=request.url;trace.requests[#trace.requests+1]=url;local response
            if url=='https://i.weread.qq.com/pay/memberCardSummary?pf=wechat_wx-2001-android-100-weread' then response={isPaying=true}
            elseif url=='https://i.weread.qq.com/book/info?bookId=900001' then response={bookId='900001',format='epub',version=7}
            elseif url=='https://i.weread.qq.com/book/chapterInfos' then
                response={data={{bookId='900001',updated={{chapterUid=1,title='Chapter One',wordCount=1800,price=0,translateVersion=generated and 1 or 0}}}}}
            elseif url=='https://i.weread.qq.com/book/getProgress?bookId=900001' or url:match('^https://weread%.qq%.com/web/book/getProgress%?') then
                response={bookId='900001',book={bookId='900001',title='Synthetic',readingTime=0},canFreeRead=1,timestamp=100}
            elseif url=='https://i.weread.qq.com/shelf/sync' or url=='https://weread.qq.com/web/shelf/sync' then
                response={books={{bookId='900001',isTop=0,secret=0,finishReading=0}},archive=self:json_decode('[]')}
            elseif url:match('^https://i%.weread%.qq%.com/trans/pdfepub%?') then
                mode_calls=mode_calls+1;local f=assert(io.open(home..'/synthetic-mode-count','ab'));f:write('1');f:close();response={succ=1}
            elseif url=='https://i.weread.qq.com/en/bookread' then
                generation_calls=generation_calls+1
                local f=assert(io.open(home..'/synthetic-generation-count','ab'));f:write('1');f:close()
                if cancel_after then socket.sleep(10) end
                local body=self:json_decode(request.body)
                assert(body.bookId=='900001' and body.freeTrial==0 and body.read[1].uid==1 and self:json_encode(body.reference.texts)=='[]')
                generated=true;response={stopPoll=1,curStatus={{uid=1,translateVersion=1}}}
            else error('unexpected synthetic endpoint') end
            assert(request.sink(self:json_encode(response)));return nil,200,{}
        end
        trace.current=options.is_current();trace.native=access.matches(child_settings,child_selected);trace.web=web.matches(child_settings,child_web)
        local Authorization=require('weread.lib.native_authorization')
        local original_request=Authorization._request
        Authorization._request=function(...)
            local ok,value=pcall(original_request,...)
            trace.steps[#trace.steps+1]='auth:'..(ok and 'ok' or tostring(value))
            if not ok then error(value,0) end;return value
        end
        local baseline=require('weread.lib.translation_generation_baseline')
        local original_baseline=baseline.read
        baseline.read=function(...)
            local ok,value,reason=pcall(original_baseline,...)
            trace.steps[#trace.steps+1]='baseline:'..(ok and (value and 'ok' or tostring(reason)) or 'error')
            if not ok then error(value) end;return value,reason
        end
        local preflight=require('weread.lib.translation_generation_source')
        local original_inspect=preflight.inspect
        preflight.inspect=function(...)
            local ok,value,reason=pcall(original_inspect,...)
            trace.steps[#trace.steps+1]='source:'..(ok and (value and value.kind or tostring(reason)) or 'error')
            if not ok then error(value) end;return value,reason
        end
        for _,name in ipairs({'lookup','prepare','discard_stale_prepared','rebase_confirmed'}) do
            local method=journal[name]
            journal[name]=function(...)
                local ok,value=pcall(method,...)
                trace.steps[#trace.steps+1]='journal_'..name..':'..(ok and (value and 'ok' or 'nil') or 'error')
                if not ok then error(value) end;return value
            end
        end
        local result=run(client,child_settings,child_selected,child_web,input,journal,options)
        result.debug_mode_calls,result.debug_generation_calls,result.debug_trace=mode_calls,generation_calls,trace
        return result
    end
else
    package.loaded['weread.lib.translation_generation_task']={run=function(_client,_settings,_selected,_web,input,_journal,options)
        assert(input.book_id=='900001' and input.chapter_uid=='1' and options.is_current())
        if mode=='slow' then socket.sleep(2) end
        return {kind=mode}
    end}
end
local notices={};plugin.showInfo=function(_self,message) notices[#notices+1]=message end
local worker_result
if integrated then
    local worker=require('weread.lib.memory_worker'):new{scheduler=UI,codec=plugin.client,timeout=600}
    local wrapper={}
    function wrapper:start(task,callback)
        local started=worker:start(task,function(value) worker_result=value;self.job=nil;callback(value) end)
        self.job=worker.job;return started
    end
    function wrapper:cancel() self.job=nil;worker:cancel() end
    plugin.translation_generation_worker=wrapper
end
local function start()
    plugin:showReadingLanguage();pump(function() return not plugin.translation_job end)
    local menu=assert(plugin._translation_menu);local entry
    for _,item in ipairs(menu.item_table) do if item.text==tr('Request official translation for this chapter (experimental)') then entry=item end end
    assert(entry,'request entry missing');menu:onMenuSelect(entry)
    assert(plugin.translation_generation_job and plugin.translation_generation_worker.job,'request did not start a background worker')
end
start();local heartbeat=false;UI:scheduleIn(.05,function() heartbeat=true end)
if integrated and cancel_after then
    local function count(name) local f=io.open(home..'/'..name,'rb');if not f then return '' end;local value=f:read('*a');f:close();return value end
    pump(function() return #count('synthetic-generation-count')==1 end,45)
    require('weread.ui.translation_generation').cancel(plugin)
    assert(not plugin.translation_generation_job and not plugin.busy_message,'cancel did not stop in-flight request')
    start();pump(function() return not plugin.translation_generation_job end,45)
    assert(notices[#notices]==tr('The translation request could not be confirmed. Check for an existing translation later; the request will not be sent again automatically.'),
        'canceled request did not remain unconfirmed')
    assert(#count('synthetic-mode-count')==1 and #count('synthetic-generation-count')==1 and bytes()==original,
        'canceled request was sent again or original changed')
    reader:onClose(false);print('PASS: native translation request menu cancel after dispatch without replay');return
end
if integrated then
    pump(function()
        if plugin._translation_fetch_result and heartbeat then return true end
        if not plugin.translation_generation_job and not plugin.translation_fetch_job then
            error('integrated task stopped: '..tostring(notices[#notices] or 'no notice')..' result='..require('json').encode(worker_result or {}))
        end
    end,90)
    assert(worker_result and worker_result.debug_mode_calls==1 and worker_result.debug_generation_calls==1,'unexpected write counts')
    local record=assert(reader.doc_settings:readSetting('weread_translation_copies')['1'])
    assert(record.path~=path and record.blocks>0 and bytes()==original,'integrated flow did not retain original and save a translated copy')
    local dialog=plugin._translation_fetch_result;dialog.ok_callback()
    pump(function() return Reader.instance and Reader.instance~=reader and Reader.instance.document.file==record.path end)
    assert(Reader.instance.weread._translation_mode=='bilingual','translated copy did not open bilingually')
    Reader.instance:onClose(false)
    print('PASS: native translation request menu integrated generation and translated copy');return
end
pump(function() return not plugin.translation_generation_job and heartbeat end)
assert(handoffs==1 and bytes()==original,'available translation did not hand off or changed source')
mode='pending';start();pump(function() return not plugin.translation_generation_job end)
assert(notices[#notices]==tr('The official translation is still being prepared. Try downloading the existing translation later.'),'pending status missing')
mode='unconfirmed';start();pump(function() return not plugin.translation_generation_job end)
assert(notices[#notices]==tr('The translation request could not be confirmed. Check for an existing translation later; the request will not be sent again automatically.'),
    'unknown result was not explained')
mode='slow';start();require('weread.ui.translation_generation').cancel(plugin)
assert(not plugin.translation_generation_job and not plugin.busy_message and handoffs==1,'cancel did not stop the request')
reader:onClose(false)
print('PASS: native translation request menu, worker, statuses, handoff and cancellation')
