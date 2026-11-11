package.path='./?.lua;'..package.path
local Fixture=require('spec.helpers.thought_edit_fixture')
local codec=Fixture.codec();local Contract=require('weread.lib.mark_edit_contract')
local timers,jobs={},{}
local UI={setDirty=function() end,scheduleIn=function(_self,_delay,task) timers[#timers+1]=task end,
    unschedule=function(_self,task) for i=#timers,1,-1 do if timers[i]==task then table.remove(timers,i) end end end}
package.preload['ui/uimanager']=function() return UI end
package.preload.device=function() return {screen={scaleBySize=function(_self,n) return n end}} end
package.preload['ffi/blitbuffer']=function() return {Color8=function(n) return n end} end
local store={writes=0,write=function(self) self.writes=self.writes+1;return not self.fail end}
package.preload['weread.lib.my_cloud_marks_store']=function() return {new=function() return store end} end
package.preload['weread.lib.native_read_access']=function() return {capture=function() return {} end} end
package.preload['weread.lib.memory_worker']=function() return {new=function(_self,options)
    assert(options.max_bytes<=8*1024*1024)
    return {cancel=function() end,start=function(_worker,task,callback)
        local job={value=task(),callback=callback};jobs[#jobs+1]=job;return true
    end}
end} end
local chapter='7';local meta='metadata-1'
package.preload['weread.lib.position_source']=function() return {document_metadata=function()
    return {metadata=meta,chapter_uid=chapter,record={format='web_xhtml'}}
end} end
package.preload['weread.lib.source_dom']=function() return {member=function() return {render_path='OEBPS/text/c.xhtml'} end,
    open_prepared=function(_doc,_book,_metadata,options)
        return {locate_span=function(_self,first,last)
            if not options.is_current() then return end
            return {pos0=first.point,pos1=last.point,text='verified'}
        end}
    end}
end
local snapshot,loads
local function value(id)
    local result={schema=1,book_id='900001',fetched_at=1000,updated=codec:json_decode('[]'),chapters=codec:json_decode('[]')}
    result.updated[1]={bookmarkId=id,type=1,chapterUid=7,markText='A unique verified quotation.',range='12-39'}
    return result
end
snapshot=value('first');loads=0
package.preload['weread.lib.personal_mark_task']=function() return {BATCH=8,MAX_NATIVE_BYTES=1024,
    load=function(_client,_library,_book,_access,online) loads=loads+1;return {snapshot=snapshot,refreshed=online} end,
    prepare=function(_file,_book,metadata,rows)
        local result={metadata=metadata,rows={}}
        for i,row in ipairs(rows) do
            result.rows[i]={bookmarkId=row.bookmarkId,reference_hash=Contract.row_hash(row),first_anchor={point=i},last_anchor={point=i+1}}
        end
        return result
    end,
    verify=function(rows) local ids={};for i,row in ipairs(rows) do ids[i]=row.bookmarkId end;return ids end,
} end
for _i,name in ipairs({'weread.lib.position_source','weread.lib.source_dom','weread.lib.personal_mark_task',
    'weread.lib.my_cloud_marks_store','weread.lib.native_read_access','weread.lib.memory_worker'}) do package.loaded[name]=nil end
local Display=require('weread.ui.personal_marks')
local state={account='owner-a',valid=true,show=true,book='900001'}
local scope={vid='owner-a',epoch=1}
local notes={{text='native note'}}
local host={client=codec,_reader_session_gen=1,ui={highlight={},annotation={annotations=notes},
    document={file='/cached.epub',info={},getXPointer=function() return 'native-point' end,
        compareXPointers=function(_self,a,b) return a<b and 1 or a>b and -1 or 0 end},
    view={view_modules={},registerViewModule=function(self,key,view) self.view_modules[key]=view end}},
    settings={get=function() return {show_annotations=state.show} end,get_auth_scope=function() return scope end,
        auth_scope_matches=function() return state.valid end},
    library_db={accountKey=function() return state.account end},detectWeReadBook=function() return state.book end,
    isNetworkOnline=function() return true end}
local checks=0
local function expect(v,m) checks=checks+1;assert(v,m or ('check '..checks)) end
local function tick()
    if #timers>0 then table.remove(timers,1)();return true end
    if #jobs>0 then local j=table.remove(jobs,1);j.callback(j.value);return true end
end
local function drain() local n=0;while tick() do n=n+1;assert(n<200,'controller did not settle') end end
expect(Display.attach(host));drain()
expect(host._personal_marks.complete and #host._personal_marks.records==1,'cached/cloud highlight never completed')
expect(host._personal_marks.records[1].bookmarkId=='first' and Display.available(host))
expect(host.ui.annotation.annotations==notes and notes[1].text=='native note','native annotation array changed')
Display.detach(host);snapshot=value('stale');expect(Display.attach(host));expect(tick() and #jobs==1)
local stale=table.remove(jobs,1);local writes=store.writes
Display.pause(host);Display.changed(host,value('new'));stale.callback(stale.value);drain()
expect(store.writes==writes,'cancelled remote read overwrote confirmed mark cache')
expect(host._personal_marks.records[1].bookmarkId=='new','stale remote read replaced confirmed mark')
state.show=false;Display.update(host)
expect(not host._personal_marks.overlay.enabled,'hide did not disable own layer')
state.show=true;Display.update(host);drain()
expect(host._personal_marks.overlay.enabled and #host._personal_marks.records==1,'show failed to restore layer')
host._translation_mode='translated';Display.update(host)
expect(not host._personal_marks.overlay.enabled and not Display.available(host),'translated document exposed original ranges')
host._translation_mode='original';Display.update(host);drain()
expect(#host._personal_marks.records==1 and host._personal_marks.overlay.enabled)
host.ui.highlight.selected_text={};Display.changed(host,value('deferred'));expect(tick())
expect(#host._personal_marks.records==0 and #jobs==0,'DOM work ran over a live native selection')
host.ui.highlight.selected_text=nil;drain();expect(host._personal_marks.records[1].bookmarkId=='deferred')
Display.suspend(host);expect(not host._personal_marks.overlay.enabled)
Display.wake(host);drain();expect(host._personal_marks.overlay.enabled and #host._personal_marks.records==1)
chapter='8';meta='metadata-2';Display.update(host);drain()
expect(host._personal_marks.complete and #host._personal_marks.records==0 and not Display.available(host),'other chapter retained personal range')
chapter='7';meta='metadata-1';Display.update(host);expect(tick() and #jobs==1)
local other=table.remove(jobs,1);state.account='owner-b';Display.update(host);other.callback(other.value);drain()
expect(not Display.available(host) and not host._personal_marks.overlay.enabled,'old account range survived scope change')
state.account='owner-a';Display.detach(host)
expect(host._personal_marks==nil and host.ui.view.view_modules[Display.KEY]==nil,'close retained registered view')
expect(host.ui.annotation.annotations==notes and #notes==1 and loads==2,'unexpected reload or local note mutation')
store.fail=true;snapshot=value('fallback');expect(Display.attach(host));drain()
expect(loads==4 and host._personal_marks.records[1].bookmarkId=='fallback','failed fresh cache save lost offline display')
Display.detach(host)
print('personal_marks_spec: '..checks..' checks passed')
