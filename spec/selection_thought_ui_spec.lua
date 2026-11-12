package.path='./?.lua;'..package.path
local queued={};local cancelled,closed,cleared=0,0,0
package.preload['ui/uimanager']=function() return {
    scheduleIn=function(_self,delay,callback) assert(delay>=.1);queued[#queued+1]=callback end,
    unschedule=function(_self,task) for i=#queued,1,-1 do if queued[i]==task then table.remove(queued,i) end end end,
    close=function() closed=closed+1 end,
} end
package.preload['weread.ui.thought_editor']=function() return {cancel=function() cancelled=cancelled+1 end} end
package.preload['weread.lib.selection_reference']=function() return {} end
package.preload['weread.ui.shelf_popup']=function() return {close=function() end} end
package.preload['weread.lib.my_cloud_marks']=function() return {id=function(v) return type(v)=='string' and v:match('^[1-9]%d*$') and v or nil end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(v) return v end} end
package.preload['weread.lib.source_context']=function() return {
    location=function(document) return document.location end,
    same_location=function(a,b) return a and b and a.point==b.point end,
} end
local Selection=require('weread.ui.selection_thought')
local checks=0;local function expect(v,label) checks=checks+1;assert(v,label) end
local document={file='/synthetic.epub',location={point='a'}}
local account,valid='account-a',true
local highlight={_highlight_buttons={},onClose=function() cleared=cleared+1 end}
function highlight:addToHighlightDialog(key,factory) self._highlight_buttons[key]=factory end
function highlight:removeFromHighlightDialog(key) self._highlight_buttons[key]=nil end
local host={ui={document=document,highlight=highlight},_current_weread_book_id='41',_reader_session_gen=1,discovery_epoch=2,
    library_db={accountKey=function() return account end},settings={get_auth_scope=function() return {vid='900000',epoch=1} end,
        auth_scope_matches=function() return valid end}}
local opens=0
Selection.open=function(self,selected) expect(self==host and selected.text=='Selected text','wrong selection snapshot');opens=opens+1 end
local function selected()
    highlight.selected_text={text='Selected text',pos0='/start',pos1='/end'}
    return highlight._highlight_buttons[Selection.KEY](highlight)
end
local function run() local tasks=queued;queued={};for _i,callback in ipairs(tasks) do callback() end end
expect(Selection.attach(host),'supported highlight API not attached')
local button=selected();expect(button.show_in_highlight_dialog_func(),'ordinary selection hidden')
highlight.select_mode=true;expect(not button.show_in_highlight_dialog_func(),'unfinished native select mode exposed');highlight.select_mode=false
host._translation_mode='translation';expect(not button.show_in_highlight_dialog_func(),'translation text exposed');host._translation_mode='original'
account=nil;expect(not button.show_in_highlight_dialog_func(),'logged-out source action exposed');account='account-a'
button.callback();expect(not highlight.selected_text and opens==0,'saved-highlight transient selection not consumed cooperatively')
run();expect(opens==1,'normal delayed selection did not open')
for _i,kind in ipairs({'document','session','epoch','account','scope'}) do
    button=selected();button.callback()
    if kind=='document' then host.ui.document={file='/other.epub'} elseif kind=='session' then host._reader_session_gen=2
    elseif kind=='epoch' then host.discovery_epoch=3 elseif kind=='account' then account='account-b' else valid=false end
    run();expect(opens==1,'old delayed callback survived '..kind)
    host.ui.document=document;host._reader_session_gen=1;host.discovery_epoch=2;account='account-a';valid=true
end
button=selected();local before=cleared;Selection.detach(host);button.callback();run()
expect(cleared==before and opens==1 and not highlight._highlight_buttons[Selection.KEY],'detached button remained active')
expect(Selection.attach(host),'could not reattach')
local external=function() end;highlight._highlight_buttons[Selection.KEY]=external;Selection.detach(host)
expect(highlight._highlight_buttons[Selection.KEY]==external,'teardown removed another callback')
local worker_stops=0
local owner={document=document,source_file=document.file,account=account,session=1,epoch=2,scope={},mode='page',
    location={point='a'},menu={},worker={cancel=function() worker_stops=worker_stops+1 end}}
host._selection_thought_owner=owner;Selection.view_changed(host)
expect(host._selection_thought_owner==owner,'same viewport cancelled owner')
document.location={point='b'};Selection.view_changed(host)
expect(not host._selection_thought_owner and owner.menu._shelf_closed and worker_stops==1 and cancelled==1 and closed==1,
    'viewport change did not close owner and stop worker')
Selection.cancel(host);expect(worker_stops==1 and cancelled==1,'duplicate cancellation repeated work')
expect(not Selection.attach{ui={highlight={}}},'unsupported host modified')
print('selection_thought_ui_spec: '..checks..' checks')
