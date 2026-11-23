package.path='./?.lua;'..package.path
package.preload['ui/uimanager']=function() return {} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(s) return s end} end
local Crypto=require('weread.lib.crypto')
local owner=Crypto.sha256_hex('weread-library:123'):sub(1,20)
local path='/tmp/test/native-reader-v1/account/book/chapter/file.epub'
local entry={book_id='42',chapter_uid='1',book_version=2,key=string.rep('a',64),copy=0,
    source_sha256=string.rep('b',64),file_id=string.rep('c',64)}
local valid,exists=true,true
package.preload['weread.lib.native_direct_cache']=function() return {
    valid_entry=function(value,id,vid) return valid and value.book_id==id and vid=='123' end,
    identify=function(_,vid,file,current) return exists and vid=='123' and file==path and current() and entry or nil end,
    open=function(_,vid,id,value,current)
        if exists and vid=='123' and id=='42' and value.key==entry.key and current() then
            return {path=path,book_version=2,file_id=entry.file_id,source_sha256=entry.source_sha256} end
    end,
} end
package.preload['weread.lib.book_file_identity']=function() return {read_document=function(doc) return doc.identity end} end
local Resume=require('weread.ui.native_home_resume')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local function fixture()
    valid,exists=true,true
    local state={scope={vid='123',epoch=1},owner=owner,jobs={},book={book_id='42',title='Book',_library_account_key=owner}}
    local doc={file=path,identity={book_id='42',book_version=2,file_id=entry.file_id}}
    local host={ui={document=doc},_reader_session_gen=1,client={},
        settings={data_dir='/tmp/test',get_auth_scope=function() return state.scope end,
            auth_scope_matches=function(_,s) return s==state.scope end,
            get_book=function(_,id) return id=='42' and state.book end,
            patch_reading_state=function(_,id,patch)
                assert(id=='42');state.patches=(state.patches or 0)+1
                for k,v in pairs(patch) do state.book[k]=v end;return true
            end},
        library_db={accountKey=function() return state.owner end},
        showBusy=function(self,_,cancel) self.busy_message={};state.cancel=cancel end,
        closeBusy=function(self) self.busy_message=nil end,
        showInfo=function(_,message) state.message=message end,
        openFile=function(_,file) state.path=file end,
        _native_home_resume_worker={start=function(_,task,callback)
            state.jobs[#state.jobs+1]={task=task,callback=callback};return true end,cancel=function() end}}
    function state.finish(n) local j=state.jobs[n];j.callback(j.task()) end
    return host,state
end
local host,s=fixture()
expect(Resume.record(host),'valid native reader not recorded');s.finish(1)
expect(s.patches==1 and s.book.home_recent_account==owner and s.book.native_home_resume.entry==entry,
    'verified chapter did not produce an account-bound home event')
local view={};host.shelf_view=view
expect(Resume.can_resume(host,s.book,'42') and Resume.open(host,s.book,'42',view,function() return true end),
    'native home resume did not start');s.finish(2)
expect(s.path==path and not host.busy_message,'verified chapter did not open')
host,s=fixture();Resume.record(host);host.ui.document.identity.file_id='wrong';s.finish(1)
expect(not s.patches,'mismatched open document recorded')
host,s=fixture();Resume.record(host);s.owner='other';s.finish(1)
expect(not s.patches,'old account recorded a chapter')
host,s=fixture();Resume.record(host);s.book.home_recent_at=os.time()+10;s.finish(1)
expect(not s.patches,'older worker replaced a newer home event')
host,s=fixture();Resume.record(host);s.finish(1);host.shelf_view=view
Resume.open(host,s.book,'42',view,function() return true end);exists=false;s.finish(2)
expect(not s.path and s.message and not host.busy_message,'damaged chapter was opened or failed silently')
host,s=fixture();Resume.record(host);s.finish(1);host.shelf_view=view
Resume.open(host,s.book,'42',view,function() return true end);local value=s.jobs[2].task();s.owner='other';s.jobs[2].callback(value)
expect(not s.path,'account change opened a cached chapter')
host,s=fixture();Resume.record(host);s.finish(1);host.shelf_view=view
Resume.open(host,s.book,'42',view,function() return true end);local old=s.jobs[2];local result=old.task()
Resume.cancel(host);Resume.open(host,s.book,'42',view,function() return true end);old.callback(result)
expect(host._native_home_resume~=nil and not s.path,'old completion cancelled a newer request')
s.finish(3);expect(s.path==path,'new request was cancelled by an old completion')
host,s=fixture();Resume.record(host);s.finish(1);host.shelf_view=view
Resume.open(host,s.book,'42',view,function() return true end);local checked=s.jobs[2].task()
s.book.native_home_resume={at=s.book.home_recent_at,entry={book_id='42',chapter_uid='2',key=entry.key,
    copy=0,file_id=entry.file_id,book_version=2,source_sha256=entry.source_sha256}}
s.jobs[2].callback(checked)
expect(not s.path and s.message,'changed resume pointer opened an old chapter')
host,s=fixture();Resume.record(host);s.finish(1);s.book.home_recent_account='other'
expect(not Resume.can_resume(host,s.book,'42'),'other account home pointer accepted')
host,s=fixture();Resume.record(host);s.finish(1);host._book_detail_view=view
expect(Resume.open_detail(host,s.book,'42',view),'detail resume did not start');s.finish(2)
expect(s.path==path and not host.busy_message,'detail did not open verified saved chapter')
host,s=fixture();Resume.record(host);s.finish(1);host._book_detail_view=view
Resume.open_detail(host,s.book,'42',view);local detail_job=s.jobs[2];local detail_result=detail_job.task()
host._book_detail_view={};detail_job.callback(detail_result)
expect(not s.path,'closed or replaced detail opened the old chapter')
host,s=fixture();Resume.record(host);s.finish(1);host._book_detail_view=view
Resume.open_detail(host,s.book,'42',view);exists=false;s.finish(2)
expect(not s.path and s.message and not host.busy_message,'damaged detail chapter was opened or failed silently')
print('PASS: native home recording and verified offline resume ('..checks..' checks)')
