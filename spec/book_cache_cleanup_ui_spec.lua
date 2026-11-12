-- Confirmation lifetime, reader/download exclusion and cooperative cancellation.
package.path='./?.lua;'..package.path
local scheduled,shown,removed,patches,released={},nil,0,0,0
local changed,fail_step=false,false
local root='/cache/900001'
local metadata={mode='directory',dev=1,ino=1}
package.preload['libs/libkoreader-lfs']=function() return {symlinkattributes=function() return metadata end} end
package.preload['weread.lib.content']=function() return {book_resolved_dir=function(_settings,_id,book) return book.cache_dir end} end
package.preload['weread.lib.book_store']=function() return {clear_downloads=function() patches=patches+1;return true end} end
package.preload['weread.lib.plugin_util']=function() return {
    tr=function(value) return value end,T=function(value) return value end,file_exists=function() return true end,
} end
package.preload['ui/uimanager']=function() return {
    show=function(_self,widget) shown=widget end,
    close=function(_self,widget) if widget.onCloseWidget then widget:onCloseWidget() end end,
    scheduleIn=function(_self,delay,callback) assert(delay>=.1);scheduled[#scheduled+1]=callback end,
} end
package.preload['ui/widget/confirmbox']=function() return {new=function(_self,options) return options end} end
package.preload['weread.lib.book_cache_cleanup']=function() return {
    scan=function() return {files=70,bytes=70,metadata='fixture',owner=metadata} end,
    same_plan=function() return not changed end,
    acquire=function() return {owns=function() return true end,release=function() released=released+1 end},
        {files=70,bytes=70,metadata='fixture',owner=metadata} end,
    step=function(job,limit)
        if fail_step then return false end
        local amount=math.min(limit,70-job.files);removed=removed+amount;job.files=job.files+amount
        return true,job.files==70 and 'done' or 'continue'
    end,
} end
local Model=require('weread.ui.book_cache_cleanup')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local function fixture()
    scheduled={};shown=nil;removed=0;patches=0;released=0;changed=false;fail_step=false
    package.loaded['apps/reader/readerui']=nil
    local books={['900001']={book_id='900001',cache_dir=root}}
    local host={ui={},settings={cache_dir='/cache'},info={},done=0,refreshes=0}
    function host.settings:get(key,fallback) return key=='books' and books or fallback end
    function host.settings:get_auth_scope() return {vid='900000',epoch=1} end
    function host.settings:auth_scope_matches() return not host.auth_changed end
    function host:clearBookAnnotationData() self.annotation_cleared=true;return true end
    function host:showBusy(_text,cancel) self.busy_message={};self.stop=cancel end
    function host:closeBusy() self.busy_message=nil end
    function host:showInfo(text) self.info[#self.info+1]=text end
    function host:showTransientInfo(text) self.info[#self.info+1]=text end
    function host:refreshCacheManagement(text) self.info[#self.info+1]=text end
    function host:refreshShelfCacheIndicators() self.refreshes=self.refreshes+1 end
    return host,books
end
local host=fixture();expect(Model.show(host,{'900001'},'Synthetic cache',function() host.done=host.done+1 end),'preview failed')
expect(removed==0 and released==0 and shown.text:find('Reading positions',1,true),'preview mutated content or omitted record retention')
shown.cancel_callback();expect(not host.book_cache_cleanup_job and removed==0,'cancelled confirmation removed content')
host=fixture();Model.show(host,{'900001'});local old=shown;old:onCloseWidget();old.ok_callback()
expect(removed==0 and not host.book_cache_cleanup_job,'closed dialog could still apply')
for _,change in ipairs({'account','epoch','session','view','document','global_reader','root','active','queued','scheduled'}) do
    local books;host,books=fixture();expect(Model.show(host,{'900001'}),'preview unavailable')
    if change=='account' then host.auth_changed=true
    elseif change=='epoch' then host.discovery_epoch=1
    elseif change=='session' then host._reader_session_gen=1
    elseif change=='view' then host._book_detail_view={}
    elseif change=='document' then host.ui.document={file='/unrelated/book.epub'}
    elseif change=='global_reader' then package.loaded['apps/reader/readerui']={instance={document={file=root..'/full.epub'}}}
    elseif change=='root' then books['900001'].cache_dir='/new/900001'
    else
        local job={book={book_id='900001'}}
        host.downloader=change=='active' and {_active_job=job} or change=='queued' and {_pending_start=job} or {_scheduled_start={pending=job}}
    end
    shown.ok_callback();expect(removed==0 and not host.book_cache_cleanup_job,'stale confirmation applied: '..change)
end
host=fixture();host.ui.document={file=root..'/full.epub'}
expect(not Model.show(host,{'900001'}) and removed==0,'open document accepted for cleanup')
host=fixture();Model.show(host,{'900001'});changed=true;shown.ok_callback()
expect(released==1 and removed==0 and not host.book_cache_cleanup_job,'changed preview held lease or deleted new cache')
host=fixture();Model.show(host,{'900001'},nil,function() host.done=host.done+1 end);shown.ok_callback()
expect(#scheduled==1 and removed==0,'confirmation blocked instead of scheduling')
table.remove(scheduled,1)();expect(removed==32 and #scheduled==1,'first chunk did not yield')
host.stop();expect(removed==32 and patches==1 and released==1 and not host.annotation_cleared,'cancellation erased annotations or lost metadata reconciliation')
table.remove(scheduled,1)();expect(removed==32 and host.done==0,'cancelled scheduled chunk continued')
host=fixture();Model.show(host,{'900001'},nil,function() host.done=host.done+1 end);shown.ok_callback()
while #scheduled>0 do table.remove(scheduled,1)() end
expect(removed==70 and released==1 and patches==1 and host.done==1 and host.annotation_cleared,'completed cleanup failed to reconcile or signal success')
host=fixture();Model.show(host,{'900001'});shown.ok_callback();fail_step=true;table.remove(scheduled,1)()
expect(released==1 and removed==0 and not host.book_cache_cleanup_job and not host.annotation_cleared,'deletion failure leaked lease or claimed success')
host=fixture();Model.show(host,{'900001'});shown.ok_callback();table.remove(scheduled,1)();host.discovery_epoch=1
table.remove(scheduled,1)();expect(removed==32 and released==1 and patches==1 and #host.info==0,'context change continued deletion or showed stale result')
host=fixture();Model.show(host,{'900001'});shown.ok_callback();Model.cancel(host)
expect(released==1 and removed==0 and not host.book_cache_cleanup_job and not host.busy_message,'leaving UI leaked cleanup task')
print(('book_cache_cleanup_ui_spec: %d checks'):format(checks))
