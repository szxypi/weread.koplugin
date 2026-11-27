package.path='./?.lua;'..package.path
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local fingerprint=string.rep('a',64)
local digest=string.rep('b',64)
local scope={vid='123',epoch=1}
local initial_access={scope=scope,fingerprint=fingerprint,revision=1,store={},credentials={vid='123'}}
local selected=initial_access
local account_valid=true
local next_tick
package.preload['ui/uimanager']=function() return {show=function() end,
    close=function(_,widget) if widget.onCloseWidget then widget:onCloseWidget() end end,
    nextTick=function(_,callback) next_tick=callback end} end
package.preload['device']=function() return {screen={scaleBySize=function(_,n) return n end}} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(text) return text end,
    T=function(text,...) local args={...};return (text:gsub('%%(%d)',function(i) return args[tonumber(i)] or '' end)) end} end
package.preload['ui/widget/confirmbox']=function() return {new=function(_,value) return value end} end
package.preload['ui/widget/multiconfirmbox']=package.preload['ui/widget/confirmbox']
package.preload['ui/widget/inputdialog']=function()
    return {new=function(_,value) value.getInputText=function(self) return self.input end;return value end}
end
package.preload['weread.ui.download_dialog']=function() return {new=function(_,value)
    value.show=function() end;value.reportProgress=function() end;return value end} end
local Access=require('weread.lib.native_read_access')
Access.capture=function() if account_valid then return selected end end
Access.matches=function(_,value) return account_valid and value==selected end
local renewal_count=0
package.preload['weread.lib.native_read_recovery']=function() return {
    cancel=function() end,
    start=function(_,ctx,old,opts)
        if ctx.recovery_attempted then return false end
        ctx.recovery_attempted=true;renewal_count=renewal_count+1
        selected={scope=scope,fingerprint=string.rep('c',64),revision=old.native.revision+2,
            store=old.native.store,credentials=old.native.credentials}
        opts.complete(true,{native=selected,base_revision=old.base_revision});return true
    end,
} end
local cloud_progress,cloud_error,progress_calls
package.preload['weread.lib.native_authorization']=function() return {new=function(_,_,options) return {
    cancel=function() end,
    _request=function(_,stage,url,body,credentials,timeout)
        assert(stage=='direct_progress' and url=='https://i.weread.qq.com/book/getProgress?bookId=456'
            and body==nil and credentials==selected.credentials and options.is_current() and timeout[2]<=3)
        progress_calls=progress_calls+1
        if cloud_error then error(cloud_error,0) end
        return cloud_progress
    end,
} end} end
local sample={book_id='456',version=7,reading_digest=digest,reading_chapters={
    {chapterUid='1',title='First',chapterIdx=1,downloadable=true},
    {chapterUid='2',title='Locked',chapterIdx=2,downloadable=false},
}}
local catalog_error,build_error
package.preload['weread.lib.native_book_catalog']=function() return {read=function()
    if catalog_error then error(catalog_error,0) end
    return sample
end} end
local expected_book,expected_chapter,expected_args
package.preload['weread.lib.native_direct_reader']=function() return {build=function(_,_,book,chapter,args,options)
    expected_book,expected_chapter,expected_args=book,chapter,args
    expect(options.allow_missing_images and options.is_current(),'missing-image policy or scope incorrect')
    if build_error then return nil,build_error end
    return {path='/tmp/settings/native-reader-v1/account/book/file.epub',book_version=7,
        source_sha256=string.rep('c',64),missing_images=0}
end} end
local UI=require('weread.ui.native_direct_reading')
expect(UI.project(sample,'456')~=nil,'valid catalog rejected')
local function clone() return {book_id='456',version=7,reading_digest=digest,reading_chapters={
    {chapterUid='1',title='One',downloadable=true},{chapterUid='2',title='Two',downloadable=true}}} end
for _,mutate in ipairs({function(v) v.book_id='457' end,function(v) v.reading_digest='bad' end,
    function(v) v.reading_chapters[2].chapterUid='1' end,function(v) v.reading_chapters[1].title='bad\n' end,
    function(v) v.reading_chapters[1].downloadable='yes' end,function(v) v.reading_chapters[1].chapterIdx=-1 end,
    function(v) v.reading_chapters[2].level=101 end,
    function(v) v.reading_chapters[4]={} end}) do
    local bad=clone();mutate(bad);expect(not UI.project(bad,'456'),'invalid catalog accepted')
end
local hierarchy=clone()
hierarchy.reading_chapters[1].level=0
hierarchy.reading_chapters[2].level=3
local projected=assert(UI.project(hierarchy,'456'))
expect(projected.chapters[1].level==0 and projected.chapters[2].level==3 and projected.chapters[2].catalog_order==2,
    'worker projection lost the catalog depth or order')
local function fixture()
    selected=initial_access;account_valid=true;catalog_error=nil;build_error=nil
    cloud_progress=nil;cloud_error=nil;progress_calls=0
    local state={jobs={},opened=0,info=0,view={}}
    local host={_book_detail_view=state.view,discovery_epoch=1,_reader_session_gen=1,ui={},client={},
        settings={data_dir='/tmp/settings',get_auth_scope=function() return scope end,
            auth_scope_matches=function(_,s) return account_valid and s==scope end},
        library_db={accountKey=function() return account_valid and 'owner' or 'other' end},
        isNetworkConnected=function() return true end,
        showBusy=function(self,_,cancel) self.busy_message={};state.cancel=cancel end,
        closeBusy=function(self) self.busy_message=nil end,
        showInfo=function(_,message) state.info=state.info+1;state.message=message end,
        showOffline=function() error('unexpected offline') end,
        showInputDialog=function(_,dialog) state.input=dialog end,
        showList=function(_,title,items,_,options)
            local menu={item_table=items,getPageNumber=function(_,index) return index end,
                onGotoPage=function(_,page) state.page=page end,switchItemTable=function(self,_,rows,index)
                self.item_table=rows;state.items=rows;state.page=index or 1
            end}
            state.title=title;state.items=items;state.subtitle=options.subtitle;state.icon=options.left_icon
            state.select=function(index) options.on_choice(menu.item_table[index]) end
            state.choose=options.on_choice
            return menu
        end,
        openFile=function(_,path,callback) state.opened=state.opened+1;state.path=path;state.handoff=callback end,
        _native_direct_worker={start=function(_,task,callback,progress) state.jobs[#state.jobs+1]={task=task,callback=callback,progress=progress};return true end,
            cancel=function() state.cancelled=true end}}
    function state.finish(index) local job=state.jobs[index];job.callback(job.task()) end
    return host,state
end
local host,s=fixture()
expect(UI.start(host,{book_id='456',title='Test',author='Author'},s.view),'failed to start')
s.finish(1)
expect(#s.items==2 and s.items[1].select_enabled and not s.items[2].select_enabled,'entitlement not shown')
expect(progress_calls==0,'browsing the catalog unnecessarily fetched cloud progress')
expect(s.subtitle=='Online: sync position or save selected highlights and private thoughts.','chapter capability hint missing')
s.select(2);expect(#s.jobs==1,'locked chapter opened')
s.select(1);expect(#s.jobs==2,'chapter not scheduled')
s.finish(2)
expect(s.opened==1 and s.path:find('/native-reader-v1/',1,true),'chapter not opened')
expect(expected_book.book_id=='456' and expected_chapter.chapterUid=='1' and expected_args.reading_catalog_sha256==digest
    and expected_args.access_fingerprint==fingerprint,'source identity not bound')
host,s=fixture()
local reader_path='/tmp/settings/native-reader-v1/current.epub'
host._book_detail_view=nil
host.ui.document={file=reader_path}
expect(UI.start(host,{book_id='456'},host.ui,{from_reader=true}),'reader catalog did not start')
local ready=s.jobs[1].task()
host.ui.document={file=reader_path}
s.jobs[1].callback(ready)
expect(not host._native_direct_reading and not host.busy_message and not s.items,
    'catalog opened over a replacement document at the same path')
host,s=fixture();host._book_detail_view=nil;host.shelf_view=s.view
local shelf_live=true
expect(UI.start(host,{book_id='456'},s.view,{shelf_current=function() return shelf_live end}),
    'shelf could not start native chapter selection')
s.finish(1);expect(s.items and host._native_direct_reading.shelf_owner==s.view,'catalog lost its bookshelf owner')
s.select(1);ready=s.jobs[2].task();shelf_live=false;s.jobs[2].callback(ready)
expect(s.opened==0 and not host._native_direct_reading,'stale bookshelf opened a prepared chapter')
host,s=fixture();UI.start(host,{book_id='456'},s.view);s.finish(1)
local menu=assert(host._native_direct_reading.menu)
expect(s.icon=='appbar.search','native catalog has no search entry')
local old_item=s.items[1]
menu:onLeftButtonTap();s.input.input='　LOCKED　';s.input.buttons[1][2].callback()
expect(#s.items==1 and s.items[1].chapter_index==2 and not s.items[1].select_enabled,
    'filter did not preserve unavailable chapter identity')
s.select(1);s.choose(old_item)
expect(#s.jobs==1,'unavailable or stale result started a download')
menu:onLeftButtonTap();s.input.input='missing';s.input.buttons[1][2].callback()
expect(s.items[1].text=='No matching chapters.' and not s.items[1].select_enabled,'empty filter result was not shown')
menu:onLeftButtonTap();s.input.buttons[1][1].callback()
expect(#s.items==2 and #s.jobs==1,'clearing filter reloaded the catalog')
menu:onLeftButtonTap();local stale_search=s.input
UI.cancel(host)
stale_search.input='First';stale_search.buttons[1][2].callback()
expect(not menu._shelf_popup and #s.items==2 and #s.jobs==1,'closed native catalog accepted search submit')
sample.reading_chapters[2].title='First'
host,s=fixture();UI.start(host,{book_id='456'},s.view);s.finish(1)
host._native_direct_reading.menu:onLeftButtonTap();s.input.input='First';s.input.buttons[1][2].callback()
expect(#s.items==2 and s.items[1].text=='1. First' and s.items[2].text=='2. First  ·  Unavailable'
    and not s.items[2].select_enabled,'duplicate titles lost the catalog position or access hint')
sample.reading_chapters[2].title='Locked'
local anchor={book_id='456',owner=require('weread.lib.crypto').sha256_hex('native-direct-account\0'..scope.vid),
    chapter_uid='2',title='Locked',book_version=7,missing_images=0,text_digest=digest,source_sha256=digest,
    key=fingerprint,copy=0}
local function marked(item) return item.text:find('Current chapter · ',1,true)==1 end
host,s=fixture();expect(UI.start(host,{book_id='456'},s.view,{anchor=anchor}),'current chapter catalog failed')
s.finish(1)
expect(s.page==2 and marked(s.items[2]) and not s.items[2].select_enabled
    and not marked(s.items[1]),'catalog did not locate and mark the current chapter')
menu=host._native_direct_reading.menu
menu:onLeftButtonTap();s.input.input='First';s.input.buttons[1][2].callback()
expect(s.page==1 and #s.items==1 and not marked(s.items[1]),'title search did not start at its first match')
menu:onLeftButtonTap();s.input.buttons[1][1].callback()
expect(s.page==2 and marked(s.items[2]) and #s.jobs==1,'clearing search did not return to the current chapter')
local function cloud_marked(item) return item.text:find('Cloud reading chapter · ',1,true)==1 end
host,s=fixture();cloud_progress={book={bookId='456',chapterUid=2,chapterIdx=2,progress=0}}
expect(UI.start(host,{book_id='456'},s.view,{cloud_chapter=true}),'cloud chapter catalog failed')
s.finish(1)
expect(progress_calls==1 and s.page==2 and cloud_marked(s.items[2]) and not s.items[2].select_enabled
    and not cloud_marked(s.items[1]) and #s.jobs==1,'cloud hint did not respect chapter identity or entitlement')
menu=host._native_direct_reading.menu
menu:onLeftButtonTap();s.input.input='First';s.input.buttons[1][2].callback()
menu:onLeftButtonTap();s.input.buttons[1][1].callback()
expect(s.page==2 and cloud_marked(s.items[2]) and progress_calls==1,'clearing search lost the cloud chapter')
for _,point in ipairs({{bookId='457',chapterUid=2,progress=10},
    {bookId='456',chapterUid=2,chapterIdx=1,progress=10},
    {bookId='456',chapterUid=0,progress=0},
    {bookId='456',chapterUid=3,chapterIdx=2,progress=10},false}) do
    host,s=fixture();cloud_progress=point and {book=point};cloud_error=not point and 'native_auth/direct_progress/http_401'
    expect(UI.start(host,{book_id='456'},s.view,{cloud_chapter=true}),'catalog required a cloud hint')
    s.finish(1)
    expect(progress_calls==1 and not s.page and not cloud_marked(s.items[2]) and #s.jobs==1 and s.info==0,
        'unverified cloud progress changed the normal catalog')
end
local function start_exact()
    local exact_host,exact=fixture()
    cloud_progress={book={bookId='456',chapterUid=1,chapterIdx=1,chapterOffset=40,progress=10,summary='A unique later passage'}}
    expect(UI.start(exact_host,{book_id='456'},exact.view,{cloud_chapter=true}),'exact cloud reading did not start')
    exact.finish(1)
    expect(#exact.jobs==2 and not exact.items and not exact_host._native_direct_reading.menu,
        'exact cloud continuation required an extra chapter selection')
    return exact_host,exact
end
host,s=start_exact();s.finish(2)
expect(s.opened==1 and type(s.handoff)=='function' and expected_chapter.chapterUid=='1' and not s.items,
    'verified cloud chapter did not open with its text target')
expect(not host._native_direct_reading,'completed direct continuation left its selector active')
host,s=start_exact();build_error='service_rejected';s.finish(2)
expect(host._native_direct_reading.menu and s.opened==0 and #s.jobs==2 and cloud_marked(s.items[1]) and s.info==1,
    'failed direct continuation did not return to its chapter list')
host,s=start_exact();ready=s.jobs[2].task();s.cancel();s.jobs[2].callback(ready)
expect(s.opened==0 and not s.items and not host._native_direct_reading,'cancelled direct continuation opened the reader')
host,s=fixture();cloud_progress={book={bookId='456',chapterUid=2,chapterIdx=2,chapterOffset=40,
    progress=10,summary='A unique later passage'}}
UI.start(host,{book_id='456'},s.view,{cloud_chapter=true});s.finish(1)
expect(#s.jobs==1 and s.page==2 and not s.items[2].select_enabled,'a locked exact cloud chapter was prepared automatically')
host,s=fixture();cloud_progress={book={bookId='456',chapterUid=1,progress=10}}
UI.start(host,{book_id='456'},s.view,{anchor=anchor,cloud_chapter=true});s.finish(1)
expect(progress_calls==0 and s.page==2 and marked(s.items[2]),'cloud lookup overrode the local chapter')
anchor.book_version=6
host,s=fixture();UI.start(host,{book_id='456'},s.view,{anchor=anchor});s.finish(1)
expect(not s.page and not marked(s.items[2]),'a different catalog version inherited a current chapter badge')
anchor.book_version=7;anchor.catalog_order=2;anchor.catalog_count=2;anchor.catalog_prev='1'
for _,sha in ipairs({digest,fingerprint}) do
    anchor.catalog_sha256=sha
    host,s=fixture();host.ui.document={file=reader_path}
    expect(UI.start(host,{book_id='456'},host.ui,{from_reader=true,batch=true,anchor=anchor}),'reader batch did not start')
    s.finish(1);assert(host._native_direct_reading.confirm).choice1_callback()
    local matches=sha==digest
    expect(s.title=='Choose the first chapter to download' and marked(s.items[2])==matches
        and s.page==(matches and 2 or nil),'range picker used an unverified anchor or missed the current chapter')
    s.select(1)
    expect(s.page==1 and #s.jobs==1,'range end ignored the chosen start or started downloading prematurely')
    UI.cancel(host)
end
host,s=fixture();UI.start(host,{book_id='456'},s.view);s.finish(1);s.select(1);local stale=s.jobs[2].task();account_valid=false;s.jobs[2].callback(stale)
expect(s.opened==0 and host._native_direct_reading==nil,'stale account opened chapter')
host,s=fixture();UI.start(host,{book_id='456'},s.view);s.finish(1);s.select(1);build_error='catalog_changed';s.finish(2)
expect(s.opened==0 and not host._native_direct_reading and s.message=='The chapter list changed. Please open it again.',
    'older catalog stayed active after detecting a change')
host,s=fixture();UI.start(host,{book_id='456'},s.view);s.finish(1)
menu=host._native_direct_reading.menu
menu:onLeftButtonTap();s.input.input='First';s.input.buttons[1][2].callback()
local online_filtered=s.items
s.select(1)
local cancel_prepare=s.cancel
local stopped=s.jobs[2];local stopped_result=stopped.task()
s.select(1)
expect(#s.jobs==2 and host._native_direct_reading.menu==menu,'preparation hid the filtered catalog or ran twice')
cancel_prepare()
expect(host._native_direct_reading.menu==menu and s.items==online_filtered and not host.busy_message and s.cancelled,
    'cancelling an online chapter lost the filtered catalog')
s.select(1);cancel_prepare();stopped.callback(stopped_result)
expect(#s.jobs==3 and s.opened==0 and host.busy_message,'late cancellation or result affected the retry')
build_error='rate_limited';s.finish(3)
expect(host._native_direct_reading.menu==menu and s.items==online_filtered and not host.busy_message
    and s.message=='WeRead is limiting requests. Please try again later.',
    'a temporary chapter failure lost the filtered catalog')
build_error=nil;s.select(1);s.finish(4)
expect(s.opened==1 and not host._native_direct_reading and not host.busy_message,'the selected chapter did not open after retry')
host,s=fixture();UI.start(host,{book_id='456'},s.view);catalog_error='native_auth/native_catalog_info/http_401';s.finish(1)
expect(#s.jobs==2 and renewal_count==1,'catalog 401 not renewed once')
catalog_error=nil;s.finish(2);expect(s.items~=nil,'renewal did not reload catalog')
host,s=fixture();UI.start(host,{book_id='456'},s.view);s.finish(1);s.select(1);build_error='auth_expired';s.finish(2)
expect(#s.jobs==3 and renewal_count==2,'chapter 401 not renewed once')
build_error=nil;s.finish(3)
expect(s.opened==1 and expected_args.access_fingerprint==selected.fingerprint and selected~=initial_access,
    'renewed chapter kept the previous authorization guard')
host,s=fixture();UI.start(host,{book_id='456'},s.view);local old=s.jobs[1];UI.cancel(host);old.callback(old.task())
expect(s.opened==0 and not s.items,'cancelled response changed UI')
host,s=fixture();UI.start(host,{book_id='456'},s.view);s.finish(1)
local stale_select=s.select;UI.cancel(host);UI.start(host,{book_id='456'},s.view);s.finish(2)
stale_select(1);expect(#s.jobs==2,'closed chapter menu selected into the new menu')
s.select(1);expect(#s.jobs==3,'current chapter menu stopped accepting selections')
host,s=fixture();UI.start(host,{book_id='456'},s.view);local suspended=s.jobs[1];local response=suspended.task()
host._weread_suspended=true;suspended.callback(response)
expect(s.opened==0 and not s.items and not host._native_direct_reading,'suspended reader accepted a late catalog')
host,s=fixture();UI.start(host,{book_id='456'},s.view,{batch=true});s.finish(1)
local confirm=assert(host._native_direct_reading.confirm);confirm.cancel_callback()
expect(not host._native_direct_reading and #s.jobs==1,'cancelled batch started downloading')
host,s=fixture();UI.start(host,{book_id='456'},s.view,{batch=true});s.finish(1)
confirm=assert(host._native_direct_reading.confirm);account_valid=false;confirm.choice2_callback()
expect(not host._native_direct_reading and #s.jobs==1,'old account confirmation started downloading')
host,s=fixture();UI.start(host,{book_id='456'},s.view,{batch=true});s.finish(1)
confirm=assert(host._native_direct_reading.confirm);confirm.choice2_callback()
expect(#s.jobs==2 and host._native_direct_reading.phase=='batch','batch did not start after confirmation')
account_valid=false;s.jobs[2].progress(33)
expect(not host._native_direct_reading and s.cancelled,'account change did not cancel the background batch')
host,s=fixture();UI.start(host,{book_id='456'},s.view,{batch=true});s.finish(1)
confirm=assert(host._native_direct_reading.confirm);confirm.choice1_callback()
s.select(2)
expect(s.page==2 and s.title=='Choose the last chapter to download' and #s.jobs==1,'range end did not open at start')
s.select(2)
expect(s.message=='No readable E-Ink chapters in this range.' and host._native_direct_reading.menu and #s.jobs==1,
    'empty readable range started a batch')
s.select(1);confirm=assert(host._native_direct_reading.confirm)
expect(#s.jobs==1 and confirm.text:find('chapters 1–2',1,true),'reverse range did not wait for confirmation')
confirm.ok_callback()
local range=host._native_direct_reading.batch_range
expect(#s.jobs==2 and range.first==1 and range.last==2,'range did not bind to the full catalog indices')
local batch_job=s.jobs[2]
batch_job.progress(50)
batch_job.callback({ok=false,error='transport'})
local retry=host._native_direct_reading and host._native_direct_reading.confirm
expect(retry and retry.text:find('chapters 1–2',1,true) and not host.busy_message,
    'connection failure lost the selected batch range')
batch_job.progress(99)
batch_job.callback({ok=false,error='transport'})
expect(host._native_direct_reading.confirm==retry,'a late batch update replaced the retry confirmation')
host.isNetworkConnected=function() return false end
retry.ok_callback()
local offline_retry=assert(host._native_direct_reading.confirm)
expect(#s.jobs==2 and not host.busy_message,'offline retry tried to load the catalog')
host.isNetworkConnected=function() return true end
offline_retry.ok_callback()
expect(#s.jobs==3 and host._native_direct_reading.phase=='catalog','retry did not refresh the catalog first')
catalog_error='native_auth/native_catalog_catalog/timeout';s.finish(3)
local retry_again=assert(host._native_direct_reading.confirm)
expect(#s.jobs==3 and not host.busy_message,'failed catalog refresh lost the retry or restarted automatically')
catalog_error=nil;retry_again.ok_callback();s.finish(4)
expect(#s.jobs==5 and host._native_direct_reading.batch_range==range and not host._native_direct_reading.batch_progress,
    'retry did not reuse the selected range or reset progress')
retry_again.ok_callback()
expect(#s.jobs==5,'an old retry confirmation started another download')
s.jobs[5].callback({ok=true,downloaded=0,saved=1,unavailable=1,missing=0})
expect(not host._native_direct_reading and not host.busy_message,'resumed batch did not finish')
host,s=fixture();UI.start(host,{book_id='456'},s.view,{batch=true});s.finish(1)
confirm=assert(host._native_direct_reading.confirm);confirm.choice2_callback()
s.jobs[2].callback({ok=false,error='rate_limited'})
retry=assert(host._native_direct_reading.confirm);retry.ok_callback()
sample.version=8;s.finish(3);sample.version=7
expect(#s.jobs==3 and not host._native_direct_reading and s.message=='The chapter list changed. Please open it again.',
    'retry used old chapter bounds in a changed catalog')
local owner=require('weread.lib.native_position_contract').account_key(scope.vid)
local reviewed={schema=1,account=owner,book_id='456',version=7,digest=digest,count=2,first=1,last=1,revision=string.rep('e',32)}
local observed=reviewed
for _,mode in ipairs({'same','updated','catalog_changed'}) do
    host,s=fixture()
    host.library_db.accountKey=function() return owner end
    host.library_db.getProfileState=function() return observed end
    if mode=='updated' then
        observed={};for key,value in pairs(reviewed) do observed[key]=value end
        observed.revision=string.rep('f',32)
    else observed=reviewed end
    expect(UI.start(host,{book_id='456'},s.view,{batch=true,resume_plan=reviewed}),'selected plan could not be checked')
    catalog_error='native_auth/native_catalog_catalog/http_429';s.finish(1)
    local catalog_retry=host._native_direct_reading and host._native_direct_reading.confirm
    expect(catalog_retry and catalog_retry.text:find('Retry loading the chapter list?',1,true)
        and #s.jobs==1 and not host.busy_message,'initial catalog failure dismissed the unfinished download')
    host.isNetworkConnected=function() return false end
    catalog_retry.ok_callback()
    local offline_prompt=assert(host._native_direct_reading.confirm)
    expect(#s.jobs==1 and not host.busy_message,'offline catalog retry tried to download')
    host.isNetworkConnected=function() return true end
    catalog_error=nil;offline_prompt.ok_callback();catalog_retry.ok_callback()
    expect(#s.jobs==2 and host._native_direct_reading.phase=='catalog','old catalog prompt restarted the download')
    if mode=='catalog_changed' then sample.version=8 end
    s.finish(2);sample.version=7
    if mode=='same' then
        expect(host._native_direct_reading.confirm.choice1_text=='Continue download' and #s.jobs==2,
            'selected plan started without confirmation')
    else
        expect(not host._native_direct_reading and #s.jobs==2 and s.info==1,'a stale plan proceeded after retry')
    end
end
host,s=fixture();UI.start(host,{book_id='456'},s.view,{batch=true})
catalog_error='native_auth/native_catalog_info/timeout';s.finish(1)
local catalog_retry=assert(host._native_direct_reading.confirm)
account_valid=false;catalog_retry.ok_callback()
expect(not host._native_direct_reading and #s.jobs==1,'old account restarted the batch catalog')
host,s=fixture();UI.start(host,{book_id='456'},s.view,{batch=true});s.finish(1)
confirm=assert(host._native_direct_reading.confirm);require('ui/uimanager'):close(confirm);confirm.choice2_callback()
expect(not host._native_direct_reading and #s.jobs==1,'dismissed download options retained a valid action')
local target={uid='2',from_uid='1',catalog_sha256=digest,book_version=7,count=2,order=2,direction=1}
host,s=fixture();sample.reading_chapters[2].downloadable=true
UI.start(host,{book_id='456'},s.view,{target=target});s.finish(1)
expect(#s.jobs==2 and not s.items,'verified adjacent download did not begin automatically')
s.finish(2);expect(s.opened==1 and expected_chapter.chapterUid=='2','verified adjacent download did not open')
sample.reading_chapters[2].downloadable=false
host,s=fixture();UI.start(host,{book_id='456'},s.view,{target=target});s.finish(1)
expect(#s.jobs==1 and s.message=='The adjacent E-Ink chapter is unavailable.','locked adjacent chapter was downloaded')
host,s=fixture();local stale_target={};for key,value in pairs(target) do stale_target[key]=value end
stale_target.catalog_sha256=string.rep('d',64)
UI.start(host,{book_id='456'},s.view,{target=stale_target});s.finish(1)
expect(#s.jobs==1 and s.message=='The chapter list changed. Please open it again.','changed catalog was used for adjacent download')
local cache=require('weread.lib.native_direct_cache');local pending=require('weread.lib.native_direct_pending')
local old_list,old_valid,old_open,old_mark=cache.list,cache.valid_entry,cache.open,pending.mark
local saved_entry={key=string.rep('d',64),copy=0,title='Saved',book_version=7,chapter_uid='1',missing_images=0,source_sha256=digest}
cache.list=function() return {saved_entry} end;cache.valid_entry=function() return true end
pending.mark=function(_,_,_,_,rows) rows[1].pending_offline=true;return true end
host,s=fixture();selected=nil
expect(UI.start(host,{book_id='456'},s.view),'saved chapters should be available when E-Ink access is missing')
expect(host._native_direct_reading.phase=='offline_list','missing E-Ink access started an online request')
s.finish(1)
expect(s.title=='Saved E-Ink chapters' and s.subtitle=='The online catalog is unavailable. Showing saved chapters.'
    and s.opened==0,'missing E-Ink access did not offer the saved catalog')
host,s=fixture();UI.start(host,{book_id='456'},s.view)
catalog_error='native_auth/native_catalog_catalog/timeout';s.finish(1)
expect(#s.jobs==2 and host._native_direct_reading.phase=='offline_list','online catalog timeout did not start a local lookup')
selected=nil;s.finish(2)
expect(s.title=='Saved E-Ink chapters' and s.opened==0,'local lookup still required the E-Ink grant or opened without a choice')
cache.list=function() return {} end
host,s=fixture();UI.start(host,{book_id='456'},s.view)
catalog_error='native_auth/native_catalog_info/http_429';s.finish(1);s.finish(2)
expect(s.message=='WeRead is limiting requests. Please try again later.' and not host._native_direct_reading,
    'empty local fallback did not report the original error')
cache.list=function() return {saved_entry} end
host,s=fixture();UI.start(host,{book_id='456'},s.view)
catalog_error='native_auth/native_catalog_catalog/http_401';s.finish(1);s.finish(2)
expect(#s.jobs==3 and host._native_direct_reading.phase=='offline_list','repeated 401 should fall back after one renewal')
account_valid=false;s.finish(3)
expect(not host._native_direct_reading and not s.items and s.info==0,'account change exposed a fallback catalog')
host,s=fixture();host.isNetworkConnected=function() error('saved chapter menu probed network state') end
expect(UI.start(host,{book_id='456'},s.view,{cached=true}),'saved chapter list did not start')
s.finish(1)
expect(s.items and s.items[1].text:find('Offline position to review',1,true),
    'saved chapter list did not expose the pending position')
host._native_direct_reading.menu:onLeftButtonTap();s.input.input='Saved';s.input.buttons[1][2].callback()
expect(#s.items==1 and s.items[1].text:find('Offline position to review',1,true) and #s.jobs==1,
    'offline filter lost the pending position or reloaded the catalog')
local other_copy={};for key,value in pairs(saved_entry) do other_copy[key]=value end
other_copy.copy=1
cache.list=function() return {saved_entry,other_copy} end
host,s=fixture();UI.start(host,{book_id='456'},s.view,{cached=true,anchor=other_copy});s.finish(1)
expect(s.page==2 and marked(s.items[2]) and not marked(s.items[1]),
    'saved catalog highlighted a different copy of the same chapter')
local replaced={};for key,value in pairs(other_copy) do replaced[key]=value end
replaced.source_sha256=fingerprint
host,s=fixture();UI.start(host,{book_id='456'},s.view,{cached=true,anchor=replaced});s.finish(1)
expect(not s.page and not marked(s.items[2]),'a changed saved file inherited the current chapter badge')
host,s=fixture();host.isNetworkConnected=function() error('alternative chooser probed network state') end
expect(UI.start(host,{book_id='456'},s.view,{cached=true,failed_copy=saved_entry}),'alternative chooser did not start')
s.finish(1)
expect(#s.items==1 and s.opened==0 and s.subtitle:find('Choose another saved chapter',1,true),
    'alternative chooser opened automatically or offered a failed copy')
s.select(1)
expect(host._native_direct_reading.entry==other_copy,'alternative chooser discarded another copy of the same chapter')
cache.open=function(_,_,_,entry)
    if entry==other_copy then
        return {path='/tmp/settings/native-reader-v1/account/book/other.epub',book_version=7,
            source_sha256=digest,missing_images=0}
    end
end
host,s=fixture();UI.start(host,{book_id='456'},s.view,{cached=true});s.finish(1)
local chooser=host._native_direct_reading.menu
chooser:onLeftButtonTap();s.input.input='Saved';s.input.buttons[1][2].callback()
chooser:onGotoPage(2)
local filtered=s.items
s.select(1);s.select(2)
expect(#s.jobs==2,'a second choice replaced an in-flight saved-file check')
s.finish(2)
expect(host._native_direct_reading.menu==chooser and s.items==filtered and s.page==2
    and not host.busy_message and s.message:find('file was kept',1,true),'failed check discarded the chapter list')
s.select(2)
local cancelled_job=s.jobs[3]
local cancelled_result=cancelled_job.task()
local stop=s.cancel
stop()
expect(s.cancelled and not host.busy_message and host._native_direct_reading.menu==chooser,
    'cancelling the file check closed the saved-chapter list')
s.select(2);stop();cancelled_job.callback(cancelled_result)
expect(#s.jobs==4 and s.opened==0 and host.busy_message,'stale cancellation or result affected the new check')
s.finish(4)
expect(s.opened==1 and s.path:find('/other.epub',1,true) and not host._native_direct_reading and not host.busy_message,
    'a second saved copy could not open from the same list')
host,s=fixture();UI.start(host,{book_id='456'},s.view,{cached=true});s.finish(1)
s.select(2);local valid_result=s.jobs[2].task();account_valid=false;s.jobs[2].callback(valid_result)
expect(not host._native_direct_reading and s.opened==0 and s.info==0,'stale account retained the saved chooser')
host,s=fixture();UI.start(host,{book_id='456'},s.view,{cached=true});s.finish(1)
s.select(2);valid_result=s.jobs[2].task()
require('ui/uimanager'):close(host._native_direct_reading.menu)
s.jobs[2].callback(valid_result)
expect(not host._native_direct_reading and s.cancelled and s.opened==0,'closing the list left a saved file able to open')
local function same_catalog(entry)
    entry.catalog_sha256=digest
    entry.chapter_idx=1
    entry.catalog_order,entry.catalog_count,entry.catalog_next=1,2,'2'
    return entry
end
local matching=same_catalog(other_copy)
local wrong_catalog=same_catalog(saved_entry)
wrong_catalog.catalog_sha256=fingerprint
cache.list=function(_,_,id,current,chapter_uid)
    expect(id=='456' and chapter_uid=='1' and current(),'saved lookup was not limited to the selected chapter and account')
    return {wrong_catalog,matching}
end
host,s=fixture();UI.start(host,{book_id='456'},s.view);s.finish(1)
build_error='rate_limited'
s.select(1);s.finish(2)
expect(s.opened==1 and s.path:find('/other.epub',1,true) and not host._native_direct_reading,
    'a complete, matching online chapter was requested from the server again')
local matching_list,open_copy=cache.list,cache.open
local alternate={}
for key,value in pairs(matching) do alternate[key]=value end
alternate.copy=matching.copy+1
cache.list=function() return {matching,alternate} end
cache.open=function(settings,vid,id,entry,current)
    if entry==alternate then
        return {path='/tmp/settings/native-reader-v1/account/book/alternate.epub',book_version=7,
            source_sha256=digest,missing_images=0}
    end
    return open_copy(settings,vid,id,entry,current)
end
host,s=fixture();UI.start(host,{book_id='456'},s.view);s.finish(1)
build_error='rate_limited';s.select(1);s.finish(2)
expect(host._native_direct_reading.copy_menu and #s.items==2 and s.opened==0
    and s.subtitle=='Each copy keeps its own reading position.',
    'online catalog ignored the separate reading positions of complete copies')
s.select(2);s.finish(3)
expect(s.opened==1 and s.path:find('/alternate.epub',1,true),'complete copy chooser did not open the selected file')
host,s=start_exact();s.finish(2)
local direct_copies=assert(host._native_direct_reading.copy_menu)
expect(not host._native_direct_reading.menu and s.opened==0,'direct continuation picked an arbitrary saved copy')
require('ui/uimanager'):close(direct_copies)
expect(not host._native_direct_reading.menu and type(next_tick)=='function','copy chooser opened a menu during close')
next_tick()
expect(host._native_direct_reading.menu and cloud_marked(s.items[1]) and #s.jobs==2,
    'dismissing the direct copy chooser did not return to the cloud chapter')
host,s=start_exact();s.finish(2);s.select(2);s.finish(3)
expect(not host._native_direct_reading and s.opened==1 and s.path:find('/alternate.epub',1,true) and s.handoff,
    'the selected copy lost the direct cloud position')
cache.list=matching_list;cache.open=function() return nil end
host,s=fixture();UI.start(host,{book_id='456'},s.view);s.finish(1);s.select(1);s.finish(2)
expect(s.opened==1 and s.path:find('/file.epub',1,true),'a damaged matching copy blocked a fresh download')
cache.open=open_copy
matching.missing_images=1
host,s=fixture();UI.start(host,{book_id='456'},s.view);s.finish(1)
host.isNetworkConnected=function() return false end
selected=nil
build_error='network must not be used'
s.select(1);s.finish(2)
expect(s.opened==1 and s.path:find('/other.epub',1,true) and not host._native_direct_reading,
    'the online catalog could not open its matching saved chapter after disconnecting')
host,s=fixture();UI.start(host,{book_id='456'},s.view);s.finish(1)
s.select(1)
local remote_job=s.jobs[2]
build_error='transport'
s.finish(2)
expect(#s.jobs==3 and s.opened==0 and host.busy_message,
    'a broken transport did not fall back to the saved chapter')
remote_job.callback({error='transport'})
expect(#s.jobs==3,'a repeated transport result started a second lookup')
s.finish(3)
expect(s.opened==1 and s.path:find('/other.epub',1,true) and not host._native_direct_reading,
    'local fallback still depended on a new network request')
host,s=fixture();UI.start(host,{book_id='456'},s.view);s.finish(1)
build_error='transport';s.select(1);s.finish(2)
local pending_fallback=s.jobs[3].task()
account_valid=false;s.jobs[3].callback(pending_fallback)
expect(#s.jobs==3 and s.opened==0 and not host._native_direct_reading,
    'a saved fallback opened after the account changed')
host,s=fixture();UI.start(host,{book_id='456'},s.view);s.finish(1)
local online_menu=host._native_direct_reading.menu
host.isNetworkConnected=function() return false end
cache.list=function() return {wrong_catalog} end
s.select(1);s.finish(2)
expect(s.opened==0 and not host.busy_message and host._native_direct_reading.menu==online_menu
    and s.message=='No saved copy matches this chapter. Connect to download it.',
    'a cache from a different catalog did not leave the reader in the same directory')
local damaged_copy={}
for key,value in pairs(matching) do damaged_copy[key]=value end
damaged_copy.copy=2
cache.list=function() return {damaged_copy,matching} end
local select_chapter=s.select
s.select(1);s.finish(3)
local copies=assert(host._native_direct_reading.copy_menu)
expect(s.opened==0 and s.title=='Choose a saved chapter copy' and #s.items==2 and s.items[2].text:find('Copy 2',1,true),
    'matching copies were not offered as separate reading positions')
select_chapter(1)
expect(#s.jobs==3,'a covered catalog accepted a second choice')
s.select(1);s.finish(4)
expect(s.opened==0 and host._native_direct_reading.copy_menu==copies and not host.busy_message
    and s.message:find('damaged',1,true),'a damaged local copy closed the chooser')
s.select(2)
local choice_job=s.jobs[5];local choice_result=choice_job.task()
require('ui/uimanager'):close(copies);choice_job.callback(choice_result)
expect(s.opened==0 and host._native_direct_reading.menu==online_menu and not host._native_direct_reading.copy_menu
    and not host.busy_message,'closing the copy menu let its pending result leave the catalog')
select_chapter(1);s.finish(6);s.select(2);s.finish(7)
expect(s.opened==1 and s.path:find('/other.epub',1,true) and not host._native_direct_reading,
    'the selected local copy did not open from the online catalog')
cache.list,cache.valid_entry,cache.open,pending.mark=old_list,old_valid,old_open,old_mark
print('PASS: native chapter catalog, capability hint, session checks and renewal ('..checks..' checks)')
