package.path='./?.lua;'..package.path
local state
local function clone(v) local t={};for k,x in pairs(v) do t[k]=x end;return t end
package.loaded['weread.lib.translation_fetch']={MAX_OUTPUT=10000,MAX_BOOK_CHAPTERS=2000,
    run=function() return state.result end,run_book=function(...) state.resume_choice=select(7,...)
        if state.run_error then error(state.run_error,0) end;return state.result end}
package.loaded['weread.lib.position_source']={document_metadata=function() return {chapter_uid='1',metadata='metadata',record={format='web_xhtml'},identity={file_id=string.rep('a',64)}} end}
package.loaded['weread.lib.source_dom']={member=function() return {render_path='OEBPS/chapter.xhtml'} end}
package.loaded['weread.lib.source_context']={location=function() return clone(state.location) end,
    same_location=function(a,b) return a.xpointer==b.xpointer and a.page==b.page end}
package.preload['libs/libkoreader-lfs']=function() return {symlinkattributes=function(path)
    return path=='/book/original.epub' and clone(state.stat) or path=='/book/output.epub' and clone(state.copy_stat or {mode='file',size=0,ino=2,dev=1,modification=1}) end} end
package.loaded['weread.lib.book_operation']={prepare=function() if state.lock_failed then return nil end;return {release=function() state.released=state.released+1 end} end}
package.loaded['weread.lib.notes_export_file']={create=function(_directory,_title,format)
    if state.output_failed then return nil end
    local output={path=format=='epub_part' and '/book/staged.epub.part' or '/book/output.epub'}
    function output:abort() state.aborted=state.aborted+1 end
    function output:accept() return not state.accept_failed end
    function output:owns() return true end
    function output:close() return true end
    return output
end}
rawset(os,'rename',function() return not state.rename_failed end)
package.preload['ui/uimanager']=function() return {close=function(_self,widget) widget.closed=true end,show=function() end} end
package.preload['ui/widget/confirmbox']=function() return {new=function(_self,options) return options end} end
package.preload['ui/widget/buttondialog']=function() return {new=function(_self,options) return options end} end
package.loaded['weread.ui.download_dialog']={new=function(_self,options)
    function options:show() state.progress_dialog=self end
    function options:reportProgress(value) state.progress_values[#state.progress_values+1]=value end
    return options
end}
package.loaded['weread.lib.plugin_util']={tr=function(text) return text end,T=function(text) return text end}
local UI=require('weread.ui.translation_fetch')
local checks=0
local function expect(v,reason) checks=checks+1;assert(v,reason) end
local function fixture()
    state={account='synthetic-account',location={xpointer='/body/DocFragment[1]/body/p[1]/text().0',page=1},
        stat={mode='file',size=300,ino=1,dev=1,modification=1},notices={},jobs={},progress_values={},released=0,aborted=0,cancelled=0}
    state.result={ok=true,chapter_uid='1',bytes=100,blocks=2,file_id=string.rep('b',64)}
    local settings={get_auth_scope=function() return {epoch=1} end,auth_scope_matches=function() return not state.auth_changed end,
        get=function(_self,key,default) if key=='cookies' then return {['wr_skey']=state.cookie or 'synthetic'} end;return default end,
        get_book=function() return {title='Synthetic'} end}
    local doc_settings={readSetting=function() return state.copies end,saveSetting=function(_self,_key,value) state.copies=value end,
        flush=function() return not state.flush_failed and '/sidecar' end}
    local host={settings=settings,client={},_reader_session_gen=1,library_db={accountKey=function() return state.account end},
        detectWeReadBook=function() return '900001' end,ui={document={file='/book/original.epub'},doc_settings=doc_settings},
        isNetworkOnline=function() return not state.offline end,requireLogin=function() return not state.logged_out end,
        closeWeReadUI=function(self) UI.cancel(self) end,showOffline=function() state.notices[#state.notices+1]='offline' end,
        showInfo=function(_self,text) state.notices[#state.notices+1]=text end,
        showBusy=function(self,_text,cancel) self.busy_message={};state.dismiss=cancel end,closeBusy=function(self) self.busy_message=nil end,
        translation_fetch_worker={start=function(_self,task,callback,progress)
            if state.start_error then error('private worker failure') end
            if state.start_failed then return false end
            state.jobs[#state.jobs+1]={task=task,callback=callback,progress=progress};return true
        end,cancel=function() state.cancelled=state.cancelled+1 end}}
    local function deliver(index,result) state.jobs[index or #state.jobs].callback(result or state.result) end
    return host,deliver
end
local host,deliver=fixture()
expect(UI.start(host) and host.translation_fetch_job,'download did not start')
deliver();expect(not host.translation_fetch_job and host._translation_fetch_result and not host.busy_message,'success leaked busy/job')
expect(state.copies['1'].file_id==string.rep('b',64) and state.released==1 and state.aborted==0,'accepted output was not retained/indexed')
UI.cancel(host);expect(not host._translation_fetch_result,'cancel kept result dialog')
for _,change in ipairs({'account','session','document','file','stat','auth','cookie','page','deadline'}) do
    host,deliver=fixture();UI.start(host)
    if change=='account' then state.account='other'
    elseif change=='session' then host._reader_session_gen=2
    elseif change=='document' then host.ui.document={file='/book/original.epub'}
    elseif change=='file' then host.ui.document.file='/other.epub'
    elseif change=='stat' then state.stat.modification=2
    elseif change=='auth' then state.auth_changed=true
    elseif change=='cookie' then state.cookie='replaced'
    elseif change=='page' then state.location.page=2
    else host.translation_fetch_job.started=os.time()-76 end
    deliver();expect(not host.translation_fetch_job and not host._translation_fetch_result and state.aborted==1 and state.released==1,change..' accepted stale output')
    expect(not state.copies and #state.notices==0,change..' modified index or showed stale dialog')
end
host,deliver=fixture();UI.start(host);state.dismiss();expect(state.aborted==1 and state.released==1 and not host.busy_message,'dismiss did not clean output')
UI.start(host);local current=host.translation_fetch_job;deliver(1)
expect(host.translation_fetch_job==current and state.aborted==1,'old callback canceled replacement')
deliver(2);expect(host._translation_fetch_result~=nil,'replacement did not finish')
for _,failure in ipairs({'start_error','start_failed','output_failed','lock_failed','offline','logged_out'}) do
    host=fixture();state[failure]=true
    expect(not UI.start(host) and not host.translation_fetch_job and not host.busy_message,failure..' leaked job/busy')
end
for _,result in ipairs({{ok=false,reason='missing'},{ok=true},{ok=true,chapter_uid='2',bytes=100,blocks=1,file_id=string.rep('b',64)},
    {ok=true,chapter_uid='1',bytes=1e20,blocks=1,file_id=string.rep('b',64)},
    {ok=true,chapter_uid='1',bytes=100,blocks=1,file_id=string.rep('b',64),target='https://example.invalid'}}) do
    host,deliver=fixture();UI.start(host);deliver(nil,result)
    expect(state.aborted==1 and state.released==1 and not host._translation_fetch_result,'invalid worker result retained output')
    expect(#state.notices==1 and not state.copies,'invalid result omitted guidance or modified shortcut')
end
host,deliver=fixture();state.accept_failed=true;UI.start(host);deliver()
expect(state.aborted==1 and not state.copies,'failed output accept was indexed')
host,deliver=fixture();state.flush_failed=true;UI.start(host);deliver()
expect(state.aborted==0 and host._translation_fetch_result and #state.notices==1,'shortcut failure deleted a saved copy or omitted guidance')
host,deliver=fixture();state.rename_failed=true;UI.start(host);deliver()
expect(state.aborted==2 and not state.copies and not host._translation_fetch_result,'failed publication retained placeholder or indexed staged output')
host=fixture();UI.start(host);state.location.page=2;UI.view_changed(host)
expect(not host.translation_fetch_job and state.aborted==1,'page event did not cancel live fetch')
host,deliver=fixture();UI.start(host);deliver();local result=host._translation_fetch_result;state.location.page=2;UI.view_changed(host)
expect(not host._translation_fetch_result and result.closed,'page event kept old result dialog')
host,deliver=fixture();state.result={ok=true,chapter_uid='1',bytes=100,blocks=2,chapters=6,translated_chapters=4,
    matched=true,target='/body/DocFragment[3]/body/p[1]',file_id=string.rep('b',64)}
expect(UI.start(host,true),'full-book download did not start')
expect(host.translation_fetch_worker.timeout==3600,'full-book worker kept the chapter timeout')
local progress=assert(state.jobs[1].progress)
for _,value in ipairs({0,20,20,10,99,98}) do progress(value) end
expect(table.concat(state.progress_values,',')=='0,20,98','full-book progress was missing, regressed, or exceeded the verified bound')
deliver();expect(state.copies.__full and state.copies.__full.file_id==string.rep('b',64)
    and not state.copies['1'] and host._translation_fetch_result,'full-book copy was not indexed separately')
progress(97);expect(#state.progress_values==3,'late progress changed a completed dialog')
host=fixture();UI.start(host,true);state.progress_dialog.buttons[1][1].callback()
expect(not host.translation_fetch_job and not host.busy_message and state.aborted==1 and state.released==1,
    'progress dialog cancel did not clean the job')
host=fixture();UI.start(host,true);progress=state.jobs[1].progress;state.location.page=2;progress(10)
expect(not host.translation_fetch_job and not host.busy_message and state.aborted==1,'stale progress did not cancel the job')
for _,change in ipairs({'no_chapters','too_many_translated','bad_fragment','bad_path','missing_target','missing_match'}) do
    host,deliver=fixture();state.result={ok=true,chapter_uid='1',bytes=100,blocks=2,chapters=6,translated_chapters=4,
        matched=true,target='/body/DocFragment[3]/body/p[1]',file_id=string.rep('b',64)}
    if change=='no_chapters' then state.result.chapters=0
    elseif change=='too_many_translated' then state.result.translated_chapters=7
    elseif change=='bad_fragment' then state.result.target='/body/DocFragment[7]/body/p[1]'
    elseif change=='bad_path' then state.result.target='/body/DocFragment[3]/bodyevil'
    elseif change=='missing_target' then state.result.target=nil
    else state.result.matched=nil end
    UI.start(host,true);deliver();expect(not state.copies and state.aborted==1,'invalid full-book result was accepted: '..change)
end
host,deliver=fixture();state.run_error='translation_fetch/source_limit';UI.start(host,true)
local limited=state.jobs[1].task();expect(limited.reason=='limit','full-book limit lost its user-facing reason')
deliver(1,limited);expect(state.aborted==1 and #state.notices==1 and not state.copies,'limited book was published')
host=fixture();state.copy_stat={mode='file',size=100,ino=2,dev=1,modification=1}
state.copies={__full={schema=1,book_id='900001',account='synthetic-account',source_file_id=string.rep('a',64),
    path='/book/output.epub',file_id=string.rep('b',64),bytes=100}}
expect(UI.saved_entry(host)==state.copies.__full,'full-book shortcut was not available for current chapter')
state.copy_stat.ino=state.stat.ino
expect(not UI.saved_entry(host),'hard-linked copy was accepted as independent')
state.copy_stat.ino=2;state.copies.__full.account='another-account'
expect(not UI.saved_entry(host),'another account’s full-book copy was accepted')
package.loaded['weread.lib.translation_resume']={new=function() return {summary=function() return {count=2,generation=string.rep('a',32)} end,
    clear=function(_self,token) state.cleared=token;return not state.clear_failed end} end}
host=fixture();host.library_db.open=function() end
expect(UI.start(host,true) and host._translation_resume_prompt and not host.translation_fetch_job,'saved download did not offer a choice')
local prompt=host._translation_resume_prompt
prompt.buttons[1][1].callback();expect(host.translation_fetch_job and prompt.closed,'resume choice did not start the job')
state.jobs[1].task();expect(state.resume_choice==true,'resume choice was not passed to the worker')
host=fixture();host.library_db.open=function() end;UI.start(host,true);prompt=host._translation_resume_prompt
prompt.buttons[2][1].callback();state.jobs[1].task()
expect(state.resume_choice==false and prompt.closed,'restart choice reused old chapters')
host=fixture();host.library_db.open=function() end;UI.start(host,true);prompt=host._translation_resume_prompt
prompt.buttons[3][1].callback()
expect(prompt.closed and state.cleared.book_id=='900001' and #state.cleared.generation==32 and not host.translation_fetch_job
    and #state.notices==1,'delete choice did not remove the selected checkpoint')
host,deliver=fixture();host.library_db.open=function() end;state.clear_failed=true
state.result={ok=true,chapter_uid='1',bytes=100,blocks=2,chapters=6,translated_chapters=4,matched=true,
    target='/body/DocFragment[3]/body/p[1]',file_id=string.rep('b',64),
    resume_token={book_id='900001',generation=string.rep('a',32)}}
UI.start(host,true,false);deliver()
expect(host._translation_fetch_result and host._translation_fetch_result.text:find('could not be removed',1,true)
    and state.copies.__full,'checkpoint cleanup failure hid a successfully saved copy or its warning')
host=fixture();host.library_db.open=function() end;UI.start(host,true);prompt=host._translation_resume_prompt
state.location.page=2;UI.view_changed(host);prompt.buttons[1][1].callback()
expect(prompt.closed and not host._translation_resume_prompt and not host.translation_fetch_job,'stale resume prompt started a download')
print('translation_fetch_ui_spec: '..checks..' checks')
