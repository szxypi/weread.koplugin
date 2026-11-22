package.path='./?.lua;'..package.path
local checks=0;local function expect(v,m) checks=checks+1;assert(v,m) end
local scheduled={};local page=1;local live=true;local in_worker=false
local wanted={book_id='42',chapter_uid='38',chapter_idx=3,chapter_offset=200,stamp=string.rep('c',64)}
local entry={book_id='42',chapter_uid='38',chapter_idx=3,book_version=7,file_id=string.rep('a',64)}
local identity={book_id='42',book_version=7,file_id=entry.file_id};local scope={vid='123',epoch=1};local native,web={},{}
local offset=200;local failure
package.preload['ui/uimanager']=function() return {scheduleIn=function(_,_,task) scheduled[#scheduled+1]=task end,unschedule=function() end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(v) return v end} end
package.preload['weread.lib.native_read_access']=function() return {matches=function() return live end} end
package.preload['weread.lib.source_currentness']=function() return {matches=function() return live end} end
package.preload['weread.lib.native_direct_cache']=function() return {valid_entry=function(e,id,vid) return e==entry and id=='42' and vid=='123' end} end
package.preload['weread.lib.native_direct_cloud']=function() return {
    valid_target=function(v) return v==wanted end,same_target=function(a,b) return a==b end,
    prepare_destination=function(_,_,e,file,n,w,active,t)
        assert(in_worker and e==entry and file=='/target' and n==native and w==web and active() and t==wanted)
        if failure then return nil,failure end
        return {target=wanted,anchor={co=offset,text='unique target anchor text',point_offset=2,
            point_unit='unicode_scalars',basis='filtered_xhtml_utf16'}}
    end,
} end
package.preload['weread.lib.source_context']=function() return {
    location=function() assert(not in_worker);return {page=page} end,
    same_location=function(a,b) return a and b and a.page==b.page end,
} end
package.preload['weread.lib.book_file_identity']=function() return {read_document=function() assert(not in_worker);return identity end} end
package.preload['weread.lib.source_dom']=function() return {open_direct_prepared=function(doc,book,uid,id,options)
    assert(not in_worker and doc and book=='42' and uid=='38' and id==identity and options.is_current())
    return {locate_anchor=function(_,anchor) return {co=anchor.co,book_id=book,chapter_uid=uid,file_id=id.file_id,
        render_path='OEBPS/text/chapter.xhtml',xpointer='/cloud'} end}
end} end
package.preload['weread.lib.reader_position']=function() return {
    goto_xpointer=function(_,xp) assert(xp=='/cloud');page=2;return true end,
    snapshot=function() return {} end,contains_anchor=function(_,_,xp) return xp=='/cloud' end,
} end
local Open=require('weread.ui.native_direct_cloud_open')
local function fixture()
    scheduled={};page=1;live=true;offset=200;failure=nil
    local s={jobs={},infos=0};local doc={file='/target'};local reader={document=doc,view={view_mode='page'}}
    local host={ui=reader,client={},_reader_session_gen=1,settings={get_auth_scope=function() return scope end,
        auth_scope_matches=function(_,value) return value==scope and live end},library_db={accountKey=function() return 'account' end},
        showBusy=function(self) self.busy_message={} end,closeBusy=function(self) self.busy_message=nil end,
        showInfo=function(_,text) s.infos=s.infos+1;s.message=text end,
        _native_direct_cloud_open_worker={start=function(_,task,callback) s.jobs[#s.jobs+1]={task=task,callback=callback};return true end,
            cancel=function() s.cancelled=true end}}
    function s.step() local task=table.remove(scheduled,1);assert(task);task() end
    function s.result(index) in_worker=true;local value=s.jobs[index].task();in_worker=false;s.jobs[index].callback(value) end
    return host,s
end
local host,s=fixture();expect(Open.start(host,entry,wanted,native,web),'destination did not start')
s.result(1);s.step();expect(#s.jobs==2,'destination was not rechecked');s.result(2)
expect(page==2 and s.message=='Opened the cloud reading position in this chapter.' and not host._native_direct_cloud_open,
    'destination was not opened after recheck')
host,s=fixture();Open.start(host,entry,wanted,native,web);s.result(1);s.step();offset=201;s.result(2)
expect(page==1 and s.infos==1 and not host._native_direct_cloud_open,'changed cloud target moved the reader')
host,s=fixture();Open.start(host,entry,wanted,native,web);page=3;Open.on_view_changed(host)
expect(s.cancelled and not host._native_direct_cloud_open,'page movement did not cancel destination')
host,s=fixture();Open.start(host,entry,wanted,native,web);failure='cloud_changed';s.result(1)
expect(s.message=='The cloud position changed during the check. Your current page is kept.','cloud change not explained')
host,s=fixture();expect(Open.receive(host,entry,wanted,native,web),'handoff was not scheduled');s.step()
expect(host._native_direct_cloud_open and #s.jobs==1,'handoff did not start destination')
host,s=fixture();Open.receive(host,entry,wanted,native,web);page=3;Open.on_view_changed(host)
expect(not host._native_direct_cloud_incoming and #s.jobs==0,'moved page did not cancel pending handoff')
print('PASS: native cloud destination rechecks before navigation ('..checks..' checks)')
