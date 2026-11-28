-- Reader-owned, offline search over verified native chapter copies.
local UI=require('ui/uimanager')
local Popup=require('weread.ui.shelf_popup')
local Cache=require('weread.lib.native_direct_cache')
local Search=require('weread.lib.native_direct_search')
local Context=require('weread.lib.source_context')
local _=require('weread.lib.plugin_util').tr
local T=require('ffi/util').template
local M={MAX_RESULTS=300}
local REDRAW_INTERVAL=.5
local function location(reader,doc) return Context.location(doc,reader.view and reader.view.view_mode) end
local function current(host,owner)
    local reader=host.ui
    return host._native_direct_search==owner and not owner.closed and reader==owner.reader
        and reader.document==owner.document and owner.document.file==owner.file
        and (host._reader_session_gen or 0)==owner.session and host.settings:auth_scope_matches(owner.scope)
        and host.library_db and host.library_db:accountKey()==owner.account
        and Context.same_location(owner.location,location(reader,owner.document))
        and (not owner.menu or not owner.menu._shelf_closed)
end
local function stop(host,owner)
    local job=owner.job;owner.job=nil
    if owner.task then UI:unschedule(owner.task);owner.task=nil end
    if job and job.redraw then UI:unschedule(job.redraw);job.redraw=nil end
    if owner.worker then owner.worker:cancel() end
    if job and job.busy and host.busy_message==job.busy then host:closeBusy() end
end
function M.cancel(host)
    local owner=host._native_direct_search
    if not owner then return end
    host._native_direct_search=nil;owner.closed=true;stop(host,owner)
    local navigation=owner.navigation;owner.navigation=nil
    if navigation then navigation.cancel(host) end
    local input,menu=owner.input,owner.menu;owner.input=nil;owner.menu=nil
    if input then UI:close(input) end
    if menu then menu._shelf_closed=true;Popup.close(menu);UI:close(menu) end
end
function M.on_view_changed(host)
    local owner=host._native_direct_search
    if owner and not current(host,owner) then M.cancel(host) end
end
local function group(rows,entry,vid)
    if type(rows)~='table' or #rows>Cache.MAX_ENTRIES then return nil end
    local groups,by_key={},{}
    for _,row in ipairs(rows) do
        if not Cache.valid_entry(row,entry.book_id,vid) then return nil end
        if row.book_version==entry.book_version and (not entry.catalog_sha256 or row.catalog_sha256==entry.catalog_sha256) then
            local key=row.chapter_uid..'\0'..row.source_sha256
            local chapter=by_key[key]
            if not chapter then
                chapter={title=row.title,uid=row.chapter_uid,copies={}};by_key[key]=chapter;groups[#groups+1]=chapter
            end
            chapter.copies[#chapter.copies+1]=row
        end
    end
    return groups
end
local render,start
render=function(host,owner)
    if not current(host,owner) or not owner.menu then return end
    Popup.redraw(owner.menu,function()
        if not current(host,owner) then return end
        local items={}
        if owner.limit then
            items[#items+1]={text=_('Downloaded search result limit reached; results may be incomplete.'),select_enabled=false}
            items[#items+1]={text=_('Search next batch (keeps only the previous batch)'),callback=function()
                if current(host,owner) and owner.limit and not owner.job and not owner.navigation then
                    owner.previous=owner.value;owner.value={};owner.limit=false;owner.show_previous=false
                    owner.batch=owner.batch+1;render(host,owner);start(host,owner)
                end
            end}
        end
        if owner.previous and not owner.job then
            items[#items+1]={text=_(owner.show_previous and 'Show current result batch' or 'Show previous result batch'),callback=function()
                if current(host,owner) and not owner.job and not owner.navigation then
                    owner.show_previous=not owner.show_previous;render(host,owner)
                end
            end}
        end
        if not owner.finished and not owner.limit and not owner.job then
            items[#items+1]={text=_('Continue searching downloaded chapters'),callback=function() start(host,owner) end}
        end
        items[#items+1]={text=T(_('Downloaded search: %1 of %2 chapters checked; %3 unavailable.'),
            owner.checked,#owner.queue,owner.unavailable),select_enabled=false}
        items[#items+1]={text=_('Chapter list unavailable; only indexed downloads were searched.'),select_enabled=false}
        if owner.unresolved>0 then items[#items+1]={text=_('Some matches could not be located safely and were omitted.'),select_enabled=false} end
        local values=owner.show_previous and owner.previous or owner.value
        for _,value in ipairs(values) do
            local hit=value.hit;local visible=values
            items[#items+1]={text=value.title..' · '..hit.context,callback=function()
                if not current(host,owner) or owner.job or owner.navigation
                    or (owner.show_previous and owner.previous or owner.value)~=visible then return end
                local Open=require('weread.ui.native_direct_search_open')
                local navigation={cancel=Open.cancel};owner.navigation=navigation
                local function release()
                    if owner.navigation==navigation then owner.navigation=nil end
                end
                if not Open.start(host,value.entry,hit,owner.keyword,owner.ignore_case,{
                    is_current=function() return host._native_direct_search==owner and owner.navigation==navigation end,
                    on_commit=function() release();M.cancel(host) end,
                    on_finish=release,
                }) then release() end
            end}
        end
        if owner.finished and #values==0 then items[#items+1]={text=_('No locatable matches in downloaded chapters.'),select_enabled=false} end
        owner.menu:switchItemTable(nil,items)
    end)
end
local function valid_result(result,entry,from)
    if type(result)~='table' or result.error or type(result.hits)~='table' or #result.hits>Search.MAX_HITS
        or type(result.unresolved)~='number' or result.unresolved%1~=0 or result.unresolved<0 or result.unresolved>Search.MAX_EXAMINED
        or result.complete~=true and (type(result.next_byte)~='number' or result.next_byte%1~=0 or result.next_byte<=from)
        or result.complete==true and result.next_byte~=nil then return false end
    for _,hit in ipairs(result.hits) do
        if type(hit)~='table' or hit.chapter_uid~=entry.chapter_uid or type(hit.byte)~='number'
            or hit.byte%1~=0 or hit.byte<from or type(hit.file_id)~='string' or #hit.file_id~=64
            or not hit.file_id:match('^[a-f0-9]+$') or type(hit.context)~='string' or #hit.context>1024
            or type(hit.anchor)~='table' then return false end
    end
    return true
end
start=function(host,owner)
    if not current(host,owner) or owner.job or owner.navigation or owner.finished or owner.limit then return end
    local ok,worker=pcall(function() return owner.worker or require('weread.lib.memory_worker'):new{
        scheduler=UI,codec=host.client,max_bytes=8*1024*1024,timeout=180} end)
    if not ok then host:showInfo(_('Could not search downloaded chapters.'));return end
    owner.worker=worker;local job={};owner.job=job
    host:showBusy(_('Searching downloaded chapters…\nTap or press a key to stop.'),function()
        if owner.job==job then stop(host,owner);render(host,owner) end
    end);job.busy=host.busy_message
    local function progress()
        if job.redraw then return end
        job.redraw=function()
            job.redraw=nil
            if owner.job==job then render(host,owner) end
        end
        UI:scheduleIn(REDRAW_INTERVAL,job.redraw)
    end
    local step
    local function later()
        local task;task=function() if owner.task==task then owner.task=nil;step() end end
        owner.task=task;UI:scheduleIn(.01,task)
    end
    step=function()
        if owner.job~=job then return end
        if not current(host,owner) then M.cancel(host);return end
        if not owner.loaded then
            local called,started=pcall(worker.start,worker,function()
                return {rows=Cache.list(host.settings,owner.scope.vid,owner.entry.book_id,
                    function() return host.settings:auth_scope_matches(owner.scope) end)}
            end,function(result)
                if owner.job~=job then return end
                if not current(host,owner) then M.cancel(host);return end
                local queue=type(result)=='table' and group(result.rows,owner.entry,owner.scope.vid)
                if not queue then stop(host,owner);render(host,owner);host:showInfo(_('Could not search downloaded chapters.'));return end
                owner.queue,owner.loaded=queue,true;progress();later()
            end)
            if not called or not started then stop(host,owner);render(host,owner);host:showInfo(_('Could not search downloaded chapters.')) end
            return
        end
        local chapter=owner.queue[owner.index]
        if not chapter then owner.finished=true;stop(host,owner);render(host,owner);return end
        local entry=chapter.copies[owner.copy];local from=owner.from
        local called,started=pcall(worker.start,worker,function()
            return Search.scan(host.settings,owner.scope.vid,entry,owner.keyword,from,owner.ignore_case,
                function() return host.settings:auth_scope_matches(owner.scope) end)
        end,function(result)
            if owner.job~=job then return end
            if not current(host,owner) then M.cancel(host);return end
            if not valid_result(result,entry,from) then
                if owner.from==1 and owner.copy<#chapter.copies then owner.copy=owner.copy+1
                else owner.unavailable=owner.unavailable+1;owner.index=owner.index+1;owner.copy=1;owner.from=1 end
            else
                owner.unresolved=owner.unresolved+result.unresolved
                for _,hit in ipairs(result.hits) do owner.value[#owner.value+1]={entry=entry,hit=hit,title=chapter.title} end
                if result.complete then owner.checked=owner.checked+1;owner.index=owner.index+1;owner.copy=1;owner.from=1
                else owner.from=result.next_byte end
            end
            if #owner.value>=M.MAX_RESULTS then owner.limit=true;stop(host,owner);render(host,owner);return end
            progress();later()
        end)
        if not called or not started then stop(host,owner);render(host,owner);host:showInfo(_('Could not search downloaded chapters.')) end
    end
    step()
end
function M.open(host,entry,initial_keyword)
    if initial_keyword~=nil and (type(initial_keyword)~='string' or #initial_keyword>160
        or initial_keyword:find('[%z%c]')) then return false end
    local reader=host.ui;local doc=reader and reader.document;local scope=host.settings:get_auth_scope()
    local at=doc and location(reader,doc)
    if not at or not scope or not host.settings:auth_scope_matches(scope) or not host.library_db
        or not host.library_db:accountKey() or not Cache.valid_entry(entry,entry and entry.book_id,scope.vid) then return false end
    if host.cancelBookSearch then host:cancelBookSearch() else M.cancel(host) end
    local owner={reader=reader,document=doc,file=doc.file,scope=scope,account=host.library_db:accountKey(),
        location=at,session=host._reader_session_gen or 0,entry=entry,queue={},index=1,copy=1,from=1,
        checked=0,unavailable=0,unresolved=0,value={},batch=1}
    host._native_direct_search=owner
    local input
    local function search(ignore_case)
        return function()
            if not current(host,owner) or owner.input~=input then return end
            local keyword=input:getInputText();local normalized=require('weread.lib.source_dom').normalize(keyword)
            if type(keyword)~='string' or #keyword>160 or keyword:find('[%z%c]') or not normalized or normalized=='' then return end
            owner.keyword=keyword;owner.ignore_case=ignore_case;owner.input=nil;UI:close(input)
            local menu=host:showList(_('Downloaded search results'),{{text=_('Searching downloaded chapters…'),select_enabled=false}})
            if not menu then M.cancel(host);return end
            owner.menu=menu;local closed=menu.onCloseWidget
            menu.onCloseWidget=function(instance,...)
                instance._shelf_closed=true;Popup.close(instance)
                if host._native_direct_search==owner then owner.menu=nil;M.cancel(host) end
                if closed then return closed(instance,...) end
            end
            render(host,owner);start(host,owner)
        end
    end
    input=require('ui/widget/inputdialog'):new{title=_('Search downloaded chapters (ignores spaces)'),input=initial_keyword or '',buttons={{
        {text=_('Cancel'),callback=function() if current(host,owner) then M.cancel(host) end end},
        {text=_('Search (match case)'),is_enter_default=true,callback=search(false)}},{
        {text=_(require('weread.lib.unicode_search').available() and 'Search (ignore case)' or 'Search (ignore English case)'),callback=search(true)}}}}
    owner.input=input;local closed=input.onCloseWidget
    input.onCloseWidget=function(instance,...)
        if owner.input==instance and host._native_direct_search==owner then owner.input=nil;M.cancel(host) end
        if closed then return closed(instance,...) end
    end
    UI:show(input);input:onShowKeyboard();return true
end
return M
