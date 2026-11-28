-- Explicit local copy of verifiable KOReader annotations to a translated EPUB.
-- No cloud writes; the original annotations and file are never modified.
local Fetch=require('weread.ui.translation_fetch')
local Core=require('weread.lib.translation_fetch')
local Dom=require('weread.lib.source_dom')
local Source=require('weread.lib.position_source')
local Identity=require('weread.lib.book_file_identity')
local UI=require('ui/uimanager')
local _,T=require('weread.lib.plugin_util').tr,require('weread.lib.plugin_util').T
local M={MAX_BYTES=2*1024*1024}
local fields={'page','pos0','pos1','drawer','color','text','note','datetime','datetime_updated'}
local function stat(path) return require('libs/libkoreader-lfs').symlinkattributes(path) end
local function same_file(a,b)
    return a and b and a.mode=='file' and b.mode=='file' and a.ino==b.ino and a.dev==b.dev
        and a.size==b.size and a.modification==b.modification
end
local function snapshot(rows)
    if type(rows)~='table' or #rows>Core.MAX_ANNOTATIONS then return nil end
    local count=0
    for index in pairs(rows) do
        if type(index)~='number' or index%1~=0 or index<1 or index>#rows then return nil end
        count=count+1
    end
    if count~=#rows then return nil end
    local out={}
    for index,row in ipairs(rows) do
        if type(row)~='table' then return nil end
        local item={}
        for _,key in ipairs(fields) do item[key]=row[key] end
        out[index]=item
    end
    return out
end
local function unchanged(rows,old)
    if type(rows)~='table' or #rows~=#old then return false end
    local count=0
    for index in pairs(rows) do
        if type(index)~='number' or index%1~=0 or index<1 or index>#rows then return false end
        count=count+1
    end
    if count~=#rows then return false end
    for index,row in ipairs(rows) do
        if type(row)~='table' then return false end
        for _,key in ipairs(fields) do if row[key]~=old[index][key] then return false end end
    end
    return true
end
local function text(value,limit,optional)
    return optional and value==nil or type(value)=='string' and #value<=limit and not value:find('[%z\1-\8\11\12\14-\31\127]')
end
local function point(doc,book_id,xp)
    if not text(xp,4096) then return nil end
    local normalized=doc:getNormalizedXPointer(xp)
    if type(normalized)~='string' or not normalized:find('/text()',1,true) then return nil end
    local member=Dom.member(doc,normalized)
    local source=member and Source.document_metadata(doc,book_id,nil,member.render_path)
    local node=doc:getTextFromXPointer(normalized)
    if not source or not text(node,65536) or not text(source.metadata,Source.MAX_META_BYTES) then return nil end
    return {xp=normalized,node=node,uid=source.chapter_uid,metadata=source.metadata}
end
local function capture(doc,book_id,row)
    if not text(row.page,4096) or not text(row.text,65536,true) or not text(row.note,65536,true)
        or not text(row.datetime,128,true) or not text(row.datetime_updated,128,true)
        or not text(row.color,64,true) then return nil end
    local highlight=row.drawer~=nil and row.drawer~=false
    if highlight and (not text(row.drawer,64) or row.drawer=='') then return nil end
    local first=point(doc,book_id,highlight and row.pos0 or row.page)
    if not first then return nil end
    local item={first=first,highlight=highlight,row=row}
    if highlight then
        local last=point(doc,book_id,row.pos1)
        if not last or first.uid==last.uid and first.metadata~=last.metadata then return nil end
        local read,quote=pcall(doc.getTextFromXPointers,doc,first.xp,last.xp)
        if doc.clearSelection then pcall(doc.clearSelection,doc) end
        if not read or not text(quote,65536) or quote=='' or doc:compareXPointers(first.xp,last.xp)~=1 then return nil end
        item.last,item.quote=last,quote
    end
    return item
end
local function target_point(doc,book_id,uid,xp,node)
    if not doc:isXPointerInDocument(xp) then return false end
    local member=Dom.member(doc,xp)
    local source=member and Source.document_metadata(doc,book_id,uid,member.render_path)
    return source~=nil and doc:getTextFromXPointer(xp)==node
end
local function already_present(doc,rows,highlight,first,last)
    local wanted_first=doc:getNormalizedXPointer(first)
    local wanted_last=highlight and doc:getNormalizedXPointer(last) or nil
    if type(wanted_first)~='string' or highlight and type(wanted_last)~='string' then error('annotation/invalid_target',0) end
    for _,row in ipairs(rows) do
        if type(row)=='table' and (not not row.drawer)==highlight then
            local a=highlight and row.pos0 or row.page
            local b=highlight and row.pos1 or nil
            if type(a)=='string' and doc:getNormalizedXPointer(a)==wanted_first
                and (not highlight or type(b)=='string' and doc:getNormalizedXPointer(b)==wanted_last) then return true end
        end
    end
    return false
end
local function apply(reader,host,book_id,entry,info,captured,plan,skipped)
    local doc=reader and reader.document
    local annotations=reader and reader.annotation
    if not doc or doc.file~=entry.path or not same_file(stat(entry.path),info)
        or Identity.read_document(doc,book_id).file_id~=entry.file_id
        or not annotations or type(annotations.annotations)~='table' or not reader.doc_settings then
        host:showInfo(_('Could not copy the annotations. The original book and its notes are kept.'));return
    end
    local pending,existing={},0
    for _,mapped in ipairs(plan) do
        local item=captured[mapped.index]
        local ok,valid=pcall(function()
            if not item or item.first.uid~=mapped.uid or not target_point(doc,book_id,mapped.uid,mapped.first,item.first.node) then return false end
            if item.highlight then
                if not mapped.last or item.last.uid~=mapped.last_uid or not target_point(doc,book_id,mapped.last_uid,mapped.last,item.last.node)
                    or doc:compareXPointers(mapped.first,mapped.last)~=1 then return false end
                local read,quote=pcall(doc.getTextFromXPointers,doc,mapped.first,mapped.last)
                if doc.clearSelection then pcall(doc.clearSelection,doc) end
                if not read or quote~=item.quote then return false end
            end
            return true
        end)
        if not ok or not valid then skipped=skipped+1
        else
            local exists_ok,exists=pcall(function()
                return already_present(doc,annotations.annotations,item.highlight,mapped.first,mapped.last)
                    or already_present(doc,pending,item.highlight,mapped.first,mapped.last)
            end)
            if not exists_ok then skipped=skipped+1
            elseif exists then existing=existing+1
            else
                local row={page=mapped.first,text=item.row.text,note=item.row.note,datetime=item.row.datetime,
                    datetime_updated=item.row.datetime_updated}
                if item.highlight then row.pos0,row.pos1,row.drawer,row.color=mapped.first,mapped.last,item.row.drawer,item.row.color end
                if reader.toc and type(reader.toc.getTocTitleByPage)=='function' then
                    local found,chapter=pcall(reader.toc.getTocTitleByPage,reader.toc,mapped.first)
                    if found and type(chapter)=='string' and chapter~='' then row.chapter=chapter end
                end
                pending[#pending+1]=row
            end
        end
    end
    if #pending>0 then
        local previous={};for index,row in ipairs(annotations.annotations) do previous[index]=row end
        local inserted={}
        local ok=pcall(function()
            for _,row in ipairs(pending) do inserted[#inserted+1]={row=row,index=annotations:addItem(row)} end
            reader.doc_settings:saveSetting('annotations',annotations.annotations)
        end)
        if not ok then
            annotations.annotations=previous;reader.doc_settings:saveSetting('annotations',previous)
            host:showInfo(_('Could not copy the annotations. The original book and its notes are kept.'));return
        end
        local flushed,saved=pcall(reader.doc_settings.flush,reader.doc_settings)
        if not flushed or not saved then
            annotations.annotations=previous;reader.doc_settings:saveSetting('annotations',previous)
            host:showInfo(_('Could not confirm saving the copied annotations. The original book and its notes are kept.'));return
        end
        if type(reader.handleEvent)=='function' then
            local event=require('ui/event')
            for _,item in ipairs(inserted) do
                if type(item.index)=='number' then pcall(reader.handleEvent,reader,event:new('AnnotationsModified',{item.row,index_modified=item.index})) end
            end
        end
        if UI.setDirty then UI:setDirty(reader,'ui') end
    end
    host:showInfo(T(_('Copied %1 annotations; %2 already existed; %3 could not be matched. Original notes are kept.'),
        #pending,existing,skipped))
end
function M.cancel(host)
    local job=host.translation_annotations_job;host.translation_annotations_job=nil
    if not job then return end
    if job.step then UI:unschedule(job.step) end
    if host.translation_annotations_worker then host.translation_annotations_worker:cancel() end
    if job.busy and host.busy_message==job.busy then host:closeBusy() end
end
local function current(host,job)
    return Fetch.is_current(host,job.owner) and same_file(stat(job.entry.path),job.info)
        and unchanged(host.ui.annotation and host.ui.annotation.annotations,job.snapshot)
end
function M.view_changed(host)
    local job=host.translation_annotations_job
    if job and not current(host,job) then M.cancel(host) end
end
function M.start(host)
    host:closeWeReadUI()
    local entry,owner,info=Fetch.saved_entry(host)
    local rows=owner and host.ui.annotation and host.ui.annotation.annotations
    if type(rows)=='table' and #rows>Core.MAX_ANNOTATIONS then
        host:showInfo(_('This book has too many annotations to copy at once. The original notes are kept.'));return false
    end
    local snap=owner and snapshot(rows)
    if not entry or not snap or #snap==0 then
        host:showInfo(_('Could not prepare annotations for this translated copy. The original notes are kept.'));return false
    end
    local job={entry=entry,owner=owner,info=info,snapshot=snap,captured={},refs={},skipped=0,index=1,bytes=0,chapters={},chapter_count=0}
    host.translation_annotations_job=job
    host:showBusy(_('Checking local annotations…\nTap or press a key to cancel.'),function() if host.translation_annotations_job==job then M.cancel(host) end end)
    job.busy=host.busy_message
    local function failed()
        M.cancel(host);host:showInfo(_('Could not prepare annotations for this translated copy. The original notes are kept.'))
    end
    job.step=function()
        if host.translation_annotations_job~=job then return end
        if not current(host,job) then M.cancel(host);return end
        local row=job.snapshot[job.index]
        if row then
            local ok,item=pcall(capture,owner.document,owner.book_id,row)
            if ok and item then
                local size=#item.first.node+#(item.last and item.last.node or '')+#(item.quote or '')+#(row.text or '')+#(row.note or '')
                local needed=job.chapters[item.first.uid] and 0 or 1
                if item.last and item.last.uid~=item.first.uid and not job.chapters[item.last.uid] then needed=needed+1 end
                if job.bytes+size<=M.MAX_BYTES and job.chapter_count+needed<=Core.MAX_ANNOTATION_CHAPTERS then
                    if not job.chapters[item.first.uid] then job.chapters[item.first.uid]=true;job.chapter_count=job.chapter_count+1 end
                    if item.last and not job.chapters[item.last.uid] then job.chapters[item.last.uid]=true;job.chapter_count=job.chapter_count+1 end
                    job.bytes=job.bytes+size;job.captured[#job.captured+1]=item
                    job.refs[#job.refs+1]={uid=item.first.uid,metadata=item.first.metadata,first=item.first.xp,
                        last=item.last and item.last.xp,last_uid=item.last and item.last.uid,last_metadata=item.last and item.last.metadata}
                else job.skipped=job.skipped+1 end
            else job.skipped=job.skipped+1 end
            job.index=job.index+1;UI:scheduleIn(0,job.step);return
        end
        job.step=nil
        if #job.refs==0 then M.cancel(host);host:showInfo(_('No local annotations could be matched. The original notes are kept.'));return end
        if not host.translation_annotations_worker then
            local made,worker=pcall(function() return require('weread.lib.memory_worker'):new{scheduler=UI,codec=host.client,max_bytes=2*1024*1024,timeout=1200} end)
            if not made then failed();return end;host.translation_annotations_worker=worker
        end
        local input={book_id=owner.book_id,chapter_uid=owner.source.chapter_uid,metadata=owner.source.metadata,path=owner.file,
            source_file_id=owner.source.identity.file_id,xpointer=owner.location.xpointer}
        local called,started=pcall(host.translation_annotations_worker.start,host.translation_annotations_worker,function()
            local saved=Core.saved(input,entry.path)
            local plan=Core.plan_annotations(input,entry.path,job.refs,entry.file_id)
            return {ok=true,saved=saved,plan=plan}
        end,function(result)
            if host.translation_annotations_job~=job then return end
            if not current(host,job) then M.cancel(host);return end
            if type(result)~='table' or result.ok~=true or type(result.saved)~='table' or not result.saved.ok
                or result.saved.file_id~=entry.file_id or result.saved.bytes~=entry.bytes or type(result.plan)~='table'
                or result.plan.ok~=true or result.plan.total~=#job.refs or type(result.plan.mapped)~='table'
                or #result.plan.mapped>#job.refs then failed();return end
            local seen={}
            for _,mapped in ipairs(result.plan.mapped) do
                if type(mapped)~='table' or type(mapped.index)~='number' or mapped.index%1~=0 or mapped.index<1
                    or mapped.index>#job.refs or seen[mapped.index] or not text(mapped.first,4096)
                    or not text(mapped.last,4096,true) or mapped.uid~=job.refs[mapped.index].uid
                    or mapped.last_uid~=job.refs[mapped.index].last_uid or (mapped.last~=nil)~=(job.refs[mapped.index].last~=nil) then failed();return end
                seen[mapped.index]=true
            end
            local skipped=job.skipped+#job.refs-#result.plan.mapped
            local captured=job.captured;M.cancel(host)
            Fetch.open_copy(host,owner,entry.path,result.saved,function(reader,next_host)
                local applied=pcall(apply,reader,next_host,owner.book_id,entry,info,captured,result.plan.mapped,skipped)
                if not applied then next_host:showInfo(_('Could not copy the annotations. The original book and its notes are kept.')) end
            end)
        end)
        if not called or not started then failed() end
    end
    UI:scheduleIn(0,job.step);return true
end
return M
