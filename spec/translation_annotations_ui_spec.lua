package.path='./?.lua;'..package.path
local state,queue
local function copy(row) local out={};for k,v in pairs(row) do out[k]=v end;return out end
local UI={scheduleIn=function(_self,_delay,fn) queue[#queue+1]=fn end,
    unschedule=function(_self,fn) for i,v in ipairs(queue) do if v==fn then queue[i]=false end end end}
package.preload['ui/uimanager']=function() return UI end
package.preload['ui/event']=function() return {new=function(_self,name,value) return {name=name,value=value} end} end
package.loaded['weread.lib.plugin_util']={tr=function(x) return x end,
    T=function(x,...) local a={...};return (x:gsub('%%(%d+)',function(i) return tostring(a[tonumber(i)]) end)) end}
package.loaded['weread.lib.source_dom']={member=function(_doc,xp) return {render_path=xp:find('other',1,true) and 'other' or 'chapter'} end}
package.loaded['weread.lib.position_source']={MAX_META_BYTES=4096,document_metadata=function(_doc,_book,uid,path)
    if path=='other' then return {chapter_uid='2',metadata='meta2'} end
    return {chapter_uid=uid or '1',metadata='meta1'}
end}
package.loaded['weread.lib.translation_fetch']={MAX_ANNOTATIONS=500,MAX_ANNOTATION_CHAPTERS=64,
    saved=function() return state.saved end,plan_annotations=function(_input,_path,items) state.refs=items;return state.plan end}
package.loaded['weread.lib.book_file_identity']={read_document=function() return {file_id=string.rep(state.wrong_target_identity and 'c' or 'b',64)} end}
package.preload['libs/libkoreader-lfs']=function() return {symlinkattributes=function() return state.file end} end
package.loaded['weread.ui.translation_fetch']={
    saved_entry=function() return state.entry,state.owner,state.file_initial end,
    is_current=function() return state.current end,
    open_copy=function(_host,_owner,_path,_result,callback)
        state.opens=state.opens+1;if state.mutate_on_open then state.file.modification=2 end
        callback(state.target,state.target_host);return true
    end}
local M=require('weread.ui.translation_annotations')
local checks=0
local function expect(v,msg) checks=checks+1;assert(v,msg) end
local function document()
    return {file='/book/original.epub',getNormalizedXPointer=function(_self,xp)
            return state.canonicalize and (xp:gsub('text%(%)%[1%]','text()')) or xp
        end,
        getTextFromXPointer=function() return state.changed_node and 'changed' or 'exact node text' end,
        getTextFromXPointers=function() return state.changed_quote and 'changed' or 'exact selection' end,
        clearSelection=function() end,isXPointerInDocument=function() return not state.bad_target end,
        compareXPointers=function() return 1 end}
end
local function fixture()
    queue={}
    local doc=document()
    local rows={{page='/body/DocFragment[1]/body/p[1]/text().0',pos0='/body/DocFragment[1]/body/p[1]/text().0',
        pos1='/body/DocFragment[1]/body/p[1]/text().8',drawer='underscore',color='yellow',text='text',note='private note',datetime='2026-01-01'},
        {page='/body/DocFragment[1]/body/p[2]/text().0',text='bookmark'}}
    local info={mode='file',ino=2,dev=1,size=50,modification=1}
    state={current=true,file=copy(info),file_initial=copy(info),entry={path='/book/copy.epub',file_id=string.rep('b',64),bytes=50},
        owner={document=doc,book_id='42',file=doc.file,source={chapter_uid='1',metadata='meta1',identity={file_id=string.rep('a',64)}},
            location={xpointer='/body/DocFragment[1]/body/p[1]/text().0'}},
        saved={ok=true,file_id=string.rep('b',64),bytes=50,target='/body/DocFragment[1]/body/p[1]'},
        plan={ok=true,total=2,mapped={{index=1,uid='1',first='/body/DocFragment[1]/body/p[3]/text().0',last='/body/DocFragment[1]/body/p[3]/text().8',last_uid='1'},
            {index=2,uid='1',first='/body/DocFragment[1]/body/p[4]/text().0'}}},opens=0,notices={},cancels=0,events={}}
    local target_doc=document();target_doc.file='/book/copy.epub'
    local annotation={annotations={}}
    function annotation:addItem(item) if state.add_error then error('error') end;self.annotations[#self.annotations+1]=item;return #self.annotations end
    local prefs={saveSetting=function(_self,_key,value) state.persisted=value end,flush=function() return not state.flush_failed end}
    state.target={document=target_doc,annotation=annotation,doc_settings=prefs,handleEvent=function(_self,event) state.events[#state.events+1]=event end}
    state.target_host={showInfo=function(_self,msg) state.notices[#state.notices+1]=msg end}
    local host={ui={document=doc,annotation={annotations=rows}},client={},closeWeReadUI=function() end,
        showBusy=function(self,_msg,cancel) self.busy_message={};state.dismiss=cancel end,
        closeBusy=function(self) self.busy_message=nil end,
        showInfo=function(_self,msg) state.notices[#state.notices+1]=msg end,
        translation_annotations_worker={start=function(_self,task,callback) state.task,state.callback=task,callback;return true end,
            cancel=function() state.cancels=state.cancels+1 end}}
    local function pump()
        while #queue>0 do local fn=table.remove(queue,1);if fn then fn() end end
    end
    local function deliver(value) state.callback(value or state.task()) end
    return host,pump,deliver
end
local host,pump,deliver=fixture()
expect(M.start(host),'annotation capture did not start');pump();deliver()
expect(state.opens==1 and #state.target.annotation.annotations==2,'matched highlight and bookmark were not copied')
expect(state.target.annotation.annotations[1].note=='private note' and state.target.annotation.annotations[1].color=='yellow','highlight content changed')
expect(#state.events==2 and state.events[1].name=='AnnotationsModified','reader annotation caches were not notified')
expect(#host.ui.annotation.annotations==2 and host.ui.annotation.annotations[1].note=='private note','original annotations changed')
host,pump,deliver=fixture()
host.ui.annotation.annotations[1].pos1='/body/DocFragment[2]/body/other[1]/text().8'
state.plan.mapped[1].last='/body/DocFragment[2]/body/other[1]/text().8';state.plan.mapped[1].last_uid='2'
M.start(host);pump();deliver()
expect(state.refs[1].last_uid=='2' and state.refs[1].last_metadata=='meta2','cross-chapter endpoint was not scoped')
expect(#state.target.annotation.annotations==2 and state.target.annotation.annotations[1].note=='private note',
    'verified cross-chapter highlight was not copied')
host,pump,deliver=fixture()
host.ui.annotation.annotations[1].pos1='/body/DocFragment[2]/body/other[1]/text().8'
state.plan.mapped[1].last='/body/DocFragment[2]/body/other[1]/text().8';state.plan.mapped[1].last_uid='2'
M.start(host);pump();state.changed_quote=true;deliver()
expect(#state.target.annotation.annotations==1 and state.target.annotation.annotations[1].text=='bookmark',
    'changed cross-chapter selection was copied')
host,pump,deliver=fixture()
host.ui.annotation.annotations[1].pos1='/body/DocFragment[2]/body/other[1]/text().8'
state.plan.mapped[1].last='/body/DocFragment[2]/body/other[1]/text().8';state.plan.mapped[1].last_uid='2'
M.start(host);pump();state.plan.mapped[1].last_uid='3';deliver()
expect(state.opens==0,'cross-chapter plan with wrong endpoint chapter was accepted')
host,pump,deliver=fixture();state.target.annotation.annotations[1]={page=state.plan.mapped[1].first,pos0=state.plan.mapped[1].first,
    pos1=state.plan.mapped[1].last,drawer='underscore',note='existing target'}
M.start(host);pump();deliver();expect(#state.target.annotation.annotations==2 and state.target.annotation.annotations[1].note=='existing target','existing target note was replaced or duplicated')
host,pump,deliver=fixture();state.canonicalize=true
state.target.annotation.annotations[1]={page=state.plan.mapped[1].first,pos0=state.plan.mapped[1].first,
    pos1=state.plan.mapped[1].last,drawer='underscore',note='existing target'}
state.plan.mapped[1].first=state.plan.mapped[1].first:gsub('text%(%)','text()[1]')
state.plan.mapped[1].last=state.plan.mapped[1].last:gsub('text%(%)','text()[1]')
M.start(host);pump();deliver();expect(#state.target.annotation.annotations==2 and state.target.annotation.annotations[1].note=='existing target',
    'equivalent native pointer spelling created a duplicate')
for _,change in ipairs({'source_change','file_change','cancel'}) do
    host,pump,deliver=fixture();M.start(host);pump()
    if change=='source_change' then host.ui.annotation.annotations[1].note='edited'
    elseif change=='file_change' then state.file.modification=2
    else state.dismiss() end
    deliver();expect(state.opens==0 and not host.translation_annotations_job,change..' accepted a late plan')
end
for _,change in ipairs({'bad_target','changed_node','changed_quote','add_error','flush_failed'}) do
    host,pump,deliver=fixture();M.start(host);pump();state[change]=true;deliver()
    if change=='add_error' or change=='flush_failed' then expect(#state.target.annotation.annotations==0,change..' left partial in-memory annotations')
    else expect(#state.target.annotation.annotations<2,change..' accepted unverified pointers') end
    expect(#host.ui.annotation.annotations==2,change..' changed original annotations')
    if change=='add_error' or change=='flush_failed' then expect(#state.events==0,change..' notified an uncommitted annotation') end
end
for _,change in ipairs({'mutate_on_open','wrong_target_identity'}) do
    host,pump,deliver=fixture();M.start(host);pump();state[change]=true;deliver()
    expect(state.opens==1 and #state.target.annotation.annotations==0,change..' accepted wrong translated file')
end
host,pump,deliver=fixture();M.start(host);pump();state.plan.mapped[2].index=1;deliver()
expect(state.opens==0,'duplicate plan entry was accepted')
host=fixture();for i=3,501 do host.ui.annotation.annotations[i]={page='x'} end
expect(not M.start(host) and not host.translation_annotations_job,'unbounded annotation list started')
host=fixture();host.ui.annotation.annotations.extra={page='x'}
expect(not M.start(host) and not host.translation_annotations_job,'non-array annotation data was accepted')
host,pump,deliver=fixture();M.start(host);pump();host.ui.annotation.annotations.extra={page='x'};deliver()
expect(state.opens==0 and not host.translation_annotations_job,'changed annotation structure accepted a late plan')
print('translation_annotations_ui_spec: '..checks..' checks')
