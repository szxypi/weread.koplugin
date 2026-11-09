package.path='./?.lua;'..package.path
local state,Recovery,timers
package.preload['ui/uimanager']=function() return {
    show=function() end,close=function(_self,widget) if widget.onCloseWidget then widget:onCloseWidget() end end,
    scheduleIn=function(_self,_delay,callback) timers[#timers+1]=callback end} end
package.preload['ui/widget/confirmbox']=function() return {new=function(_self,value) return value end} end
package.preload['ui/event']=function() return {new=function() return {} end} end
package.preload['dump']=function() return function() return '{["live"]=true}' end end
package.preload['weread.lib.plugin_util']=function() return {tr=function(value) return value end,
    T=function(value,...) local args={...};return (value:gsub('%%(%d+)',function(index) return tostring(args[tonumber(index)]) end)) end} end
package.preload['weread.lib.mp_record_recovery']=function() return {
    capture=function(_settings,book,article,path)
        if state.bad_source then error('private-source-error') end
        if state.legacy then return nil,'legacy' end
        return {root=book.cache_dir,key=string.rep('a',64),path=path,stamped=state.stamped,review=article.reviewId,
            legacy=(state.legacy_html or state.legacy_epub) or nil,epub=state.epub or nil}
    end,
    matches=function(_settings,book,article,input) return not state.stale and book.cache_dir==input.root and article.reviewId==input.review end,
    hash_directory=function(path) return state.live and 'shared' or path end,
    freeze=function() return {} end,
    preserve=function(_store,_input,rows)
        state.preserved=true;state.live_captured=rows[1] and rows[1].kind=='live'
        if state.preserve_failed then error('private-storage-error') end
        return true
    end,
    prepare=function()
        if state.prepare_failed then error('private-storage-error') end
        return {ok=true,source_sha256=not state.no_sha and string.rep('b',64) or nil,rows=state.rows,assets={}}
    end,
    bind_stage=function() state.stage_bound=true;return not state.stage_bind_failed end,
    bind_assets=function() state.assets_bound=true;return not state.asset_bind_failed end,
    assets_match=function() return not state.assets_changed end,
    write=function() state.body_written=true;return {ok=true} end,
    restore=function(_store,_input,id)
        state.restore_id=id;state.restored=not state.restore_failed;return state.restored
    end} end
package.preload['weread.lib.mp_records_db']=function() return {MAX_RECORDS=128,new=function() return {exists=function() return not state.no_history end} end} end
package.preload['weread.lib.mp_download_stage']=function() return {} end
Recovery=require('weread.ui.mp_record_recovery')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local function fixture()
    timers={};state={account='one',rows={{id=string.rep('c',64),kind='backup',saved_at=1700000000,
        valid=true,notes=1,bookmarks=1,has_position=true,preview='Synthetic quote',note_preview='Synthetic note'}},books={MP_WXS_1={cache_dir='/cache'}}}
    local host={settings={cache_dir='/all',data_dir='/data',get=function() return state.books end},
        ui={document={file='/reader.html'}},_reader_session_gen=1,discovery_epoch=1,
        library_db={accountKey=function() return state.account end},
        openFile=function(_self,path) state.opened=path end,showInfo=function(_self,text) state.notice=text end,
        closeWeReadUI=function(self) Recovery.cancel(self);self.discovery_epoch=self.discovery_epoch+1 end,
        showList=function(_self,title,rows) return {title=title,item_table=rows} end,
        showBusy=function(self,_text,cancel) self.busy_message={};state.cancel_busy=cancel end,
        closeBusy=function(self) self.busy_message=nil end}
    host.mp_records_worker={runner={done=function() return state.done~=false end},
        start=function(self,task,callback) state.task=task;state.callback=callback;self.job={pid=1};return true end,
        cancel=function(self) state.cancelled=true;self.job=nil end}
    host.create_mp_stage=function(_root,_key,options)
        state.stage_created=true;state.stage_format=options.format
        return {close=function() state.stage_closed=true end,cleanup=function() state.cleaned=true end,
            commit=function(_self,_result,deferred)
                state.deferred=deferred
                if state.commit_failed then return nil end
                return state.epub and '/cache/new.epub' or '/cache/new.html'
            end,
            publish_deferred=function()
                assert(state.restored,'current selector published before record readback')
                state.published=not state.publish_failed;return state.published
            end}
    end
    return host,{book_id='MP_WXS_1',cache_dir='/cache'},{reviewId='one',title='Synthetic article'}
end
local function deliver(host)
    local task,callback=state.task,state.callback
    local ok,result=pcall(task);host.mp_records_worker.job=nil
    callback(ok and result or {error='worker_failed'})
end
local function choose(host)
    host._mp_records_menu.item_table[1].callback();return host._mp_records_confirmation
end
local host,book,article=fixture()
expect(Recovery.open(host,book,article,'/cache/old.html') and state.preserved and not state.opened and not state.stage_created,'unsafe old text opened before durable preservation')
deliver(host);expect(host._mp_records_menu and not state.stage_created,'inspection changed current cache')
local dialog=choose(host)
expect(dialog.text:find('Synthetic note',1,true) and dialog.text:find('another version',1,true),'record selection omitted preview or uncertainty')
dialog.cancel_callback();expect(not state.stage_created and host.mp_records_job,'cancelled confirmation created a copy')
dialog=choose(host);dialog.ok_callback()
expect(state.stage_created and not state.published and not state.opened,'confirmation published before copy and records')
deliver(host)
expect(state.body_written and state.deferred and state.restored and state.published and state.opened=='/cache/new.html','explicit recovery did not publish after records')
expect(not host.mp_records_job and not host.busy_message,'success retained recovery task or busy overlay')
for _i,kind in ipairs({'beside','beside_backup','folder','folder_backup','legacy_beside','history','history_backup','compatibility'}) do
    host,book,article=fixture();state.rows[1].kind=kind
    Recovery.open(host,book,article,'/cache/old.html');deliver(host)
    expect(host._mp_records_menu and not state.notice,'native record location missing from chooser: '..kind)
    Recovery.cancel(host)
end
for _i,mode in ipairs({'stamped','legacy'}) do
    host,book,article=fixture();state[mode]=true;Recovery.open(host,book,article,'/cache/old.html')
    expect(state.opened=='/cache/old.html' and not state.task,'safe or separately validated legacy path blocked')
end
host,book,article=fixture();state.rows={};Recovery.open(host,book,article,'/cache/old.html');deliver(host)
expect(state.opened=='/cache/old.html' and not state.stage_created,'no-record old cache required unnecessary recovery')
host,book,article=fixture();state.no_history=true;Recovery.open(host,book,article,'/cache/old.html')
expect(state.opened=='/cache/old.html' and not state.task and not state.preserved,'ordinary read required a new writable archive without any records')
host,book,article=fixture();state.rows={};Recovery.show(host,book,article,'/cache/old.html');deliver(host)
expect(state.notice and not state.opened,'explicit empty recovery opened a file')
host,book,article=fixture();host.ui.doc_settings={data={}};host.ui.handleEvent=function() state.saved_in_memory=true end
state.live=true;state.no_history=true;Recovery.open(host,book,article,'/cache/old.html');deliver(host)
expect(state.saved_in_memory and state.live_captured,'current unclosed shared record was not preserved')
for _i,change in ipairs({'account','epoch','session','document','file','cache','record','root','article','stale'}) do
    host,book,article=fixture();Recovery.open(host,book,article,'/cache/old.html');deliver(host);dialog=choose(host)
    if change=='account' then state.account='two' elseif change=='epoch' then host.discovery_epoch=20
    elseif change=='session' then host._reader_session_gen=20 elseif change=='document' then host.ui.document={file='/reader.html'}
    elseif change=='file' then host.ui.document.file='/other.html' elseif change=='cache' then host.settings.cache_dir='/moved'
    elseif change=='record' then state.books.MP_WXS_1.cache_dir='/moved' elseif change=='root' then book.cache_dir='/moved'
    elseif change=='article' then article.reviewId='two' else state.stale=true end
    dialog.ok_callback();expect(not state.stage_created and not state.opened,'stale confirmation restored: '..change)
end
for _i,failure in ipairs({'prepare_failed','commit_failed','restore_failed','publish_failed'}) do
    host,book,article=fixture();state[failure]=true;Recovery.open(host,book,article,'/cache/old.html');deliver(host)
    if host._mp_records_menu then choose(host).ok_callback();deliver(host) end
    expect(not state.opened and not state.published and state.notice and not state.notice:find('private-',1,true),'failed recovery opened or leaked: '..failure)
    if failure~='prepare_failed' then expect(state.cleaned,'failed copy was not cleaned: '..failure) end
end
host,book,article=fixture();state.preserve_failed=true
expect(not Recovery.open(host,book,article,'/cache/old.html') and not state.task and not state.opened,'preservation failure entered background or opened old body')
host,book,article=fixture();Recovery.open(host,book,article,'/cache/old.html');deliver(host)
local stale_menu=host._mp_records_menu;stale_menu:onCloseWidget();stale_menu.item_table[1].callback()
expect(not host.mp_records_job and not host._mp_records_confirmation,'closed chooser retained a live callback')
host,book,article=fixture();Recovery.open(host,book,article,'/cache/old.html');deliver(host);choose(host).ok_callback()
state.done=false;state.cancel_busy()
expect(state.cancelled and state.stage_closed and not state.cleaned,'cancel cleaned files while child could still write')
state.done=true;table.remove(timers,1)();expect(state.cleaned and not state.opened,'cancel did not reap before cleanup')
host,book,article=fixture();Recovery.open(host,book,article,'/cache/old.html');deliver(host)
host._mp_records_menu.item_table[2].callback();host._mp_records_confirmation.ok_callback();deliver(host)
expect(state.restore_id==false and state.opened=='/cache/new.html','fresh copy applied an arbitrary saved record')
host,book,article=fixture();state.legacy_html=true;state.stamped=true
Recovery.open(host,book,article,'/cache/title.html');deliver(host)
expect(state.assets_bound and host._mp_records_menu and not state.opened,'title-based HTML skipped preservation because of an old revision marker')
choose(host).ok_callback();deliver(host)
expect(state.stage_bound and state.body_written and state.published and state.opened=='/cache/new.html','legacy HTML was not bound to its first stage')
for _i,failure in ipairs({'asset_bind_failed','stage_bind_failed','assets_changed'}) do
    host,book,article=fixture();state.legacy_html=true;state[failure]=true
    Recovery.open(host,book,article,'/cache/title.html');deliver(host)
    if host._mp_records_menu then
        choose(host).ok_callback()
        if state.body_written or failure=='assets_changed' then deliver(host) end
    end
    expect(not state.opened and not state.published and state.notice,'legacy resource or target failure published a copy: '..failure)
end
host,book,article=fixture();state.legacy_html=true;state.rows={};state.no_sha=true
Recovery.open(host,book,article,'/cache/title.html');deliver(host)
expect(state.opened=='/cache/title.html' and not state.assets_bound and not state.stage_created,'ordinary title cache required copy-only preparation')
host,book,article=fixture();state.epub=true;state.legacy_epub=true
Recovery.open(host,book,article,'/cache/title.epub');deliver(host)
expect(host._mp_records_menu and state.preserved and not state.assets_bound and not state.opened,'legacy EPUB bypassed preservation or required external assets')
choose(host).ok_callback();deliver(host)
expect(state.stage_bound and state.stage_format=='epub' and state.published and state.opened=='/cache/new.epub','EPUB recovery used the HTML publisher or skipped first-stage binding')
host,book,article=fixture();state.epub=true;state.stamped=true
Recovery.open(host,book,article,'/cache/version.epub')
expect(state.opened=='/cache/version.epub' and not state.task,'independent EPUB did not retain direct reading')
host,book,article=fixture();state.epub=true;state.legacy_epub=true;state.stage_bind_failed=true
Recovery.open(host,book,article,'/cache/title.epub');deliver(host);choose(host).ok_callback()
expect(not state.opened and not state.published and state.notice,'EPUB target binding failure published a copy')
print('PASS: native record recovery choice, ownership, failure and cancellation ('..checks..' checks)')
