package.path='./?.lua;'..package.path
local destination='/body/DocFragment[2]/body/p/text().1'
local resolved=true
local catalog_complete=true
local info={mode='file',dev=1,ino=1,size=200,modification=2}
package.preload['libs/libkoreader-lfs']=function() return {symlinkattributes=function() return info end} end
package.preload['weread.lib.source_dom']=function() return {chapter_start=function(_,_,uid)
    return resolved and uid=='4' and destination or nil
end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(value) return value end} end
package.preload['weread.lib.chapter_cache_claim']=function() return {document_complete=function() return catalog_complete end} end
local Navigation=require('weread.ui.combined_chapter_navigation')
local epoch,owner=1,'user'
local function settings() return {get_book=function() return {} end,
    get=function(_,key,default) if key=='auth_epoch' then return epoch end;return default end,
    get_auth_scope=function() return {epoch=epoch} end,auth_scope_matches=function(_,scope) return scope.epoch==epoch end} end
local function doc(path)
    return {file=path,point='old',isXPointerInDocument=function(_,p) return p==destination end,
        isXPointerInCurrentPage=function(self,p) return self.point==p end}
end
local function reader(path)
    local value={document=doc(path),link={addCurrentLocationToStack=function(self) self.added=true end}}
    value.rolling={onGotoXPointer=function(_,point) value.document.point=point end}
    return value
end
local old=reader('/full.epub')
local calls={}
local host={ui=old,_reader_session_gen=3,settings=settings(),library_db={accountKey=function() return owner end},
    ensureChaptersLoaded=function() return {} end,
    progress_sync={begin_local_navigation=function() calls.local_nav=(calls.local_nav or 0)+1 end},
    closeWeReadUI=function() calls.close=(calls.close or 0)+1 end,showInfo=function(_,text) calls.message=text end}
local book,chapter={book_id='123'},{chapterUid=4}
local proof={opf_hash=string.rep('a',64)}
assert(Navigation.open(host,book,chapter,'/full.epub',function() return true end,proof))
assert(old.document.point==destination and old.link.added and calls.close==1 and calls.local_nav==1)
resolved=false;old.document.point='old';assert(not Navigation.open(host,book,chapter,'/full.epub',function() return true end,proof))
assert(old.document.point=='old' and calls.close==1 and calls.message,'unverified chapter moved the reader')
resolved=true;assert(not Navigation.open(host,book,chapter,'/full.epub',function() return false end,proof))
assert(old.document.point=='old' and calls.close==1,'stale selection moved the reader')
host.progress_sync={begin_file_resume=function(_,options) assert(options.partial_combined);calls.partial_begin=true;return 'partial' end,
    finish_file_resume=function(_,frame,applied) calls.partial_finished=frame=='partial' and applied;return true end}
host.showTransientInfo=function(_,value) calls.partial_notice=value end
assert(Navigation.open(host,book,chapter,'/full.epub',function() return true end,proof,true))
assert(calls.partial_begin and calls.partial_finished and calls.partial_notice,'partial same-file selection did not pause syncing')
calls.partial_begin=nil;catalog_complete=false
assert(Navigation.open(host,book,chapter,'/full.epub',function() return true end,proof))
assert(calls.partial_begin,'changed catalog did not pause syncing')
catalog_complete=true
local saved_callback
host.ui=reader('/single.epub');host._reader_session_gen=5
host.progress_sync={checkpoint_local=function() calls.checkpoint=true end,
    begin_file_resume_departure=function() calls.departure=true end}
host.openFile=function(_,path,callback) assert(path=='/full.epub');saved_callback=callback end
assert(Navigation.open(host,book,chapter,'/full.epub',function() return true end,proof))
assert(calls.checkpoint and calls.departure and saved_callback)
local next_reader=reader('/full.epub')
local sync={navigation_generation=0,begin_file_resume=function() calls.begin=true;return 'frame' end,
    finish_file_resume=function(_,frame,applied) calls.finished=frame=='frame' and applied;return true end}
next_reader.weread={settings=settings(),library_db={accountKey=function() return owner end},progress_sync=sync,
    ensureChaptersLoaded=function() return {} end,
    detectWeReadBook=function() return '123' end,showInfo=function(_,text) calls.message=text end}
host._reader_session_gen=6
assert(saved_callback(next_reader) and next_reader.document.point==destination and calls.begin and calls.finished)
next_reader.document.point='old';assert(not saved_callback(next_reader) and next_reader.document.point=='old','handoff replayed')
host._reader_session_gen=5;calls.begin=nil;saved_callback=nil
assert(Navigation.open(host,book,chapter,'/full.epub',function() return true end,proof))
host._reader_session_gen=6;epoch=2;assert(not saved_callback(next_reader) and not calls.begin,'changed account accepted handoff')
epoch=1;host._reader_session_gen=5;saved_callback=nil
assert(Navigation.open(host,book,chapter,'/full.epub',function() return true end,proof))
host._reader_session_gen=6;sync.pending_jump={};assert(not saved_callback(next_reader) and not calls.begin,'pending navigation overwritten')
sync.pending_jump=nil;host._reader_session_gen=5;saved_callback=nil
assert(Navigation.open(host,book,chapter,'/full.epub',function() return true end,proof))
host._reader_session_gen=6;info={mode='file',dev=1,ino=2,size=200,modification=2}
assert(not saved_callback(next_reader) and not calls.begin,'replaced file accepted')
print('combined_chapter_navigation_spec: same-file, one-use handoff and stale guards passed')
