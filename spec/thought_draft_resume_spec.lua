package.path='./?.lua;'..package.path
local UI={}
function UI:show(widget) self.top=widget end
function UI:close(widget) if widget.onCloseWidget then widget:onCloseWidget() end end
function UI:scheduleIn(_,callback) self.notice=callback end
function UI:unschedule(callback) if self.notice==callback then self.notice=nil end end
package.preload['ui/uimanager']=function() return UI end
package.preload['ui/widget/menu']=function() return {new=function(_self,v) return v end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(v) return v end} end
package.preload['weread.lib.thought_edit_contract']=function() return {
    reference_hash=function(_op,row) return row.hash end,valid_content=function(v) return type(v)=='string' and v~='' end,
    key=function(v) return type(v)=='string' and v~='' end,hash=function(v) return type(v)=='string' and #v==64 end} end
local state
local function copy(value) local out={};for k,v in pairs(value) do out[k]=v end;return out end
package.preload['weread.lib.thought_edit_store']=function() return {new=function() return {
    read=function() return copy(state.record) end,
    finish=function(_self,record,phase)
        assert(record.revision==state.record.revision and phase=='prepared')
        if state.claim_on_finish then state.record.phase='pending' end
        if state.record.phase~=phase then return false end
        state.record.phase='idle';return true
    end,
    draft=function(_self,key)
        state.draft_reads=(state.draft_reads or 0)+1
        if state.error then return nil,'storage' end
        if state.draft and state.draft.draft_key==key then return copy(state.draft) end
    end,
    draft_previews=function()
        local values={}
        for _,draft in ipairs(state.drafts or state.draft and {state.draft} or {}) do
            values[#values+1]={draft_key=draft.draft_key,book_id=draft.book_id,token=draft.token,
                preview=require('weread.lib.protocol').utf8_substr(draft.content,60):gsub('[%z%c]',' ')}
        end
        return values
    end,
    save_draft=function(_self,_book,_operation,_reference,_base,content,expected)
        if state.require_lease then assert(state.lease_held,'chapter lease missing while saving draft') end
        state.save_expected=expected;if state.save_failed then return nil end
        state.saved_body=content;return {token='new'} end,
    delete_draft=function() return false end,
} end,draft_key=function() return 'draft' end} end
package.preload['weread.lib.my_cloud_marks_store']=function() return {new=function() return {} end} end
package.preload['weread.lib.thought_edit_service']=function() return {new=function() return {
    cancel=function() end,prepare=function() error('local action started cloud work') end,
} end} end
package.preload['weread.ui.mark_editor']=function() return {cancel=function() end} end
package.preload['weread.lib.my_cloud_marks']=function() return {id=function(id) return id end} end
package.preload['weread.lib.my_mark_target']=function() return {can_locate=function(row) return row and row.bookmarkId~=nil end} end
package.preload['weread.lib.selection_reference']=function() return {
    parse=function(v) return v=='selection' and {chapter_uid='7',raw_sha256=string.rep('a',64)} or nil end,
    valid=function(row,id) return row and row.source and row.source.book_id==id end,
    restore=function() return state.restored end} end
package.preload['weread.ui.thought_text']=function() return {
    viewer=function(v) return v end,menu=function(v) return v end,input=function(v) function v:getInputText() return self.input end;return v end} end
package.preload['weread.lib.memory_worker']=function() return {new=function() return {
    start=function(_self,task,callback) state.task=task;state.complete=callback
        if state.worker_throws then error('synthetic worker failure') end;return not state.worker_failed end,
    cancel=function() state.cancelled=true end} end} end
package.preload['weread.ui.my_cloud_marks']=function() return {open=function(host,id,variant,options)
    assert(options.current())
    state.opened={id=id,variant=variant,options=options}
    state.apply=function()
        if not options.current() then return end
        host._my_marks_owner={id=id};options.on_open(host._my_marks_owner)
    end
    return true
end} end
local Editor=require('weread.ui.thought_editor')
local checks=0;local function expect(v,label) checks=checks+1;assert(v,label) end
local function fixture()
    state={draft={draft_key='draft',token='v1',book_id='42',operation='create',reference_id='mark',base_hash='original',content='Saved draft'}}
    local host={client={},settings={},library_db={},ui={document={file='/unrelated'}}}
    function host.library_db:accountKey() return 'account' end
    function host.library_db:getChapters() return {} end
    function host.settings:auth_scope_matches() return true end
    function host.settings:get_book() return {book_id='42'} end
    function host:showInfo(message) state.message=message end
    function host:showOffline(label) state.offline_label=label end
    function host:isNetworkLinkAvailable() return false end
    function host:isNetworkOnline() error('local action probed Internet reachability') end
    function host:showInputDialog(widget) UI:show(widget) end
    local owner={id='42',account='account',scope={},thoughts=false,menu={},value={updated={{bookmarkId='mark',markText='quote',hash='original'}}}}
    host.owner=owner
    local function current(h,o) return h.owner==o and not o.menu._shelf_closed end
    return host,owner,current
end
local function open_list(host,owner,current)
    if not Editor.drafts(host,owner,current) then return false end
    expect(owner.editor.draft_job and not owner.editor.dialog,'preview read immediately redrew the UI')
    state.complete(state.task())
    return true
end
local host,owner,current=fixture()
expect(Editor.resume(host,owner,'draft','v1',current),'matching draft did not resume')
expect(owner.editor and owner.editor.input.input=='Saved draft','draft text not restored')
owner.editor.input.buttons[1][1].callback()
expect(state.save_expected=='v1' and not owner.editor,'resumed draft did not save against the observed version')
host,owner,current=fixture();Editor.resume(host,owner,'draft','v1',current)
owner.editor.input.input='Changed while offline';owner.editor.input.buttons[1][2].callback()
expect(owner.editor and owner.editor.input.input=='Changed while offline' and state.saved_body=='Changed while offline'
    and state.save_expected=='v1' and state.message:find('saved on this device',1,true),'offline Continue did not save the current draft')
host,owner,current=fixture();state.record={phase='idle',revision=1}
expect(not Editor.check(host,owner,current) and not owner.editor and state.message=='No thought change needs checking.',
    'idle recovery required a connection')
host,owner,current=fixture();state.record={phase='prepared',revision=2}
expect(Editor.check(host,owner,current) and state.record.phase=='idle' and state.draft.token=='v1'
    and state.message:find('unsent change was cancelled',1,true),'offline check failed to clear the unsent intent without touching the draft')
host,owner,current=fixture();state.record={phase='prepared',revision=3};state.claim_on_finish=true
expect(not Editor.check(host,owner,current) and state.record.phase=='pending' and state.draft.token=='v1'
    and state.message:find('needs checking',1,true),'cancelling a prepared intent cleared a concurrently claimed dispatch')
expect(not Editor.check(host,owner,current) and state.record.phase=='pending' and state.offline_label=='Thought',
    'offline check of a pending dispatch attempted cloud work or lost the pending operation')
host,owner,current=fixture();state.draft=nil
expect(Editor.start(host,owner,'create',owner.value.updated[1],current),'new draft editor did not open')
owner.editor.input.input='New draft';owner.editor.input.buttons[1][1].callback()
expect(state.save_expected==false and not owner.editor,'new draft save did not require an empty slot')
host,owner,current=fixture();Editor.resume(host,owner,'draft','v1',current);state.save_failed=true
owner.editor.input.buttons[1][1].callback()
expect(owner.editor and state.message:find('changed elsewhere',1,true),'conflicting save closed the editor or hid the conflict')
host,owner,current=fixture();state.draft.token='v2'
expect(not Editor.resume(host,owner,'draft','v1',current) and not owner.editor and state.message:find('changed',1,true),'stale token opened editor')
host,owner,current=fixture();state.draft.book_id='43'
expect(not Editor.resume(host,owner,'draft','v1',current) and not owner.editor,'other-book record opened under wrong owner')
host,owner,current=fixture();owner.value.updated[1].hash='different'
expect(not Editor.resume(host,owner,'draft','v1',current) and not owner.editor and state.message:find('unavailable',1,true),'changed reference accepted')
host,owner,current=fixture();state.error=true
expect(not Editor.resume(host,owner,'draft','v1',current) and not owner.editor,'unreadable draft was opened')
expect(not Editor.start(host,owner,'create',owner.value.updated[1],current) and not owner.editor
    and state.message=='Could not load local thought drafts.','unreadable draft opened an empty editor')
host,owner,current=fixture();state.draft.reference_id='selection';state.draft.base_hash='source';owner.value=nil
expect(Editor.resume(host,owner,'draft','v1',current) and state.complete,'selection did not start source validation')
state.complete({});expect(not owner.editor and state.message:find('unavailable',1,true),'missing source opened editor')
host,owner,current=fixture();state.draft.reference_id='selection';state.draft.base_hash='source';owner.value=nil
Editor.resume(host,owner,'draft','v1',current);host.owner={};state.complete({reference={selection=true,source={book_id='42'},bookmarkId='selection',hash='source'}})
expect(not owner.editor or not owner.editor.input,'stale owner opened selection editor')
host,owner,current=fixture();state.draft.reference_id='selection';state.draft.base_hash='source';owner.value=nil
Editor.resume(host,owner,'draft','v1',current);state.complete({reference={selection=true,source={book_id='42'},bookmarkId='selection',hash='source'}})
expect(owner.editor and owner.editor.input and owner.editor.input.input=='Saved draft','verified selection did not restore')
host,owner,current=fixture();state.draft.reference_id='selection';state.draft.base_hash='source';owner.value=nil
Editor.resume(host,owner,'draft','v1',current);state.draft.token='v2'
state.complete({reference={selection=true,source={book_id='42'},bookmarkId='selection',hash='source'}})
expect(not owner.editor and state.message:find('changed',1,true),'replacement during source validation opened stale draft')
host,owner,current=fixture();owner.id='41';host._notebook_owner={child=owner}
local full_draft=string.rep('字',65)..'完整草稿结尾'
state.draft.content=full_draft
expect(open_list(host,owner,current),'cross-book draft list did not open')
expect(owner.editor.dialog.item_table[1].mandatory=='Book ID 42','cross-book draft did not identify its book')
local selected_row=owner.editor.dialog.item_table[1]
expect(not state.draft_reads,'opening the draft list read the full selected draft')
selected_row.callback();local viewer=owner.editor.dialog
expect(selected_row.text==string.rep('字',60) and viewer.text==full_draft and state.draft_reads==1,
    'opening a preview did not read its full text')
selected_row.callback()
expect(owner.editor.dialog==viewer and state.draft_reads==1,'obsolete draft list reopened a preview')
local button=viewer.buttons_table[1][2]
expect(button.id=='resume_other_book_draft','cross-book resume not offered')
button.callback()
expect(state.opened.options.source==owner.menu and host._notebook_owner.child==owner,'pending handoff replaced its source')
state.apply()
expect(state.opened and state.opened.id=='42' and state.opened.variant==nil and state.opened.options.resume_draft.token=='v1'
    and host._notebook_owner.child==host._my_marks_owner,'cross-book handoff lost target or parent ownership')
host,owner,current=fixture();owner.id='41'
state.drafts={copy(state.draft),copy(state.draft)}
local prefix=string.rep('字',57)..'\n😀🙂'
state.drafts[1].content=prefix..string.rep('x',4096)
local titles=0
function host.library_db:getBook(id)
    expect(id=='42')
    titles=titles+1;return {title='Saved book'}
end
expect(open_list(host,owner,current),'same-book drafts did not list')
local rows=owner.editor.dialog.item_table
expect(rows[1].text==prefix:gsub('\n',' ') and rows[1].mandatory=='Saved book'
    and rows[2].mandatory=='Saved book' and titles==1,'draft preview split UTF-8, changed text, or repeated a title lookup')
host,owner,current=fixture();owner.id='41';host._notebook_owner={child=owner}
open_list(host,owner,current);owner.editor.dialog.item_table[1].callback()
owner.editor.dialog.buttons_table[1][2].callback();owner.menu._shelf_popup={}
state.apply()
expect(not host._my_marks_owner and host._notebook_owner.child==owner,'delayed handoff displaced a newer popup')
host,owner,current=fixture();state.draft.operation='edit';state.draft.reference_id='review';owner.thoughts=true
owner.value={reviews={{reviewId='review',isPrivate=1,content='Original',hash='original'}}}
expect(Editor.resume(host,owner,'draft','v1',current) and owner.editor.input.input=='Saved draft',
    'matching edited-thought draft did not restore')
host,owner,current=fixture();state.draft.operation='edit';state.draft.reference_id='review';owner.id='41'
open_list(host,owner,current);owner.editor.dialog.item_table[1].callback();viewer=owner.editor.dialog
viewer.buttons_table[1][2].callback()
expect(state.opened and state.opened.variant=='thoughts' and state.opened.options.resume_draft.operation=='edit',
    'cross-book edit draft opened the wrong notes list')
host,owner,current=fixture();owner.thoughts=true;owner.value={reviews={}}
open_list(host,owner,current);owner.editor.dialog.item_table[1].callback();viewer=owner.editor.dialog
viewer.buttons_table[1][2].callback()
expect(state.opened and state.opened.id=='42' and state.opened.variant==nil,
    'same-book mark draft could not switch from the thoughts list')
host,owner,current=fixture();expect(open_list(host,owner,current))
local stale_row=owner.editor.dialog.item_table[1];state.draft.token='v2'
stale_row.callback()
expect(not owner.editor and state.draft_reads==1 and state.message:find('draft changed',1,true),
    'changing a draft after listing opened the newer body using stale controls')
host,owner,current=fixture();expect(Editor.drafts(host,owner,current))
local old_complete,old_result=state.complete,state.task()
UI.notice()
local loading=owner.editor.dialog
expect(loading.title=='Loading local thought drafts…','slow list did not offer a cancellable notice')
UI:close(loading)
expect(not owner.editor and state.cancelled and not UI.notice,'closing the notice did not cancel the draft list')
expect(open_list(host,owner,current));local reopened=owner.editor.dialog
old_complete(old_result)
expect(owner.editor.dialog==reopened,'old list result replaced a newer list')
host,owner,current=fixture();state.worker_failed=true
expect(not Editor.drafts(host,owner,current) and not owner.editor and not UI.notice
    and state.message=='Could not load local thought drafts.','failed list worker left a stale notice or context')
host,owner,current=fixture();expect(Editor.drafts(host,owner,current))
local replacement_popup={};owner.menu._shelf_popup=replacement_popup
state.complete(state.task())
expect(not owner.editor and owner.menu._shelf_popup==replacement_popup and not UI.notice,'draft list replaced a newer popup')
host,owner,current=fixture();state.draft=nil;state.require_lease=true
host.settings.data_dir='/synthetic';owner.source_file='/synthetic/native-reader-v1/chapter.epub';owner.scope.vid='123'
local source={book_id='42',chapter_uid='7',raw_sha256=string.rep('a',64)}
local row={selection=true,source=source,bookmarkId='selection',hash='source'}
local entry={book_id='42',chapter_uid='7',source_sha256=source.raw_sha256,file_id=string.rep('b',64)}
package.loaded['weread.lib.native_direct_cache']={acquire=function()
    if state.lease_held or state.busy then return nil end
    state.lease_held=true
    return {owns=function() return state.lease_held end,release=function() state.lease_held=false end}
end,identify=function(_,vid,file,live)
    assert(vid=='123' and file==(state.pin_path or owner.source_file) and live());if state.bad_entry then return nil end;return entry
end}
state.busy=true
expect(not Editor.start(host,owner,'create',row,current) and not owner.editor and not state.lease_held,
    'busy chapter opened a draft editor')
state.busy=false;state.bad_entry=true
expect(Editor.start(host,owner,'create',row,current) and owner.editor and not owner.editor.input,
    'chapter check blocked or skipped the pending state')
state.complete(state.task())
expect(not owner.editor and not state.lease_held,'missing chapter opened editor or leaked its lease')
state.bad_entry=false
expect(Editor.start(host,owner,'create',row,current) and state.lease_held and not owner.editor.input,
    'chapter was not protected while checked in background')
state.complete(state.task());expect(owner.editor and owner.editor.input,'verified chapter did not open editor')
owner.editor.input.input='Protected draft';owner.editor.input.buttons[1][1].callback()
expect(not owner.editor and not state.lease_held and state.save_expected==false,
    'draft did not commit before releasing its chapter lease')
state.draft=nil
expect(Editor.start(host,owner,'create',row,current) and state.lease_held,'second draft editor did not acquire lease')
state.complete(state.task());expect(owner.editor and owner.editor.input,'second verified chapter did not open editor')
owner.editor.input.input='Cancelled draft';Editor.cancel(host,owner)
expect(not owner.editor and not state.lease_held and state.save_expected==false,
    'cancel did not save before releasing its chapter lease')
state.draft=nil;owner.direct_entry={file_id='different'}
expect(Editor.start(host,owner,'create',row,current),'changed chapter check did not start')
state.complete(state.task())
expect(not owner.editor and not state.lease_held,'changed chapter identity opened editor or leaked its lease')
owner.direct_entry=nil
expect(Editor.start(host,owner,'create',row,current) and state.lease_held,'cancellable chapter check did not start')
local late=state.complete;Editor.cancel(host,owner)
expect(not owner.editor and not state.lease_held and state.cancelled,'cancel did not stop check and release lease')
late({entry=entry});expect(not owner.editor and not state.lease_held,'late chapter result reopened editor')
state.worker_failed=true
expect(not Editor.start(host,owner,'create',row,current) and not owner.editor and not state.lease_held,
    'failed source worker leaked its chapter lease')
state.worker_failed=false
state.worker_throws=true
expect(not Editor.start(host,owner,'create',row,current) and not owner.editor and not state.lease_held,
    'throwing source worker leaked its chapter lease')
state.worker_throws=false
expect(Editor.start(host,owner,'create',row,current) and state.lease_held,'stale account check did not start')
late=state.complete;host.owner={};late({entry=entry})
expect(not owner.editor and not state.lease_held,'stale account left source check or lease active')
host.owner=owner;state.draft={draft_key='draft',token='v1',book_id='42',operation='create',
    reference_id='selection',base_hash='source',content='Earlier draft'}
local saved_draft=copy(state.draft)
expect(Editor.start(host,owner,'create',row,current,nil,saved_draft),'draft recheck did not start')
state.draft.token='v2';state.complete(state.task())
expect(not owner.editor and not state.lease_held and state.message:find('draft changed',1,true),
    'replacement during chapter check opened an older draft')
do
    package.loaded['weread.lib.native_read_access']={matches=function() return true end}
    package.loaded['weread.lib.source_currentness']={matches=function() return true end}
    package.loaded['weread.lib.native_direct_reference']={
        restore_cached=function(_,_,_,_,_,_,_,is_current)
            assert(is_current())
            if state.missing then return nil,state.missing end
            return row
        end,
        restore=function()
            assert(state.background and state.network_checks==1)
            state.remote_checked=true;return row
        end,
        restore_downloaded=function(_,_,account_scope,id,ref)
            assert(account_scope==owner.scope and id=='42' and ref=='selection')
            state.downloaded_checked=true
            return state.downloaded_reference,state.downloaded_source
        end,
    }
    for _,case in ipairs({{'cached'}, {'offline_source_unavailable',true},
        {'offline_source_unavailable',false}, {'source_changed',true}}) do
        host,owner,current=fixture();owner.direct=true;owner.direct_entry=entry;owner.value=nil
        state.draft.reference_id='selection';state.draft.base_hash='source';state.network_checks=0
        if case[1]~='cached' then state.missing=case[1] end
        function host:isNetworkOnline()
            assert(state.background,'draft restore probed the network on the interface thread')
            state.network_checks=state.network_checks+1;return case[2]
        end
        expect(Editor.resume(host,owner,'draft','v1',current) and state.network_checks==0,'resume blocked on network state')
        state.background=true;local result=state.task();state.background=false
        state.complete(result)
        local fallback=case[1]=='offline_source_unavailable'
        local opened=owner.editor and owner.editor.input
        expect(state.network_checks==(fallback and 1 or 0) and (state.remote_checked==true)==(fallback and case[2] or false),
            'incorrect fallback for '..case[1])
        expect((opened~=nil)==(case[1]=='cached' or fallback and case[2]),
            'incorrect restore result for '..case[1])
    end
    host,owner,current=fixture();state.draft.reference_id='selection';state.draft.base_hash='source'
    state.worker_throws=true
    expect(not Editor.resume(host,owner,'draft','v1',current) and not owner.editor and state.cancelled
        and state.message:find('draft is kept',1,true),'worker failure did not leave the draft available')
    for _,file_id in ipairs({entry.file_id,string.rep('c',64)}) do
        host,owner,current=fixture();owner.value=nil;owner.scope.vid='123'
        host.settings.data_dir='/synthetic'
        host.settings.get_book=function() end
        state.draft.reference_id='selection';state.draft.base_hash='source'
        state.downloaded_reference=row
        state.downloaded_source={path='/synthetic/native-reader-v1/chapter.epub',file_id=file_id}
        state.pin_path=state.downloaded_source.path
        owner.source_file='/unrelated'
        expect(Editor.resume(host,owner,'draft','v1',current),'downloaded draft did not start a source check')
        state.complete(state.task())
        expect(state.downloaded_checked and state.lease_held and not owner.editor.input,'downloaded draft did not pin its chapter')
        state.complete(state.task())
        if file_id==entry.file_id then
            expect(owner.editor.input.input=='Saved draft' and owner.editor.source_file==state.downloaded_source.path,
                'resumed draft did not use its verified download')
            Editor.cancel(host,owner)
        else expect(not owner.editor and not state.lease_held,'replaced download opened an editor') end
    end
end
print('thought_draft_resume_spec: '..checks..' checks')
