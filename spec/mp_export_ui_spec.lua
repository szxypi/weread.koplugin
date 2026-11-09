package.path='./?.lua;'..package.path
package.preload['ui/uimanager']=function() return {show=function() end,close=function(_self,widget) if widget.onCloseWidget then widget:onCloseWidget() end end} end
package.preload['ui/widget/confirmbox']=function() return {new=function(_self,value) return value end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(text) return text end,T=function(text,...)
    local args={...};return (text:gsub('%%(%d+)',function(index) return tostring(args[tonumber(index)]) end)) end} end
local state
package.preload['weread.lib.content']=function() return {mp_article_cached_path=function(_settings,book,article)
    if state.uncached then return nil end
    return (book.cache_dir or '/cache')..'/'..article.title..'.html'
end} end
package.preload['libs/libkoreader-lfs']=function() return {
    symlinkattributes=function() return state.source_invalid and {mode='link'} or {mode='file',dev=1,ino=2,size=30,modification=4} end,
    attributes=function(_path,key) if key=='size' then return 200 end end} end
local Model=require('weread.lib.mp_export')
Model.write=function(input,output)
    state.input=input
    if state.write_error then error('private body/path error') end
    output.bytes=200
    return {ok=true,bytes=200,images=2,missing=1,copied=false}
end
local Export=require('weread.ui.mp_export')
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local function fixture()
    state={account='one',jobs={},outputs={},aborts=0,notices={}}
    local host={settings={data_dir='/local',get=function() return state.books or {} end},discovery_epoch=0,_reader_session_gen=1,
        library_db={accountKey=function() return state.account end},client={},ui={document={file='/cache/Test.html'}},
        showInfo=function(_self,value) state.notices[#state.notices+1]=value end,
        showBusy=function(self,_text,cancel) self.busy_message={};state.dismiss=cancel end,
        closeBusy=function(self) self.busy_message=nil end,
        closeWeReadUI=function(self) Export.cancel(self);self.discovery_epoch=self.discovery_epoch+1 end,
        showList=function(_self,title,rows) return {title=title,item_table=rows} end,
        openFile=function(_self,path) state.opened=path end,
        detectWeReadBook=function() return 'MP_WXS_1' end,
        create_mp_output=function(directory,title,format)
            state.created={directory=directory,title=title,format=format}
            if state.create_failed then return nil end
            local file={path='/local/exports/articles/Test.epub'}
            function file:accept(bytes) if state.accept_error then error('private file') end;return not state.accept_failed and bytes==self.bytes end
            function file:owns() return not state.replaced end
            function file:abort() state.aborts=state.aborts+1;self.path=nil end
            state.outputs[#state.outputs+1]=file;return file
        end,
        mp_export_worker={start=function(_self,task,callback)
            if state.start_error then error('private error') end
            if state.start_failed then return false end
            state.jobs[#state.jobs+1]={task=task,callback=callback};return true
        end,cancel=function() state.worker_cancelled=true end}}
    local book={book_id='MP_WXS_1',title='Channel',cache_dir='/moved'}
    local article={title='Test',reviewId='review',private='excluded'}
    local function deliver(index,result)
        local job=state.jobs[index or #state.jobs];job.callback(result or job.task())
    end
    return host,book,article,deliver
end
local host,book,article,deliver=fixture()
expect(Export.start(host,book,article) and state.created.format=='epub' and state.created.directory=='/local/exports/articles','offline export did not start')
book.title='Changed';article.title='Changed';deliver()
expect(state.input.book.title=='Channel' and state.input.article.title=='Test' and not state.input.article.private,'metadata snapshot leaked or mutated')
expect(not host.mp_export_job and not host.busy_message and state.aborts==0 and host._mp_export_result,'successful output discarded')
expect(host._mp_export_result.text:find('Included images: 2',1,true) and host._mp_export_result.text:find('Images unavailable: 1',1,true),'missing image count not shown')
host._mp_export_result.ok_callback();expect(state.opened==state.outputs[1].path,'accepted export did not open')
for _,change in ipairs({'account','epoch','session','document','file','timeout','clock'}) do
    host,book,article,deliver=fixture();Export.start(host,book,article)
    if change=='account' then state.account='two'
    elseif change=='epoch' then host.discovery_epoch=1
    elseif change=='session' then host._reader_session_gen=2
    elseif change=='document' then host.ui.document={file='/cache/Test.html'}
    elseif change=='file' then host.ui.document.file='/other'
    elseif change=='timeout' then host.mp_export_job.started=os.time()-121
    else host.mp_export_job.started=os.time()+2 end
    deliver();expect(state.aborts==1 and not host._mp_export_result and #state.notices==0,change..' accepted stale output')
end
host,book,article,deliver=fixture();Export.start(host,book,article);state.dismiss()
expect(state.aborts==1 and not host.mp_export_job,'dismiss retained incomplete file')
Export.start(host,book,article);local busy=host.busy_message;deliver(1)
expect(host.mp_export_job and host.busy_message==busy,'old callback cancelled new job')
deliver(2);local old=host._mp_export_result;Export.cancel(host);old.ok_callback()
expect(not state.opened,'closed success dialog opened an export')
for _,failure in ipairs({'create_failed','start_failed','start_error','write_error','accept_failed','accept_error'}) do
    host,book,article,deliver=fixture();state[failure]=true
    if Export.start(host,book,article) then deliver() end
    expect(not host.mp_export_job and not host.busy_message and not host._mp_export_result and #state.notices==1,failure..' retained work')
    expect(not state.notices[1]:find('private',1,true),failure..' leaked raw failure')
end
for _,bad in ipairs({{ok=true,bytes=1.2,images=0,missing=0,copied=false},
    {ok=true,bytes=200,images=-1,missing=0,copied=false},{ok=true,bytes=200,images=0,missing=0},
    {ok=true,bytes=200,images=0,missing=Model.MAX_NODES+1,copied=false}}) do
    host,book,article,deliver=fixture();Export.start(host,book,article);deliver(nil,bad)
    expect(state.aborts==1 and not host._mp_export_result,'invalid worker envelope accepted')
end
host,book,article=fixture();state.uncached=true
expect(not Export.start(host,book,article) and #state.outputs==0,'uncached article created output')
host,book,article=fixture();state.source_invalid=true
expect(not Export.start(host,book,article) and #state.outputs==0,'source symlink exported')
host,book,article=fixture();book.book_id='42'
expect(not Export.start(host,book,article),'ordinary book exported as MP')
host,book,article=fixture();Export.show(host,book,article);local picker=host._mp_export_picker
state.account='two';picker.ok_callback();expect(#state.jobs==0,'stale account picker started export')
Export.show(host,book,article);local closed=host._mp_export_picker;Export.show(host,book,article);closed.ok_callback()
expect(host._mp_export_picker and #state.jobs==0,'old picker replaced current picker')
host,book,article,deliver=fixture();Export.list(host,book,{article});local menu=host._mp_export_menu
menu.item_table[1].callback();host._mp_export_picker.ok_callback();deliver()
expect(state.input.path=='/moved/Test.html','custom cache root was lost by export list')
Export.list(host,book,{article});menu=host._mp_export_menu;menu:onCloseWidget();menu.item_table[1].callback()
expect(not host._mp_export_picker,'closed list callback opened picker')
host,book,article,deliver=fixture();Export.start(host,book,article);deliver();state.replaced=true;host._mp_export_result.ok_callback()
expect(not state.opened and #state.notices==1,'replaced exported file opened')
host,book,article=fixture();book.cache_dir='/cache';book.mp_articles={article};state.books={MP_WXS_1=book}
expect(Export.current(host) and host._mp_export_picker,'current saved article not found')
book.mp_articles={article,article};Export.cancel(host)
expect(not Export.current(host) and not host._mp_export_picker,'ambiguous same-path article accepted')
Export.list(host,book,book.mp_articles)
local ambiguous=host._mp_export_menu
expect(#ambiguous.item_table==2 and ambiguous.item_table[1].select_enabled==false,'ambiguous cache was exportable from picker')
ambiguous.item_table[1].callback();expect(not host._mp_export_picker,'disabled ambiguous row exported')
host,book,article=fixture();Export.show(host,book,article);local dismissed=host._mp_export_picker
dismissed:onCloseWidget();dismissed.ok_callback()
expect(#state.jobs==0 and not host._mp_export_picker,'native-closed picker started export')
host,book,article,deliver=fixture();Export.start(host,book,article);deliver();local stale_result=host._mp_export_result
stale_result:onCloseWidget();stale_result.ok_callback();expect(not state.opened,'native-closed result opened export')
host,book,article,deliver=fixture();Export.start(host,book,article);deliver();state.account='two';host._mp_export_result.ok_callback()
expect(not state.opened and #state.notices==0,'expired result acted on another account')
print('PASS: cached MP export UI ('..checks..' checks)')
