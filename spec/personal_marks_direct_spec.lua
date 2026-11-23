package.path='./?.lua;'..package.path
local Fixture=require('spec.helpers.thought_edit_fixture');local codec=Fixture.codec()
local Contract=require('weread.lib.mark_edit_contract')
local timers,jobs={},{}
local UI={setDirty=function() end,scheduleIn=function(_,_,task) timers[#timers+1]=task end,
    unschedule=function(_,task) for i=#timers,1,-1 do if timers[i]==task then table.remove(timers,i) end end end}
package.preload['ui/uimanager']=function() return UI end
package.preload.device=function() return {screen={scaleBySize=function(_,n) return n end}} end
package.preload['ffi/blitbuffer']=function() return {Color8=function(n) return n end} end
local state={owner='account-a',valid=true,online=true,source=true,entry_ok=true,show=true,identity=true,walk_failure=false,searches=0}
local scope={vid='123',epoch=1};local identity={book_id='41',book_version=7,file_id=string.rep('a',64),chapter_count=1}
local entry={book_id='41',book_version=7,file_id=identity.file_id,chapter_uid='2',key=string.rep('b',64),source_sha256=string.rep('c',64)}
local snapshot={schema=1,book_id='41',fetched_at=1000,updated=codec:json_decode('[]'),chapters=codec:json_decode('[]')}
snapshot.updated[1]={bookmarkId='first',type=1,chapterUid=2,markText='Unique quotation',range='15-31'}
local store={write=function() return true end}
package.preload['weread.lib.my_cloud_marks_store']=function() return {new=function() return store end} end
package.preload['weread.lib.native_read_access']=function() return {capture=function() return {} end} end
package.preload['weread.lib.memory_worker']=function() return {new=function()
    return {cancel=function() end,start=function(_,task,callback)
        local ok,value=pcall(task);jobs[#jobs+1]={value=ok and value or {error='unavailable'},callback=callback};return true
    end}
end} end
package.preload['weread.lib.native_direct_path']=function() return {contains=function(_,file) return file=='/direct.epub' end} end
package.preload['weread.lib.book_file_identity']=function() return {PATH='identity',decode=function()
    return state.identity and identity or nil
end,read_document=function() return state.identity and identity or {} end} end
package.preload['weread.lib.native_direct_cache']=function() return {identify=function(_,vid,file,current)
    assert(vid=='123' and file=='/direct.epub' and current());return state.entry_ok and entry or nil
end,valid_entry=function(value,book,vid) return state.entry_ok and value==entry and book=='41' and vid=='123' end} end
package.preload['weread.lib.source_dom']=function() return {open_direct_prepared=function(_,book,uid,id,options)
    assert(book=='41' and uid=='2' and id==identity)
    return {locate_span=function(_,a,b)
        if state.walk_failure then return nil,'source_dom/walk_diverged' end
        if options.is_current() then return {pos0=a.point,pos1=b.point,text='Unique quotation'} end
    end,locate_span_search=function(_,a,b,quote)
        state.searches=state.searches+1;assert(quote=='Unique quotation')
        if options.is_current() then return {pos0=a.point,pos1=b.point,text=quote} end
    end,locate_anchor=function(_,a) return {xpointer=a.co,co=a.co} end}
end} end
local loads,prepares=0,0
package.preload['weread.lib.personal_mark_task']=function() return {BATCH=8,MAX_NATIVE_BYTES=1024,
    load=function(_,_,book,_,online) assert(book=='41');loads=loads+1;return {snapshot=snapshot,refreshed=online} end,
    prepare_direct=function(_,_,_,file,e,metadata,rows,online)
        assert(file=='/direct.epub' and e==entry and online==state.online);prepares=prepares+1
        if not state.source then error('missing cache') end
        return {metadata=metadata,rows={{bookmarkId=rows[1].bookmarkId,reference_hash=Contract.row_hash(rows[1]),
            first_anchor={point=1},last_anchor={point=2}}}}
    end,
    verify=function(rows) local ids={};for _,row in ipairs(rows) do ids[#ids+1]=row.bookmarkId end;return ids end,
} end
for _,name in ipairs({'weread.lib.my_cloud_marks_store','weread.lib.native_read_access','weread.lib.memory_worker',
    'weread.lib.native_direct_path','weread.lib.book_file_identity','weread.lib.native_direct_cache','weread.lib.source_dom',
    'weread.lib.personal_mark_task'}) do package.loaded[name]=nil end
local Display=require('weread.ui.personal_marks')
local host={client=codec,_reader_session_gen=1,settings={get=function() return {show_annotations=state.show} end,
    get_auth_scope=function() return scope end,auth_scope_matches=function(_,s) return state.valid and s==scope end},
    library_db={accountKey=function() return state.owner end},detectWeReadBook=function() return nil end,
    isNetworkOnline=function() return state.online end,ui={highlight={},document={file='/direct.epub',info={},
        getDocumentFileContent=function() return 'identity' end,compareXPointers=function(_,a,b) return a<b and 1 or a>b and -1 or 0 end},
        view={view_modules={},registerViewModule=function(self,key,value) self.view_modules[key]=value end}}}
local checks=0
local function expect(v,m) checks=checks+1;assert(v,m or ('check '..checks)) end
local function tick()
    if #timers>0 then table.remove(timers,1)();return true end
    if #jobs>0 then local j=table.remove(jobs,1);j.callback(j.value);return true end
end
local function drain() local n=0;while tick() do n=n+1;assert(n<200) end end
expect(Display.attach(host),'direct chapter not attached');drain()
expect(host._personal_marks.direct and host._personal_marks.complete and #host._personal_marks.records==1,'verified direct highlight missing')
expect(loads==1 and prepares==1 and Display.available(host))
state.walk_failure=true;Display.changed(host,snapshot);drain()
expect(state.searches==1 and #host._personal_marks.records==1,'verified fallback was not used after cursor divergence')
state.walk_failure=false
local empty={schema=1,book_id='41',fetched_at=1000,updated=codec:json_decode('[]'),chapters=codec:json_decode('[]')}
Display.changed(host,empty);drain()
expect(host._personal_marks.complete and #host._personal_marks.records==0,'deleted highlight remained visible')
Display.changed(host,snapshot);drain()
expect(host._personal_marks.complete and #host._personal_marks.records==1,'confirmed highlight did not reappear')
Display.detach(host);state.online=false;expect(Display.attach(host));drain()
expect(#host._personal_marks.records==1 and loads==2,'offline cached source not shown')
state.online=true;Display.network_connected(host);drain();expect(loads==3 and #host._personal_marks.records==1,'reconnect did not refresh')
state.show=false;Display.update(host);local before_hidden=loads;Display.network_connected(host);drain()
expect(loads==before_hidden,'hidden annotations triggered a network refresh')
state.show=true;Display.update(host);drain();expect(#host._personal_marks.records==1,'visible annotations did not recover')
Display.pause(host);Display.changed(host,snapshot);expect(tick() and #jobs==1)
local stale=table.remove(jobs,1);state.owner='account-b';Display.update(host);stale.callback(stale.value);drain()
expect(not Display.available(host) and not host._personal_marks.overlay.enabled,'old account source displayed')
state.owner='account-a';Display.detach(host)
state.online=false;state.source=false;expect(Display.attach(host));drain()
expect(#host._personal_marks.records==0 and not host._personal_marks.complete,'missing offline source displayed')
state.online=true;state.source=true;Display.network_connected(host);drain()
expect(#host._personal_marks.records==1 and host._personal_marks.complete,'reconnect did not recover missing source')
Display.detach(host);state.entry_ok=false
expect(Display.attach(host));drain();expect(#host._personal_marks.records==0 and not Display.available(host),'unverified entry displayed')
Display.detach(host);state.entry_ok=true;state.identity=false;expect(not Display.attach(host),'missing file identity accepted')
print('personal_marks_direct_spec: '..checks..' checks passed')
