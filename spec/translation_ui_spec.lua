package.path='./?.lua;'..package.path
local Model=require('weread.lib.translation')
local Crypto=require('weread.lib.crypto')
local Archive=require('weread.lib.translation_archive')
local raw='synthetic OPF'
local chapter=assert(Model.analyze('<html><body><p id="one">Original</p><p id="one" class="wr-translation">Translation</p></body></html>','1',1))
local profile={schema=1,book_id='42',file_id='synthetic',opf_path='OPS/package.opf',opf_sha256=Crypto.sha256_hex(raw),blocks=1,pairs=1,chapters={chapter}}
local attributes={mode='file',size=123,modification=100,ino=1,dev=1}
local inspect_count,inspect_failed=0,false
Archive.inspect=function() inspect_count=inspect_count+1;if not inspect_failed then return profile end end
package.preload['libs/libkoreader-lfs']=function() return {attributes=function() return attributes end} end
package.loaded['weread.lib.book_file_identity']={read_document=function(doc) return {file_id=doc.identity or 'synthetic'} end}
package.preload['ui/uimanager']=function() return {close=function(_self,menu) menu.closed=true end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(value) return value end,
    T=function(value,...) local args={...};return (value:gsub('%%(%d+)',function(i) return tostring(args[tonumber(i)]) end)) end} end
local Display=require('weread.ui.translation')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local function fixture(shared)
    attributes={mode='file',size=123,modification=100,ino=1,dev=1}
    local state={account='guest',id='42',notices={},jobs={},menus={},cancels=0,preference=shared and shared.preference}
    local doc={file='/synthetic.epub',xp='/body/DocFragment[1]/body/p[1]/text().3'}
    function doc:getDocumentFileContent() return raw end
    function doc:setStyleSheet(_base,css) state.css=css end
    function doc:getXPointer() return self.xp end
    function doc:getNormalizedXPointer(value) if state.pointer_error then error('private native error') end;return value end
    function doc:isXPointerInDocument() return not state.invalid_target end
    local host={_reader_session_gen=1,client={},library_db={accountKey=function() return state.account end},
        detectWeReadBook=function() return state.id end,
        ui={document=doc,typeset={css='base'},styletweak={getCssText=function() return 'user{color:black;}' end},
            rolling={onGotoXPointer=function(_self,value) state.target=value end}},
        showInfo=function(_self,value) state.notices[#state.notices+1]=value end,
        showTransientInfo=function(_self,value) state.notices[#state.notices+1]=value end,
        showBusy=function(self,_text,cancel) self.busy_message={};state.dismiss=cancel end,
        closeBusy=function(self) self.busy_message=nil end,
        closeWeReadUI=function(self) Display.cancel(self) end,
        showList=function(_self,title,items) local menu={title=title,item_table=items};state.menus[#state.menus+1]=menu;return menu end,
        translation_worker={start=function(_self,task,callback)
            if state.start_error then error('private failure') end
            if state.start_failed then return false end
            state.jobs[#state.jobs+1]={task=task,callback=callback};return true
        end,cancel=function() state.cancels=state.cancels+1 end}}
    host.ui.doc_settings={readSetting=function() return state.preference end,
        saveSetting=function(_self,_key,value) state.preference=value end,
        flush=function() if state.flush_error then error('private path') end;return not state.flush_failed and '/synthetic' end}
    host.ui.reloadDocument=function(_self,after_close,_seamless,after_open)
        state.reloads=(state.reloads or 0)+1
        if state.reload_error then error('private reload') end
        if state.reload_failed then return false end
        Display.document_close(host);host._reader_session_gen=host._reader_session_gen+1
        after_close()
        local next_host,next_state=fixture(state)
        next_host.ui.weread=next_host
        state.next_host,state.next_state=next_host,next_state
        Display.restore(next_host);Display.pre_render(next_host);Display.reader_ready(next_host)
        after_open(next_host.ui)
    end
    local function deliver(index,result)
        local job=assert(state.jobs[index or #state.jobs]);job.callback(result or job.task())
    end
    Display.restore(host)
    return host,state,deliver
end
local host,state,deliver=fixture()
expect(state.css:find('user{color:black;}',1,true) and state.css:find('display: none',1,true),'initial original did not preserve user CSS')
expect(Display.show(host) and host.translation_job and host.busy_message,'offline inspection did not start')
deliver();expect(host._translation_menu and not host.busy_message,'verified profile did not open choices')
local menu=host._translation_menu
expect(#menu.item_table==5 and menu.item_table[1].mandatory=='Current','mode choices/current marker absent')
menu.item_table[2].callback()
expect(state.reloads==1 and state.preference.mode=='bilingual','mode did not persist/reload')
expect(state.next_host._translation_mode=='bilingual' and state.next_state.target=='/body/DocFragment[1]/body/p[1]/text().3','reload lost bilingual position')
expect(not host._translation_profile and host.ui.styletweak:getCssText()=='user{color:black;}','old document retained style wrapper/profile')
host,state=state.next_host,state.next_state
Display.show(host);host._translation_menu.item_table[3].callback()
expect(state.next_state.target=='/body/DocFragment[1]/body/p[2]','translation reused original language offset')
expect(state.next_host._translation_mode=='translation','translation mode lost in transfer')
host,state=state.next_host,state.next_state
host.ui.document.xp='/body/DocFragment[1]/body/p[2]/text().2'
Display.show(host);host._translation_menu.item_table[1].callback()
expect(state.next_state.target=='/body/DocFragment[1]/body/p[1]','original remap reused translation offset')
Display.cancel(state.next_host)
for _,change in ipairs({'account','session','file','document','stat','deadline'}) do
    host,state,deliver=fixture();Display.show(host)
    if change=='account' then state.account='other'
    elseif change=='session' then host._reader_session_gen=2
    elseif change=='file' then host.ui.document.file='/other.epub'
    elseif change=='document' then host.ui.document={file='/synthetic.epub'}
    elseif change=='stat' then attributes.modification=101
    else host.translation_job.started=os.time()-121 end
    deliver()
    expect(not host._translation_menu and not host.busy_message and #state.notices==0,change..' accepted late result or opened stale notice')
end
host,state,deliver=fixture();Display.show(host);state.dismiss();Display.show(host)
local busy=host.busy_message;deliver(1)
expect(host.translation_job and host.busy_message==busy,'old inspection canceled replacement')
deliver(2);expect(host._translation_menu~=nil,'replacement inspection failed')
local old=host._translation_menu;Display.show(host);old.item_table[2].callback()
expect(not state.reloads and host._translation_menu~=old,'old menu acted on replacement')
state.account='changed';host._translation_menu.item_table[2].callback()
expect(not state.reloads,'stale menu changed account preference')
for _,failure in ipairs({'start_failed','start_error'}) do
    host,state=fixture();state[failure]=true;expect(not Display.show(host) and not host.busy_message and not host.translation_job,failure..' leaked busy')
    expect(#state.notices==1 and not state.notices[1]:find('private',1,true),'worker failure leaked exception')
end
host,state,deliver=fixture();Display.show(host);deliver(nil,{ok=true,profile={}})
expect(not host._translation_menu and #state.notices==1,'invalid profile accepted')
for _,failure in ipairs({'flush_failed','flush_error','reload_error','reload_failed','invalid_target','pointer_error'}) do
    host,state=fixture();state[failure]=true
    local ok,result=pcall(Display.apply,host,'translation',100,profile)
    expect(ok and result==false,failure..' escaped or accepted failed transition')
    expect(state.preference==nil and #state.notices<=1,failure..' retained changed preference')
end
host,state=fixture();host.ui.rolling.rendering_state='busy'
expect(not Display.apply(host,'bilingual',100,profile) and not state.preference,'rendering reader allowed change')
host=fixture();host.downloader={_scheduled_start=true}
expect(not Display.apply(host,'bilingual',100,profile),'scheduled download allowed change')
host,state=fixture();local none={schema=1,book_id='42',file_id='synthetic',opf_path=profile.opf_path,opf_sha256=profile.opf_sha256,blocks=0,pairs=0,chapters={chapter}}
expect(not Display.apply(host,'bilingual',100,none) and not state.preference,'missing translation generated or saved a mode')
local before=inspect_count
host=fixture({preference={schema=1,book_id='42',mode='translation',scale=140}})
expect(inspect_count==before+1 and host._translation_mode=='translation' and host._translation_scale==140,'saved mode did not inspect before load')
host.ui.document.identity='other';Display.pre_render(host)
expect(host._translation_mode=='original' and host._translation_restore_error,'wrong file identity accepted restored styles')
Display.document_close(host)
expect(host.ui.styletweak:getCssText()=='user{color:black;}','close retained CSS wrapper')
inspect_failed=true
host,state=fixture({preference={schema=1,book_id='42',mode='translation',scale=140}})
Display.reader_ready(host)
expect(host._translation_mode=='original' and #state.notices==1 and state.preference.mode=='translation','failed restore hid original, changed stored preference or omitted guidance')
print('PASS: translation reader UI ('..checks..' checks)')
