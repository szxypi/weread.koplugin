-- Reader-owned, cancellable online search. Search hits remain untrusted until
-- the existing source-navigation worker verifies the selected original text.
local Search=require('weread.lib.book_search')
local Target=require('weread.lib.book_search_target')
local Access=require('weread.lib.read_access')
local Protocol=require('weread.lib.protocol')
local Reading=require('weread.ui.book_reading')
local Navigation=require('weread.ui.my_mark_navigation')
local Popup=require('weread.ui.shelf_popup')
local UI=require('ui/uimanager')
local _=require('weread.lib.plugin_util').tr
local M={}

local function open_downloaded(host,book,chapters,keyword)
    local ok,opened=pcall(function()
        return require('weread.ui.cached_book_search').open(host,book,chapters,keyword)
    end)
    return ok and opened==true
end

local function copy(value)
    if type(value)~='table' then return value end
    local out={}
    for key,item in pairs(value) do out[key]=copy(item) end
    return out
end

local function preview(context,keyword)
    context=context:gsub('[%z%c]',' ')
    local found=context:find(keyword,1,true)
    if not found then
        context=keyword..' · '..context
    elseif found>1 then
        local starts={}
        for index in context:sub(1,found-1):gmatch('()[%z\1-\127\194-\244][\128-\191]*') do starts[#starts+1]=index end
        if #starts>18 then context='…'..context:sub(starts[#starts-17]) end
    end
    return Protocol.utf8_substr(context,90)
end

local function current(host,owner)
    local document=host.ui and host.ui.document
    return host._book_search_owner==owner and not owner.closed and document==owner.document
        and document and document.file==owner.file and (host._reader_session_gen or 0)==owner.session
        and host.library_db and host.library_db:accountKey()==owner.account
        and host.settings:auth_scope_matches(owner.scope)
        and (not owner.menu or not owner.menu._shelf_closed)
end

local function stop_work(host,owner)
    local job=owner.job;owner.job=nil
    if owner.worker then owner.worker:cancel() end
    if job and job.busy and host.busy_message==job.busy then host:closeBusy() end
end

local function stop_recovery(host,owner)
    local recovery=owner.recovery;owner.recovery=nil
    if not recovery then return end
    if recovery.request then require('weread.ui.web_renewal').cancel(host,recovery.request) end
    if recovery.busy and host.busy_message==recovery.busy then host:closeBusy() end
end

function M.cancel(host)
    local owner=host._book_search_owner
    if not owner then return end
    host._book_search_owner=nil;owner.closed=true
    stop_work(host,owner);stop_recovery(host,owner);Navigation.cancel(host,owner)
    local input,menu=owner.input,owner.menu;owner.input=nil;owner.menu=nil
    if input then UI:close(input) end
    if menu then menu._shelf_closed=true;Popup.close(menu);UI:close(menu) end
end

local render,fetch_page,switch_search,choose_chapter,restore_search
render=function(host,owner)
    if not current(host,owner) or not owner.menu then return end
    Popup.redraw(owner.menu,function()
        if not current(host,owner) then return end
        local items={}
        if owner.state and not owner.state.finished and owner.state.pages<128 then
            items[#items+1]={text=_('Load more results'),callback=function()
                if current(host,owner) and not owner.job and not owner.recovery and not owner.navigation then fetch_page(host,owner) end
            end}
        end
        if owner.state and owner.state.pages>0 and owner.state.pages<128 and owner.fallback_state then
            items[#items+1]={text=_('Search from current chapter'),callback=function()
                if current(host,owner) and not owner.job and not owner.recovery and not owner.navigation then
                    switch_search(host,owner,true)
                end
            end}
        elseif owner.primary_state then
            items[#items+1]={text=_('Continue original search'),callback=function()
                if current(host,owner) and not owner.job and not owner.recovery and not owner.navigation then
                    switch_search(host,owner,false)
                end
            end}
        end
        local cached_added=false
        local function cached_option()
            if cached_added then return end
            cached_added=true
            items[#items+1]={text=_('Search downloaded chapters'),callback=function()
                if not current(host,owner) or owner.job or owner.recovery or owner.navigation then return end
                local opened=open_downloaded(host,owner.id,owner.chapters,owner.keyword)
                if not opened and current(host,owner) then host:showInfo(_('Could not search downloaded chapters.')) end
            end}
        end
        -- Local source-index search can find matches omitted by the online
        -- index, including for ordinary books and partially loaded results.
        if owner.state and owner.state.pages>0 and (#owner.value>0 or not owner.state.finished) then cached_option() end
        for _i,hit in ipairs(owner.value) do
            local row=Target.row(owner.id,hit)
            local title=owner.titles[hit.chapter_uid] or _('Chapter unavailable')
            local context=preview(hit.context,hit.text)
            items[#items+1]={text=title..' · '..context,select_enabled=row~=nil,callback=function()
                if current(host,owner) and not owner.job and not owner.recovery and not owner.navigation and row then
                    Navigation.start(host,owner,row,current)
                end
            end}
        end
        if owner.manual_origin then
            items[#items+1]={text=_('Return to previous search'),callback=function()
                if current(host,owner) and not owner.job and not owner.recovery and not owner.navigation then
                    restore_search(host,owner)
                end
            end}
        elseif owner.cb_book and owner.state and owner.state.pages>0 and owner.state.pages<128
            and type(owner.chapters)=='table' and #owner.chapters>1 then
            items[#items+1]={text=_('Search from another chapter'),callback=function()
                if current(host,owner) and not owner.job and not owner.recovery and not owner.navigation then
                    choose_chapter(host,owner)
                end
            end}
        end
        if #owner.value==0 and owner.state and owner.state.finished then
            items[#items+1]={text=_(owner.cb_book and 'No matches returned. Search may be incomplete for this book.'
                or 'No matching text found.'),select_enabled=false}
            cached_option()
        elseif owner.cb_book and #owner.value>0 then
            items[#items+1]={text=_('Search results may be incomplete for this book.'),select_enabled=false}
        end
        if owner.local_available then cached_option() end
        if owner.state and owner.state.pages>=128 and (not owner.state.finished or owner.limit_reached) then
            items[#items+1]={text=_('Search limit reached; results may be incomplete.'),select_enabled=false}
        end
        if not owner.state and owner.retry then
            items[#items+1]={text=_('Retry search'),callback=function()
                if current(host,owner) and not owner.job and not owner.recovery then owner.retry() end
            end}
        elseif #items==0 then
            items[1]={text=_('Searching this book…\nTap or press a key to cancel.'),select_enabled=false}
        end
        owner.menu:switchItemTable(nil,items)
    end)
end

-- Each starting point keeps its own cursor; the page and hit limits and the
-- seen ranges belong to the combined search, including after a switch.
switch_search=function(host,owner,to_fallback)
    local source=owner.state
    local target=to_fallback and owner.fallback_state or owner.primary_state
    if not source or not target then return false end
    target.pages=source.pages;target.seen=source.seen;target.hit_count=source.hit_count
    if to_fallback then
        owner.primary_state=not source.finished and source or nil
        owner.fallback_state=nil;owner.fallback_attempted=true
    else
        owner.fallback_state=not source.finished and source or nil
        owner.primary_state=nil
    end
    owner.state=target;render(host,owner)
    if to_fallback then return fetch_page(host,owner) end
    return true
end

-- An additional chapter search borrows the global page budget and seen set,
-- while the original and automatic-fallback cursors remain untouched.
restore_search=function(host,owner)
    local saved=owner.manual_origin
    if not saved or not owner.state or owner.job or owner.recovery or owner.navigation then return false end
    local completed=owner.state
    saved.state.pages=completed.pages;saved.state.seen=completed.seen;saved.state.hit_count=completed.hit_count
    local unfinished=not completed.finished
    if completed.pages>=128 then
        if unfinished or not saved.state.finished or saved.primary_state and not saved.primary_state.finished
            or saved.fallback_state and not saved.fallback_state.finished
            or owner.manual_cursors and next(owner.manual_cursors) then owner.limit_reached=true end
        owner.manual_cursors=nil
    end
    if unfinished and completed.pages<128 and (saved.resumed or completed.pages>saved.start_pages
            or owner.recovery_state==completed) then
        owner.manual_cursors=owner.manual_cursors or {}
        owner.manual_cursors[saved.uid]={state=completed,recovery_attempted=owner.recovery_state==completed}
        -- The current cursor owns the latest shared set. Parked cursors must
        -- not retain old copies after later worker results replace that set.
        completed.seen=nil
    elseif owner.manual_cursors then owner.manual_cursors[saved.uid]=nil end
    owner.state=saved.state;owner.primary_state=saved.primary_state;owner.fallback_state=saved.fallback_state
    owner.manual_origin=nil;owner.fallback_attempted=true
    render(host,owner)
    return true
end

choose_chapter=function(host,owner)
    if not current(host,owner) or not owner.menu or owner.manual_origin or not owner.state
        or owner.state.pages>=128 or owner.job or owner.recovery or owner.navigation then return false end
    local Menu=require('ui/widget/menu')
    local source=owner.state
    local chapters=owner.chapters
    local page,size,generation=1,40,0
    local dialog
    local function valid(version)
        return current(host,owner) and Popup.current(owner.menu,dialog) and owner.state==source
            and version==generation and not owner.manual_origin and not owner.job and not owner.recovery and not owner.navigation
    end
    local function rows()
        generation=generation+1;local version=generation
        local items={}
        if page>1 then items[#items+1]={text=_('Previous chapters'),callback=function()
            if valid(version) then page=page-1;dialog:switchItemTable(nil,rows()) end
        end} end
        local last=math.min(page*size,#chapters)
        for index=(page-1)*size+1,last do
            local chapter=chapters[index]
            local uid=chapter.chapterUid
            local parked=owner.manual_cursors and owner.manual_cursors[uid]
            items[#items+1]={text=tostring(index)..'. '..chapter.title,mandatory=parked and _('Continue') or '',callback=function()
                if not valid(version) then return end
                local target=parked and parked.state or Search.new(owner.id,owner.keyword,chapters,uid)
                if not target then host:showInfo(_('Could not load this book\'s chapter list.'));return end
                if parked and parked.recovery_attempted then owner.recovery_state=target end
                if parked then owner.manual_cursors[uid]=nil end
                target.pages=source.pages;target.seen=source.seen;target.hit_count=source.hit_count
                target.order=source.order
                owner.manual_origin={state=source,primary_state=owner.primary_state,fallback_state=owner.fallback_state,
                    uid=uid,start_pages=source.pages,resumed=parked~=nil}
                owner.primary_state=nil;owner.fallback_state=nil;owner.state=target;owner.fallback_attempted=true
                Popup.close(owner.menu);render(host,owner);fetch_page(host,owner)
            end}
        end
        if last<#chapters then items[#items+1]={text=_('Next chapters'),callback=function()
            if valid(version) then page=page+1;dialog:switchItemTable(nil,rows()) end
        end} end
        return items
    end
    dialog=Menu:new{title=_('Choose a chapter to search'),item_table=rows(),is_borderless=true,title_bar_fm_style=true}
    return Popup.show(owner.menu,dialog)
end

local function begin_work(host,owner,task,done)
    if not current(host,owner) or owner.job or owner.recovery or owner.navigation then return false end
    local job={};owner.job=job
    host:showBusy(_('Searching this book…\nTap or press a key to cancel.'),function()
        if owner.job==job then stop_work(host,owner);owner.local_available=true;render(host,owner) end
    end)
    job.busy=host.busy_message
    local ok,worker=pcall(function()
        return owner.worker or require('weread.lib.memory_worker'):new{scheduler=UI,codec=host.client,max_bytes=8*1024*1024}
    end)
    if not ok or not worker then stop_work(host,owner);return false end
    owner.worker=worker
    local called,started=pcall(worker.start,worker,task,function(value)
        if owner.job~=job then return end
        if not current(host,owner) then M.cancel(host);return end
        stop_work(host,owner);done(value)
    end)
    if not called or not started then stop_work(host,owner);return false end
    return true
end

fetch_page=function(host,owner,recovered)
    if not current(host,owner) or not owner.state or owner.job or owner.recovery or owner.navigation then return false end
    if not host:isNetworkOnline() then
        owner.local_available=true;render(host,owner);host:showOffline(_('Search entire book'));return false
    end
    local access=Access.capture(host.settings)
    if not access or not access.web then
        owner.local_available=true;render(host,owner)
        host:showInfo(_('A verified WeRead web login is required for online book search.'));return false
    end
    local previous=owner.state
    local work_state=copy(previous)
    local started=begin_work(host,owner,function()
        local page,reason=Search.fetch(host.client,work_state,access)
        return {page=page,state=work_state,reason=reason}
    end,function(value)
        if not Access.matches(host.settings,access) then
            M.cancel(host);host:showInfo(_('WeRead login changed. Search again.'));return
        end
        if owner.state~=previous then return end
        if type(value)=='table' and value.reason=='web_http_401' and value.page==nil
            and type(value.state)=='table' and value.state.book==owner.id and value.state.keyword==owner.keyword
            and value.state.pages==previous.pages and not recovered and owner.recovery_state~=previous then
            local renewal=require('weread.ui.web_renewal')
            owner.recovery_state=previous
            local recovery={};owner.recovery=recovery
            host:showBusy(_('Renewing WeRead login…\nTap or press a key to cancel.'),function()
                if owner.recovery==recovery then stop_recovery(host,owner);owner.local_available=true;render(host,owner) end
            end)
            recovery.busy=host.busy_message
            local called,started,request=pcall(renewal.run,host,{is_current=function()
                return owner.recovery==recovery and current(host,owner) and owner.state==previous and host:isNetworkOnline()
            end},function(ok,reason)
                if owner.recovery~=recovery then return end
                stop_recovery(host,owner)
                if not current(host,owner) or owner.state~=previous then M.cancel(host);return end
                if reason=='session_changed' then M.cancel(host);return end
                if not ok then owner.local_available=true;render(host,owner);host:showInfo(renewal.error_text(reason));return end
                local fresh=Access.capture(host.settings)
                if not fresh or not fresh.web then M.cancel(host);host:showInfo(_('WeRead login changed. Search again.'));return end
                fetch_page(host,owner,true)
            end)
            if owner.recovery==recovery then
                if called and started then recovery.request=request
                else
                    stop_recovery(host,owner);owner.local_available=true;render(host,owner)
                    host:showInfo(renewal.error_text(called and request or 'unavailable'))
                end
            elseif called and started then renewal.cancel(host,request) end
            return
        end
        if type(value)~='table' or value.reason~=nil or type(value.page)~='table' or type(value.page.hits)~='table'
            or type(value.state)~='table' or value.state.book~=owner.id or value.state.keyword~=owner.keyword
            or value.state.pages~=previous.pages+1 or #value.page.hits>1000 then
            local reason=type(value)=='table' and value.reason
            local message=reason=='rate_limited' and 'Search requests are temporarily limited. Wait and try again. Existing results are kept.'
                or (reason=='web_http_401' or reason=='web_expired')
                    and 'The search login is unavailable. Check your login and try again. Existing results are kept.'
                or 'Could not search this book. Check the network and try again.'
            owner.local_available=true;render(host,owner);host:showInfo(_(message));return
        end
        -- The catalog order is immutable for this owner. Keep one shared map
        -- rather than retaining a copy for every parked chapter cursor.
        value.state.order=previous.order
        owner.state=value.state
        for _i,hit in ipairs(value.page.hits) do owner.value[#owner.value+1]=hit end
        if owner.fallback_attempted and #value.page.hits>0 then
            -- The second starting point can return matches before earlier
            -- results. Keep the combined list in book and source order.
            local order=owner.state.order
            table.sort(owner.value,function(a,b)
                if order[a.chapter_uid]~=order[b.chapter_uid] then return order[a.chapter_uid]<order[b.chapter_uid] end
                if a.start~=b.start then return a.start<b.start end
                return a.finish<b.finish
            end)
        end
        if owner.state.finished and owner.manual_origin then
            restore_search(host,owner);return
        elseif owner.state.finished and owner.primary_state then
            switch_search(host,owner,false);return
        elseif owner.cb_book and owner.state.finished and owner.state.pages<128 and owner.fallback_state then
            switch_search(host,owner,true);return
        end
        render(host,owner)
    end)
    if not started then owner.local_available=true;render(host,owner);host:showInfo(_('Could not search this book. Check the network and try again.')) end
    return started
end

local function begin_search(host,owner,chapters)
    if not current(host,owner) then return end
    chapters=Reading.catalog(chapters)
    local state=chapters and Search.new(owner.id,owner.keyword,chapters)
    if not state then owner.local_available=true;render(host,owner);host:showInfo(_('Could not load this book\'s chapter list.'));return end
    if owner.cb_book and owner.current_uid then
        local fallback=Search.new(owner.id,owner.keyword,chapters,owner.current_uid)
        if fallback and fallback.cursor.chapter~=state.cursor.chapter then owner.fallback_state=fallback end
    end
    owner.state=state;owner.titles={};owner.chapters=chapters
    for _i,chapter in ipairs(chapters) do owner.titles[tostring(chapter.chapterUid)]=chapter.title end
    render(host,owner);fetch_page(host,owner)
end

local function prepare_catalog(host,owner,chapters)
    owner.retry=function() prepare_catalog(host,owner,chapters) end
    if Reading.catalog(chapters) then begin_search(host,owner,chapters);return end
    local WorkerSettings=require('weread.lib.worker_settings')
    local fingerprint=WorkerSettings.fingerprint(host.settings)
    local started=begin_work(host,owner,function()
        local Content=require('weread.lib.content')
        local auth=WorkerSettings.capture(host.settings)
        local book=host.settings:get_book(owner.id) or {book_id=owner.id}
        local book_copy={book_id=owner.id,title=book.title,author=book.author,reader_url=book.reader_url}
        Content.ensure_reader_state(host.client,book_copy)
        return {chapters=Reading.catalog(Content.fetch_catalog(host.client,book_copy)),auth=auth()}
    end,function(value)
        if WorkerSettings.fingerprint(host.settings)~=fingerprint or type(value)~='table'
            or value.auth and not WorkerSettings.merge(host.settings,fingerprint,value.auth) then
            owner.local_available=true;render(host,owner);host:showInfo(_('Could not load this book\'s chapter list.'));return
        end
        local prepared_chapters=Reading.catalog(value.chapters)
        local saved=prepared_chapters and pcall(function()
            local Content=require('weread.lib.content')
            local book=host.settings:get_book(owner.id) or {book_id=owner.id}
            assert(host.library_db:putChapters(owner.id,prepared_chapters))
            assert(Content.save_catalog_cache(host.client,host.settings,book,prepared_chapters))
        end)
        if not saved then owner.local_available=true;render(host,owner);host:showInfo(_('Could not load this book\'s chapter list.'));return end
        begin_search(host,owner,prepared_chapters)
    end)
    if not started then owner.local_available=true;render(host,owner);host:showInfo(_('Could not load this book\'s chapter list.')) end
end

function M.open(host,book_id,chapters,current_uid)
    if type(book_id)~='string' or not Access.display_book_id(book_id) then return false end
    local document=host.ui and host.ui.document
    local scope=host.settings:get_auth_scope()
    local account=host.library_db and host.library_db:accountKey()
    if not document or not document.file then return false end
    if not host:isNetworkOnline() then
        if open_downloaded(host,book_id,chapters) then return true end
        host:showOffline(_('Search entire book'));return false
    end
    if scope and not host.settings:auth_scope_matches(scope) then
        host:showInfo(_('A verified WeRead web login is required for online book search.'));return false
    end
    if not account or not scope then
        if open_downloaded(host,book_id,chapters) then return true end
        host:showInfo(_('A verified WeRead web login is required for online book search.'));return false
    end
    local access=Access.capture(host.settings)
    if not access or not access.web then
        if open_downloaded(host,book_id,chapters) then return true end
        host:showInfo(_('A verified WeRead web login is required for online book search.'));return false
    end
    if host.cancelBookSearch then host:cancelBookSearch() else M.cancel(host) end
    local owner={id=book_id,scope=scope,account=account,document=document,file=document.file,
        session=host._reader_session_gen or 0,value={},titles={},search_results=true,cb_book=book_id:sub(1,3)=='CB_',
        current_uid=current_uid}
    host._book_search_owner=owner
    local InputDialog=require('ui/widget/inputdialog')
    local input
    input=InputDialog:new{title=_('Search this book online'),input='',buttons={{
        {text=_('Cancel'),callback=function() if current(host,owner) then M.cancel(host) end end},
        {text=_('Search'),is_enter_default=true,callback=function()
            if not current(host,owner) or owner.input~=input then return end
            local keyword=input:getInputText()
            if type(keyword)~='string' or keyword:match('^%s*$') or #keyword>160
                or keyword:find('[%z%c]') or Protocol.utf8_substr(keyword,#keyword+1)~=keyword then return end
            owner.keyword=keyword
            owner.input=nil;UI:close(input)
            local menu=host:showList(_('Search results'),{{text=_('Searching this book…\nTap or press a key to cancel.'),select_enabled=false}})
            if not menu then M.cancel(host);return end
            owner.menu=menu
            local closed=menu.onCloseWidget
            menu.onCloseWidget=function(instance,...)
                instance._shelf_closed=true;Popup.close(instance)
                if host._book_search_owner==owner then owner.menu=nil;M.cancel(host) end
                if closed then return closed(instance,...) end
            end
            prepare_catalog(host,owner,chapters)
        end},
    }}}
    owner.input=input
    local closed=input.onCloseWidget
    input.onCloseWidget=function(instance,...)
        if owner.input==instance and host._book_search_owner==owner then owner.input=nil;M.cancel(host) end
        if closed then return closed(instance,...) end
    end
    UI:show(input);input:onShowKeyboard();return true
end

return M
