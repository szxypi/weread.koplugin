package.path='./?.lua;'..package.path
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local fingerprint=string.rep('a',64)
local digest=string.rep('b',64)
local scope={vid='123',epoch=1}
local selected={scope=scope,fingerprint=fingerprint,revision=1,store={},credentials={vid='123'}}
local account_valid=true
package.preload['ui/uimanager']=function() return {show=function() end,
    close=function(_,widget) if widget.onCloseWidget then widget:onCloseWidget() end end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(text) return text end,
    T=function(text,...) local args={...};return (text:gsub('%%(%d)',function(i) return args[tonumber(i)] or '' end)) end} end
package.preload['ui/widget/confirmbox']=function() return {new=function(_,value) return value end} end
package.preload['ui/widget/multiconfirmbox']=package.preload['ui/widget/confirmbox']
package.preload['ui/widget/inputdialog']=function()
    return {new=function(_,value) value.getInputText=function(self) return self.input end;return value end}
end
package.preload['weread.ui.download_dialog']=function() return {new=function(_,value)
    value.show=function() end;value.reportProgress=function() end;return value end} end
package.preload['weread.lib.native_read_access']=function() return {
    capture=function() if account_valid then return selected end end,
    matches=function(_,value) return account_valid and value==selected end,
} end
local renewal_count=0
package.preload['weread.lib.native_read_recovery']=function() return {
    cancel=function() end,
    start=function(_,ctx,old,opts)
        if ctx.recovery_attempted then return false end
        ctx.recovery_attempted=true;renewal_count=renewal_count+1
        opts.complete(true,old);return true
    end,
} end
package.preload['weread.lib.native_authorization']=function() return {new=function() return {cancel=function() end} end} end
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
    function(v) v.reading_chapters[4]={} end}) do
    local bad=clone();mutate(bad);expect(not UI.project(bad,'456'),'invalid catalog accepted')
end
local function fixture()
    account_valid=true;catalog_error=nil;build_error=nil
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
                onGotoPage=function(_,page) state.page=page end,switchItemTable=function(self,_,rows)
                self.item_table=rows;state.items=rows
            end}
            state.title=title;state.items=items;state.subtitle=options.subtitle;state.icon=options.left_icon
            state.select=function(index) options.on_choice(menu.item_table[index]) end
            state.choose=options.on_choice
            return menu
        end,
        openFile=function(_,path) state.opened=state.opened+1;state.path=path end,
        _native_direct_worker={start=function(_,task,callback,progress) state.jobs[#state.jobs+1]={task=task,callback=callback,progress=progress};return true end,
            cancel=function() state.cancelled=true end}}
    function state.finish(index) local job=state.jobs[index];job.callback(job.task()) end
    return host,state
end
local host,s=fixture()
expect(UI.start(host,{book_id='456',title='Test',author='Author'},s.view),'failed to start')
s.finish(1)
expect(#s.items==2 and s.items[1].select_enabled and not s.items[2].select_enabled,'entitlement not shown')
expect(s.subtitle=='Online: sync position or save selected highlights and private thoughts.','chapter capability hint missing')
s.select(2);expect(#s.jobs==1,'locked chapter opened')
s.select(1);expect(#s.jobs==2,'chapter not scheduled')
s.finish(2)
expect(s.opened==1 and s.path:find('/native-reader-v1/',1,true),'chapter not opened')
expect(expected_book.book_id=='456' and expected_chapter.chapterUid=='1' and expected_args.reading_catalog_sha256==digest
    and expected_args.access_fingerprint==fingerprint,'source identity not bound')
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
host,s=fixture();UI.start(host,{book_id='456'},s.view);s.finish(1);s.select(1);local stale=s.jobs[2].task();account_valid=false;s.jobs[2].callback(stale)
expect(s.opened==0 and host._native_direct_reading==nil,'stale account opened chapter')
host,s=fixture();UI.start(host,{book_id='456'},s.view);s.finish(1);s.select(1);build_error='catalog_changed';s.finish(2)
expect(s.opened==0 and s.message=='The chapter list changed. Please open it again.','catalog change not reported')
host,s=fixture();UI.start(host,{book_id='456'},s.view);catalog_error='native_auth/native_catalog_info/http_401';s.finish(1)
expect(#s.jobs==2 and renewal_count==1,'catalog 401 not renewed once')
catalog_error=nil;s.finish(2);expect(s.items~=nil,'renewal did not reload catalog')
host,s=fixture();UI.start(host,{book_id='456'},s.view);s.finish(1);s.select(1);build_error='auth_expired';s.finish(2)
expect(#s.jobs==3 and renewal_count==2,'chapter 401 not renewed once')
build_error=nil;s.finish(3);expect(s.opened==1,'renewed chapter did not open')
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
local old_list,old_valid,old_mark=cache.list,cache.valid_entry,pending.mark
local saved_entry={key=string.rep('d',64),copy=0,title='Saved',book_version=7,chapter_uid='1',missing_images=0}
cache.list=function() return {saved_entry} end;cache.valid_entry=function() return true end
pending.mark=function(_,_,_,_,rows) rows[1].pending_offline=true;return true end
host,s=fixture();host.isNetworkConnected=function() return false end
expect(UI.start(host,{book_id='456'},s.view,{cached=true}),'saved chapter list did not start')
s.finish(1)
expect(s.items and s.items[1].text:find('Offline position to review',1,true),
    'saved chapter list did not expose the pending position')
host._native_direct_reading.menu:onLeftButtonTap();s.input.input='Saved';s.input.buttons[1][2].callback()
expect(#s.items==1 and s.items[1].text:find('Offline position to review',1,true) and #s.jobs==1,
    'offline filter lost the pending position or reloaded the catalog')
cache.list,cache.valid_entry,pending.mark=old_list,old_valid,old_mark
print('PASS: native chapter catalog, capability hint, session checks and renewal ('..checks..' checks)')
