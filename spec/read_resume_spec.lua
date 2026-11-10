package.path='./?.lua;'..package.path
package.preload['ui/uimanager']=function() return {} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(value) return value end} end
local Resume=require('weread.ui.read_resume')
local Source=require('weread.lib.position_source')
local Identity=require('weread.lib.book_file_identity')
local Crypto=require('weread.lib.crypto')
local checks=0
local function expect(value,why) checks=checks+1;assert(value,why) end
local function copy(value)
    if type(value)~='table' then return value end
    local result={};for key,item in pairs(value) do result[key]=copy(item) end;return result
end
local id,uid='900001','2'
local raw='Original <tag>&amp;😀 source bytes for a local reading transfer.'
local function fixture(format,version,salt,original)
    local book,chapter={book_id=id,bookVersion=version},{chapterUid=2}
    local captured=assert(Source.capture(book,chapter,original or raw,format))
    local root=Identity.encode(book,{chapter},Identity.capture(book),Crypto.sha256_hex(salt))
    local identity=assert(Identity.decode(root))
    local path='OEBPS/text/chapter-002.xhtml'
    local metadata=assert(Source.bind(captured,identity,path,Crypto.sha256_hex('rendered '..salt)))
    local position={book_id=id,chapter_uid=uid,chapter_offset=20,file_id=identity.file_id,book_version=version,
        raw_sha256=captured.raw_sha256,render_path=path,basis=Source.coordinate_basis(format),upload_verified=false}
    local calls=0
    local doc={file='/new.epub',getDocumentFileContent=function(_self,name)
        calls=calls+1
        if name==Identity.PATH then return root end
        if name==Source.meta_path(uid) or name==Source.path_meta_path(path) then return metadata end
        error('raw source must not be read on the UI thread')
    end}
    function doc:getCurrentPage() return 1 end
    function doc:getCurrentPos() return 0 end
    function doc:getPageXPointer() return '/body/DocFragment[1]/body/p/text().0' end
    function doc:getNormalizedXPointer(point) return point end
    return position,doc,function() return calls end
end
for _i,format in ipairs({'web_xhtml','web_txt'}) do
    local old=fixture(format,7,'old')
    local new,doc,calls=fixture(format,8,'new')
    local target,why=Resume.bind(doc,old)
    expect(target,why)
    expect(target.file_id==new.file_id and target.book_version==8 and target.chapter_offset==20,'new package identity/source point not bound')
    expect(target.raw_sha256==old.raw_sha256 and target.basis==old.basis and not target.upload_verified,'raw coordinate meaning changed')
    expect(calls()<=4,'UI binding read too many metadata members')
    expect(select(2,Resume.bind(doc,new))=='same_file','same package tried to replace native position')
    local changed_doc=select(2,fixture(format,8,'changed',raw..'changed'))
    expect(select(2,Resume.bind(changed_doc,old))=='source_changed','changed original bytes were rebound')
    local other_doc=select(2,fixture(format=='web_txt' and 'web_xhtml' or 'web_txt',7,'other'))
    expect(select(2,Resume.bind(other_doc,old))=='source_changed','different coordinate basis was rebound')
end
local original=fixture('web_xhtml',7,'old')
for _i,change in ipairs({{book_id='900002'},{chapter_uid=''},{chapter_uid='bad\nuid'},{chapter_offset=-1},
    {chapter_offset=0/0},{chapter_offset=math.huge},{chapter_offset=0.5},{book_version=-1},
    {file_id='wrong'},{raw_sha256='wrong'},{basis='catalog_words'},{upload_verified=true},
    {render_path=string.rep('x',1025)}}) do
    local value=copy(original);for key,item in pairs(change) do value[key]=item end
    expect(not Resume.position(value,id),'invalid local source point accepted')
end
expect(not Resume.position({book_id=nil},nil),'missing identity accepted')
expect(not Resume.bind({},true),'malformed source descriptor accepted')
local book={book_id=id,pending_upload_position={book_id=id,chapter_uid=uid,source_position=original},pending_upload_account='owner',
    last_local_position={book_id=id,chapter_uid=uid,source_position=original},recent_read_account='owner'}
expect(Resume.from_book(book,'owner').chapter_offset==20,'stored local source was not selected')
local invalid=copy(book);invalid.pending_upload_position.source_position=nil
expect(not Resume.from_book(invalid,'owner'),'missing newer source revived an older source')
invalid=copy(book);invalid.pending_upload_account='other';invalid.last_local_position.source_position.chapter_offset=21
expect(Resume.from_book(invalid,'owner').chapter_offset==21,'foreign pending point displaced current account recent point')
invalid=copy(book);invalid.pending_upload_position.chapter_uid='4'
expect(not Resume.from_book(invalid,'owner'),'contradictory local/source chapter accepted')
invalid=copy(book);invalid.pending_upload_position.book_id='900002';invalid.last_local_position.source_position.chapter_offset=21
expect(Resume.from_book(invalid,'owner').chapter_offset==21,'foreign book pending point accepted')

local function hosts(live,selected_book)
    local new,doc=fixture('web_xhtml',8,'new')
    local state={owner='owner',epoch=1,clock=10,opens=0,finished=0,started=0,departures=0,checkpoints=0}
    local settings={get_auth_scope=function() return {vid='900000',epoch=state.epoch} end,
        auth_scope_matches=function(_self,auth) return auth.epoch==state.epoch end,
        get_book=function() return copy(selected_book or book) end}
    local parent={settings=settings,library_db={accountKey=function() return state.owner end},ui={},_reader_session_gen=0}
    local child={settings=settings,library_db=parent.library_db,ui={document=doc},_reader_session_gen=1,source_navigation={job={}}}
    child.progress_sync={navigation_generation=0,verified=false,begin_file_resume=function()
        state.started=state.started+1;return state
    end,finish_file_resume=function(_self,frame,applied)
        expect(frame==state,'wrong transition frame finished');state.finished=state.finished+1;state.applied=applied;return true
    end}
    function child:detectWeReadBook() return id end
    function child:openSourcePosition(target,callback) state.target=target;state.finish=callback;return true end
    function child:showTransientInfo() state.messages=(state.messages or 0)+1 end
    local dispatch=function(callback) state.opens=state.opens+1;state.callback=callback end
    if live then
        local old_doc=select(2,fixture('web_xhtml',7,'old'));old_doc.file='/old.epub'
        parent.ui={document=old_doc,view={view_mode='page'},rolling={xpointer='old-marker'}};parent._reader_session_gen=1
        function parent:detectWeReadBook() return id end
        parent.progress_sync={navigation_generation=0,checkpoint_local=function() state.checkpoints=state.checkpoints+1 end,
            begin_file_resume_departure=function() state.departures=state.departures+1 end}
        parent.source_position={current=function() return nil end,check=function(_self,callback) state.prepared=callback;return true end}
    end
    return parent,child,state,dispatch,{document=doc,weread=child},new
end
local parent,child,state,dispatch,reader,new=hosts()
expect(Resume.open(parent,'/new.epub',book,dispatch) and state.opens==1,'stored-source opening was not dispatched')
expect(state.callback(reader) and state.started==1 and state.target.file_id==new.file_id,'after-open callback did not bind the new package')
expect(not state.callback(reader),'one-use callback replayed')
state.finish(state.target)
expect(state.finished==1 and state.applied and not child._read_resume_active,'completed navigation was not finalized')
for _i,change in ipairs({'account','epoch','path','book','remote_intent','verified','generation','bad_reader','expired','superseded','cancelled'}) do
    parent,child,state,dispatch,reader=hosts();Resume.open(parent,'/new.epub',book,dispatch)
    local callback=state.callback
    if change=='account' then state.owner='other'
    elseif change=='epoch' then state.epoch=2
    elseif change=='path' then reader.document.file='/other.epub'
    elseif change=='book' then child.detectWeReadBook=function() return '900002' end
    elseif change=='remote_intent' then child.progress_sync.pending_jump={}
    elseif change=='verified' then child.progress_sync.verified=true
    elseif change=='generation' then child.progress_sync.navigation_generation=1
    elseif change=='bad_reader' then reader=true
    elseif change=='expired' then parent._read_resume_token.started=os.time()-121
    elseif change=='superseded' then Resume.open(parent,'/new.epub',book,dispatch)
    else Resume.cancel(parent) end
    local accepted=callback(reader)
    expect(not accepted and state.started==0,'stale after-open callback committed: '..change)
end
for _i,change in ipairs({'page','marker','account','close','cancel','session','new_sync'}) do
    local data={hosts(true)};parent,state,dispatch=data[1],data[3],data[4]
    Resume.open(parent,'/new.epub',book,dispatch)
    expect(state.opens==0 and state.prepared,'live source preparation was not asynchronous')
    if change=='page' then parent.ui.document.getCurrentPage=function() return 2 end;Resume.view_changed(parent)
    elseif change=='marker' then parent.ui.rolling.xpointer='new-marker';Resume.view_changed(parent)
    elseif change=='account' then state.owner='other'
    elseif change=='close' then Resume.on_close(parent)
    elseif change=='cancel' then Resume.cancel(parent)
    elseif change=='new_sync' then parent.progress_sync.navigation_generation=1
    else parent._reader_session_gen=2 end
    state.prepared(copy(original))
    expect(state.opens==0,'cancelled live preparation opened a file: '..change)
end
parent,child,state,dispatch,reader=hosts(true);Resume.open(parent,'/new.epub',book,dispatch)
state.prepared(copy(original));expect(state.opens==1 and state.checkpoints==1 and state.departures==1,'live point was not checkpointed before opening')
Resume.on_close(parent);parent._reader_session_gen=2
expect(state.callback(reader),'expected old-reader close invalidated its own file handoff')
Resume.navigation_cancelled(child,child.source_navigation.job)
expect(state.finished==1 and state.applied==false and not child._read_resume_active,'cancelled source navigation left transition pending')
local storage_data={hosts(true)};parent,state,dispatch=storage_data[1],storage_data[3],storage_data[4]
Resume.open(parent,'/new.epub',book,dispatch)
parent.progress_sync.checkpoint_local=function() error('synthetic storage failure') end
state.prepared(copy(original));expect(state.opens==1 and not state.callback,'storage failure left a deferred open stuck')
parent,child,state,dispatch,reader=hosts();Resume.open(parent,'/new.epub',book,dispatch)
child.progress_sync.begin_file_resume=function() error('synthetic storage failure') end
expect(not state.callback(reader) and state.messages==1,'transition initialization failure escaped the reader callback')
parent,child,state,dispatch,reader=hosts();Resume.open(parent,'/new.epub',book,dispatch)
function child:showInfo() state.save_message=true end
child.progress_sync.finish_file_resume=function() error('synthetic flush failure') end
assert(state.callback(reader));state.finish(state.target)
expect(state.save_message and not child._read_resume_active,'successful jump with a save failure was silently reported')
local numeric_id=id
id='CB_SyntheticResume'
for _i,format in ipairs({'web_xhtml','web_txt'}) do
    local old=fixture(format,7,'cb-old')
    local target_doc=select(2,fixture(format,8,'cb-new'))
    local target=assert(Resume.bind(target_doc,old))
    expect(target.book_id==id and target.chapter_offset==old.chapter_offset and target.raw_sha256==old.raw_sha256
        and target.basis==old.basis and target.upload_verified==false,'CB binding changed local units or upload rights')
    local cb_book={book_id=id,last_local_position={book_id=id,chapter_uid=uid,source_position=old},recent_read_account='owner'}
    expect(Resume.from_book(cb_book,'owner').raw_sha256==old.raw_sha256,'CB saved source position was skipped')
    if format=='web_xhtml' then
        parent,child,state,dispatch,reader=hosts(false,cb_book)
        expect(Resume.open(parent,'/new.epub',cb_book,dispatch) and state.callback,'CB stored handoff bypassed preparation')
        expect(state.callback(reader) and state.target.book_id==id,'CB new reader did not bind its own source')
        state.finish(state.target)
        expect(state.applied and state.finished==1 and not child._read_resume_active,'CB stored handoff did not finalize')
        parent,child,state,dispatch,reader=hosts(true,cb_book)
        Resume.open(parent,'/new.epub',cb_book,dispatch);state.prepared(copy(old));parent._reader_session_gen=2
        expect(state.callback(reader) and state.checkpoints==1 and state.departures==1,'CB live point was not transferred after closing')
        state.finish(state.target)
        expect(not child._read_resume_active,'CB live transition retained its active frame')
        local cancelled={hosts(true,cb_book)};parent,state,dispatch=cancelled[1],cancelled[3],cancelled[4]
        Resume.open(parent,'/new.epub',cb_book,dispatch);state.owner='other';state.prepared(copy(old))
        expect(state.opens==0,'CB account replacement opened a stale handoff')
    end
end
for _i,bad_id in ipairs({'CB_','CB_'..string.rep('a',65),'CB_a/b','CB_a?x=1','CB_a_b','MP_WXS_synthetic'}) do
    local candidate=fixture('web_xhtml',7,'bad');candidate.book_id=bad_id
    expect(not Resume.position(candidate,bad_id) and not Resume.from_book({book_id=bad_id},'owner'),
        'invalid CB local handoff identity accepted')
end
id=numeric_id
print(('read_resume_spec: %d checks'):format(checks))
