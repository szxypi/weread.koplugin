-- Progress belongs to the native viewport, not a guessed cloud book offset.
package.path='./?.lua;'..package.path
local Context=require('weread.lib.reader_progress_context')
local page,total,pos,mode,account,epoch=2,10,250,'page','account-a',1
local document={file='/synthetic.epub',info={doc_height=1000},getPageCount=function() return total end,
    getCurrentPos=function() return pos end}
local ui={document=document,view={view_mode=mode},getCurrentPage=function() return page end,handleEvent=function() end}
local host={ui=ui,_reader_session_gen=1,library_db={accountKey=function() return account end},
    settings={get_auth_scope=function() return {epoch=epoch} end,
        auth_scope_matches=function(_,scope) return scope.epoch==epoch end}}
local base=assert(Context.capture(host))
assert(base.percent==20 and Context.current(host,base))
pos=251;assert(not Context.current(host,base));pos=250
document.getVisiblePageNumberCount=function() return 2 end
assert(not Context.current(host,base) and Context.capture(host).visible_pages==2,
    'changed page spread accepted an old progress action')
document.getVisiblePageNumberCount=nil
page=3;assert(not Context.current(host,base));page=2
total=11;assert(not Context.current(host,base));total=10
account='account-b';assert(not Context.current(host,base));account='account-a'
epoch=2;assert(not Context.current(host,base));epoch=1
host._reader_session_gen=2;assert(not Context.current(host,base));host._reader_session_gen=1
document.file='/other.epub';assert(not Context.current(host,base));document.file='/synthetic.epub'
ui.view.view_mode='scroll';local scroll=assert(Context.capture(host))
assert(scroll.percent==25 and Context.current(host,scroll))
document.info.doc_height=1200
assert(not Context.current(host,scroll),'changed scroll extent accepted an old progress action')
ui.rolling={};document.info.doc_height=0;assert(not Context.capture(host),'unknown scroll extent was presented as precise progress')
document.info.doc_height=1000;ui.rolling=nil;ui.view.view_mode='page'
assert(not Context.current(host,scroll))
for _,bad in ipairs({0,-1,1/0,10000001,1.5}) do total=bad;assert(not Context.capture(host)) end
total=10;page=11;assert(not Context.capture(host));page=2
local original=host.library_db.accountKey
host.library_db.accountKey=function() error('synthetic account failure') end
assert(not Context.capture(host) and not Context.current(host,base));host.library_db.accountKey=original
host.settings.auth_scope_matches=function() error('synthetic scope failure') end
assert(not Context.current(host,base))
print('reader_progress_context_spec: file scope, viewport, scroll and stale ownership passed')
