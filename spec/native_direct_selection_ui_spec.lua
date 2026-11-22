package.path='./?.lua;'..package.path
local pending={};local tasks={};local scope={vid='123',epoch=1};local native={};local web={web={cookies={wr_vid='123'}}}
package.preload['ui/uimanager']=function() return {scheduleIn=function(_,_,task) tasks[#tasks+1]=task end,
    unschedule=function() end,close=function() end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(v) return v end} end
package.preload['weread.lib.source_context']=function() return {location=function() return {page=1} end,
    same_location=function(a,b) return a and b and a.page==b.page end} end
package.preload['weread.lib.book_file_identity']=function() return {PATH='identity',decode=function() return {book_id='42'} end} end
package.preload['weread.lib.native_read_access']=function() return {capture=function() return native end,matches=function() return true end} end
package.preload['weread.lib.source_currentness']=function() return {capture=function() return web end,matches=function() return true end} end
package.preload['weread.lib.my_cloud_marks']=function() return {id=function(id) return id end,display_id=function(id) return id end} end
package.preload['weread.lib.selection_reference']=function() return {} end
package.preload['weread.ui.thought_editor']=function() return {cancel=function() end} end
package.preload['weread.ui.mark_editor']=function() return {cancel=function() end} end
package.preload['weread.ui.shelf_popup']=function() return {close=function() end} end
package.preload['weread.lib.memory_worker']=function() return {new=function() return {
    start=function(_,_,callback) pending[#pending+1]=callback;return true end,cancel=function() end} end} end
local Selection=require('weread.ui.selection_thought')
local document={file='/synthetic/native-reader-v1/chapter.epub',getDocumentFileContent=function() return 'identity' end}
local host={ui={document=document,view={view_mode='page'}},_reader_session_gen=1,discovery_epoch=1,client={},
    settings={data_dir='/synthetic',get_auth_scope=function() return scope end,auth_scope_matches=function(_,value) return value==scope end},
    library_db={accountKey=function() return 'account' end},detectWeReadBook=function() return nil end,
    showList=function() return {} end,showInfo=function() error('unexpected information dialog') end}
local chosen={text='Synthetic selection',pos0='/a',pos1='/b'}
assert(Selection.open(host,chosen));local first=assert(host._selection_thought_owner)
assert(Selection.open(host,chosen));local second=assert(host._selection_thought_owner)
assert(first~=second and #pending==2,'new selection did not replace the old owner')
pending[1]({entry={book_id='42'}})
assert(host._selection_thought_owner==second and not second.menu._shelf_closed,
    'late identity result cancelled the newer native selection')
Selection.cancel(host);pending[2]({entry={book_id='42'}})
assert(not host._selection_thought_owner,'late cancelled selection reopened a menu')
print('PASS: late native chapter identity results cannot cancel a newer selection')
