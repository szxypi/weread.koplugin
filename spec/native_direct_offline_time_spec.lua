package.path='./?.lua;./?/init.lua;'..package.path
local helper=require('spec.helpers.annotation_test_store')
package.preload['lua-ljsqlite3/init']=function() return {open=helper.connect} end
package.preload['ui/uimanager']=function() return {} end
local jobs={}
package.preload['weread.lib.memory_worker']=function() return {new=function() return {
    start=function(_self,task,callback) jobs[#jobs+1]={task=task,callback=callback};return true end,
    cancel=function() end,
} end} end
local entry
package.preload['weread.lib.native_direct_cache']=function() return {identify=function(_settings,vid,_file,current)
    return vid=='123' and current() and entry or nil
end} end
local Crypto=require('weread.lib.crypto')
local Identity=require('weread.lib.book_file_identity')
local Collector=require('weread.lib.offline_time')
local C=require('weread.lib.readtime_transfer_contract')
local Direct=require('weread.lib.native_direct_offline_time')
local root=os.tmpname()..'-direct-time';assert(os.execute('mkdir -p '..string.format('%q',root))==0)
local book={book_id='42',bookVersion=7}
local raw=Identity.encode(book,{{}},Identity.capture(book),string.rep('b',64))
local identity=assert(Identity.decode(raw))
entry={book_id='42',file_id=identity.file_id,book_version=7}
local file=root..'/native-reader-v1/synthetic/book.epub'
local document={file=file,getDocumentFileContent=function() return raw end}
local stats={id_curr_book=1,page_stat={},settings={},isEnabledAndNotFrozen=function() return true end}
local enabled=true;local vid='123';local epoch=1
local settings={data_dir=root,get=function(_self,key) if key=='offline_time' then return {enabled=enabled} end return {} end,
    get_auth_scope=function() return {vid=vid,epoch=epoch} end,
    auth_scope_matches=function(_self,scope) return scope.vid==vid and scope.epoch==epoch end}
local function account() return Crypto.sha256_hex('weread-library:'..vid):sub(1,20) end
local host={settings=settings,ui={document=document,statistics=stats},client={},_reader_session_gen=1,
    library_db={accountKey=function() return account() end}}
local scheduler={scheduleIn=function() end,unschedule=function() end}
local now=1000
local source={available=function() return true end,snapshot=function() return {{page='1',start_time=1000,duration=now-1000}} end,
    persisted=function() return {} end}
local service=Collector:new{settings=settings,library_db=host.library_db,scheduler=scheduler,
    get_context=function() return Direct.context(host,true) end,is_online=function() return false end,
    clock=function() return {wall=now,monotonic=now,zone='+08:00'} end,source=source}
host.offline_time=service
assert(service:start() and service.state=='native_time_checking' and not service.active)
local first=jobs[1];first.callback(first.task())
assert(service.active and service.state=='recording','verified chapter did not start offline collection')
now=1010;assert(service:update('timer'))
local rows=assert(service.store:pending(account()))
assert(#rows==1 and rows[1].duration==10 and rows[1].version_source=='native_direct')
assert(rows[1].file_id==identity.file_id and rows[1].book_id=='42' and rows[1].book_version==7)
assert(not C.verified(rows[1],now),'native chapter time entered ordinary transfer queue')
assert(service:update('timer') and service:status().pending==10,'same interval was captured twice')
assert(service:pause());now=1020
assert(service:status().pending==10,'paused time was recorded')
-- A late worker result cannot resume a paused collector or attach another account.
Direct.cancel(host);service:start();local late=jobs[#jobs];assert(service:pause())
late.callback(late.task());assert(service.paused and not service.active)
vid='456';epoch=2;service:start();local other=jobs[#jobs]
other.callback(other.task());assert(not service.active and service.state=='native_time_unavailable',
    'foreign account unexpectedly resolved synthetic entry')
vid='123';epoch=3;service:start();local stale=jobs[#jobs];local result=stale.task()
host._reader_session_gen=host._reader_session_gen+1;stale.callback(result)
assert(not service.active,'late chapter proof entered a new reader session')
service:start();local mismatched=jobs[#jobs];result=mismatched.task();result.file_id=string.rep('c',64)
mismatched.callback(result)
assert(not service.active and service.state=='native_time_unavailable','different open EPUB identity was accepted')
Direct.cancel(host);service:start();local disabled=jobs[#jobs];result=disabled.task();enabled=false
disabled.callback(result);assert(not service.active and host._native_offline_time==nil,'disabled capture accepted a late result')
print('PASS: native offline time is local, account-bound and excluded from ordinary transfer')
