package.path='./?.lua;'..package.path
local state
package.preload['ui/uimanager']=function() return {show=function() end,close=function() end,nextTick=function(_self,fn) fn() end} end
package.preload['ui/widget/confirmbox']=function() return {new=function(_self,value) return value end} end
package.preload['ui/widget/pathchooser']=function() return {new=function(_self,value) return value end} end
package.preload['ffi/util']=function() return {template=function(text,value) return (text:gsub('%%1',value)) end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(text) return text end} end
package.preload['weread.lib.personal_upload']=function() return {
    accepts_name=function(name) return type(name)=='string' and name:lower():match('%.pdf$')~=nil end,
    capture=function(path) if not state.invalid then return {path=path,name='selected.pdf'} end end,
} end
package.preload['weread.lib.personal_original']=function() return {remember=function(_host,id,input)
    state.writes=state.writes+1;state.link={id=id,path=input.path};return not state.fail_save end,
    forget=function(_host,id,expected)
        if state.changed_link or id~='CB_old' or expected~=state.expected then return false end
        state.removed=true;return true
    end} end
local M=require('weread.ui.personal_original')
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local function fixture()
    state={account='one',writes=0};local view={};local book={book_id='CB_old'}
    local host={_reader_session_gen=1,discovery_epoch=1,_book_detail_view=view,ui={file_chooser={path='/books'},document={file='first.epub'}},
        library_db={accountKey=function() return state.account end},showInfo=function(_self,text) state.notice=text end,
        showBookMenu=function(self,selected) state.refreshed=selected;self._book_detail_view={} end}
    return host,book,view
end
local host,book,view=fixture();expect(M.start(host,book,view),'chooser did not open')
local chooser=host._personal_original_attach.chooser
expect(chooser.file_filter('book.PDF') and not chooser.file_filter('book.txt'),'PDF-only filter incorrect')
chooser.onConfirm('/books/selected.pdf');local dialog=host._personal_original_attach.dialog
expect(dialog.text:find('cannot verify',1,true) and dialog.text:find('does not sync',1,true),'manual association lacks matching and sync guidance')
dialog.ok_callback();expect(state.writes==1 and state.link.id=='CB_old' and state.refreshed==book and state.notice:find('will not sync',1,true),'confirmed local association failed')
host,book,view=fixture();M.start(host,book,view);host._personal_original_attach.chooser.onConfirm('/books/a.pdf')
host._personal_original_attach.dialog.cancel_callback();expect(state.writes==0 and not host._personal_original_attach,'cancel wrote association')
for _,change in ipairs({'account','session','epoch','document','file','view','cancel'}) do
    host,book,view=fixture();M.start(host,book,view);host._personal_original_attach.chooser.onConfirm('/books/a.pdf')
    local stale=host._personal_original_attach.dialog
    if change=='account' then state.account='two' elseif change=='session' then host._reader_session_gen=2
    elseif change=='epoch' then host.discovery_epoch=2 elseif change=='document' then host.ui.document={}
    elseif change=='file' then host.ui.document.file='other.epub'
    elseif change=='view' then host._book_detail_view={} else M.cancel(host) end
    stale.ok_callback();expect(state.writes==0 and not state.refreshed,'stale association saved: '..change)
end
host,book,view=fixture();state.invalid=true;M.start(host,book,view);host._personal_original_attach.chooser.onConfirm('/books/a.pdf')
expect(state.writes==0 and not host._personal_original_attach and state.notice:find('Could not use',1,true),'invalid file accepted')
host,book,view=fixture();state.fail_save=true;M.start(host,book,view);host._personal_original_attach.chooser.onConfirm('/books/a.pdf')
host._personal_original_attach.dialog.ok_callback();expect(not state.refreshed and state.notice:find('Could not link',1,true),'failed save claimed success')
host,book,view=fixture();state.expected={path='/books/a.pdf'}
expect(M.forget(host,book,view,state.expected),'unlink confirmation did not open')
local unlink=host._personal_original_attach.dialog
expect(unlink.text:find('original file and cloud book are kept',1,true),'unlink did not describe preserved files')
unlink.cancel_callback();expect(not state.removed and not host._personal_original_attach,'cancel unlinked')
host,book,view=fixture();state.expected={path='/books/a.pdf'};M.forget(host,book,view,state.expected)
state.changed_link=true;host._personal_original_attach.dialog.ok_callback()
expect(not state.removed and state.notice:find('changed',1,true),'changed association was unlinked')
host,book,view=fixture();state.expected={path='/books/a.pdf'};M.forget(host,book,view,state.expected)
state.account='two';host._personal_original_attach.dialog.ok_callback();expect(not state.removed,'stale account unlinked association')
host,book,view=fixture();state.expected={path='/books/a.pdf'};M.forget(host,book,view,state.expected)
host._personal_original_attach.dialog.ok_callback();expect(state.removed and state.refreshed==book,'confirmed unlink did not refresh')
print('PASS: manual local PDF association UI ('..checks..' checks)')
