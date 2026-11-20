-- Focused navigation, cancellation and stale callback tests with native event fakes.
package.path='./?.lua;'..package.path
local shown,tasks,removed=nil,{},{}
package.preload['ui/uimanager']=function() return {
    show=function(_,view) shown=view end,
    close=function(_,view) if view.onCloseWidget then view:onCloseWidget() end end,
    scheduleIn=function(_,_,fn) tasks[#tasks+1]=fn end,
    unschedule=function(_,fn) removed[fn]=true end,
} end
package.preload['ui/widget/buttondialog']=function() return {new=function(_,args)
    function args:getAddedWidgetAvailableWidth() return 200 end
    function args:addWidget(widget) self.widget=widget end
    return args
end} end
package.preload['device']=function() return {screen={scaleBySize=function(_,value) return value end}} end
package.preload['ui/event']=function() return {new=function(_,name,value) return {name=name,value=value} end} end
package.preload['ui/geometry']=function() return {new=function(_,args) return args end} end
package.preload['ui/gesturerange']=function() return {new=function(_,args) return args end} end
package.preload['ui/widget/container/inputcontainer']=function() return {extend=function(_,args)
    args.__index=args
    function args:new(values) setmetatable(values,self);if values.init then values:init() end;return values end
    return args
end} end
package.preload['ui/widget/progresswidget']=function() return {new=function(_,args)
    function args:paintTo() end;return args
end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(text) return text end,
    T=function(text,...) for i=1,select('#',...) do text=text:gsub('%%'..i,tostring(select(i,...))) end;return text end} end
local Progress=require('weread.ui.reader_progress')
local page,pos,account=2,100,'one'
local doc={file='chapter.epub',getPageCount=function() return 10 end,getCurrentPos=function() return pos end}
local events,history,input={},0,0
local ui={document=doc,view={view_mode='page'},getCurrentPage=function() return page end,
    handleEvent=function(_,event) events[#events+1]=event end,
    link={addCurrentLocationToStack=function() history=history+1 end},
    gotopage={onShowGotoDialog=function() input=input+1 end}}
local host={ui=ui,_reader_session_gen=1,library_db={accountKey=function() return account end}}
local prev,next_chapter={chapterUid='1'},{chapterUid='3'}
local opened
function host:openChapter(book,chapter) opened={book=book,chapter=chapter} end
local book={}
local opts={single_chapter=true,book=book,previous=prev,next=next_chapter,is_current=function() return true end,
    resolve_chapter=function(direction) return book,direction<0 and prev or next_chapter end}
local function button(id)
    for _,row in ipairs(shown.buttons) do for _,item in ipairs(row) do if item.id==id then return item end end end
    error('missing button '..id)
end
assert(Progress.show(host,opts));assert(shown.title:find('Current chapter file',1,true))
local panel=host._weread_reader_progress
panel.bar:paintTo(nil,10,30)
panel.bar:onTapSelect(nil,{pos={x=110}})
assert(#tasks==1 and #events==0 and not panel.dialog)
tasks[1]();assert(#events==1 and events[1].name=='GotoPercent' and events[1].value==50 and history==1)
assert(not host._weread_reader_progress)
assert(Progress.show(host,opts));local stale=button('progress_next_chapter').callback
local existing=host._weread_reader_progress
assert(not Progress.show(host,{is_current=function() return false end}) and host._weread_reader_progress==existing,
    'stale open closed a newer panel')
assert(Progress.show(host,opts));local active=host._weread_reader_progress
stale();assert(host._weread_reader_progress==active,'stale action closed a newer panel')
button('progress_next_chapter').callback();assert(#tasks==2);tasks[2]()
assert(opened.book==book and opened.chapter==next_chapter)
assert(Progress.show(host,opts));button('progress_previous_chapter').callback()
account='two';tasks[3]();account='one';assert(opened.chapter==next_chapter,'account switch opened old chapter')
assert(Progress.show(host,opts));button('progress_input').callback();Progress.cancel(host)
assert(removed[tasks[4]]);tasks[4]();assert(input==0,'canceled input dialog opened')
assert(Progress.show(host,opts));button('progress_input').callback();tasks[5]();assert(input==1)
assert(Progress.show(host,opts));button('progress_forward_10').callback();page=3;tasks[6]();page=2
assert(#events==1,'changed page accepted a stale progress jump')
assert(Progress.show(host,opts));local previous=shown;Progress.cancel(host)
assert(not host._weread_reader_progress and not previous.widget.callback(75))
assert(#events==1,'canceled progress bar dispatched an event')
ui.toc={getPreviousChapter=function() return 1 end,getNextChapter=function() return 5 end}
assert(Progress.show(host,{native_chapters=true}));assert(shown.title:find('Current file',1,true))
button('progress_next_chapter').callback();tasks[7]()
assert(events[2].name=='GotoNextChapter','full-file chapter navigation bypassed the native reader')
assert(Progress.show(host,opts));button('progress_back_10').callback();tasks[8]()
assert(events[3].name=='GotoPercent' and events[3].value==10 and history==2,'relative progress control was incorrect')
assert(Progress.show(host,opts));local dismissed=shown;dismissed:onCloseWidget()
assert(not host._weread_reader_progress,'dismissed panel retained its owner')
local open_chapter=host.openChapter;host.openChapter=nil
assert(Progress.show(host,opts))
assert(button('progress_previous_chapter').enabled==false and button('progress_next_chapter').enabled==false,
    'missing chapter controller left buttons enabled')
Progress.cancel(host);host.openChapter=open_chapter
local info
function host:showInfo(value) info=value end
local dialog_class=require('ui/widget/buttondialog');local original_new=dialog_class.new
dialog_class.new=function() error('synthetic construction failure') end
assert(not Progress.show(host,opts) and not host._weread_reader_progress and info=='Could not open reading progress.')
dialog_class.new=original_new
local manager=require('ui/uimanager');local original_show=manager.show
manager.show=function() error('synthetic show failure') end;info=nil
assert(not Progress.show(host,opts) and not host._weread_reader_progress and info=='Could not open reading progress.')
manager.show=original_show
local saved_document=host.ui.document;host.ui.document=nil;info=nil
assert(not Progress.show(host,opts) and info=='Reading progress is unavailable for this file.')
host.ui.document=saved_document
print('reader_progress_ui_spec: native events, chapter navigation and cancellation passed')
