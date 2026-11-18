-- Reader-owned search over downloaded source snapshots. All archive work is
-- cancellable and outside the UI process; results never authorize sync.
local Access=require('weread.lib.read_access')
local Search=require('weread.lib.cached_book_search')
local Target=require('weread.lib.cached_search_target')
local Navigation=require('weread.ui.my_mark_navigation')
local Popup=require('weread.ui.shelf_popup')
local Reading=require('weread.ui.book_reading')
local UI=require('ui/uimanager')
local _=require('weread.lib.plugin_util').tr
local T=require('ffi/util').template
local M={MAX_RESULTS=1000}

local function current(host,owner)
    local document=host.ui and host.ui.document
    local scope_ok=owner.scope and host.settings:auth_scope_matches(owner.scope)
        or not owner.scope and not host.settings:get_auth_scope() and host.settings:get('auth_epoch',0)==owner.auth_epoch
    return host._cached_book_search_owner==owner and not owner.closed and document==owner.document
        and document and document.file==owner.file and (host._reader_session_gen or 0)==owner.session
        and host.library_db and host.library_db:accountKey()==owner.account and scope_ok
        and (not owner.menu or not owner.menu._shelf_closed)
end
local function stop(host,owner)
    local job=owner.job;owner.job=nil
    if owner.task then UI:unschedule(owner.task);owner.task=nil end
    if owner.worker then owner.worker:cancel() end
    if owner.catalog_worker then owner.catalog_worker:cancel() end
    if job and job.busy and host.busy_message==job.busy then host:closeBusy() end
end
local function stop_download(host,owner)
    local download=owner.download;owner.download=nil
    if not download then return end
    if download.confirm and owner.menu then Popup.close(owner.menu) end
    if download.complete and host.downloader then
        pcall(host.downloader.cancelRequest,host.downloader,download.complete,'search_closed')
    end
end
function M.cancel(host)
    local owner=host._cached_book_search_owner
    if not owner then return end
    host._cached_book_search_owner=nil;owner.closed=true
    stop(host,owner);stop_download(host,owner);Navigation.cancel(host,owner)
    local input,menu=owner.input,owner.menu;owner.input=nil;owner.menu=nil
    if input then UI:close(input) end
    if menu then menu._shelf_closed=true;Popup.close(menu);UI:close(menu) end
end

local function queue(book,chapters,file,full)
    chapters=Reading.catalog(chapters)
    local catalog_missing=not chapters
    if not chapters then
        local keys,seen={},{}
        for uid in pairs(type(book.cached_chapters)=='table' and book.cached_chapters or {}) do
            uid=Access.book_id(uid)
            if uid and tonumber(uid)<=2147483647 and not seen[uid] then
                keys[#keys+1]=uid;seen[uid]=true
                if #keys>10000 then return nil end
            end
        end
        table.sort(keys,function(a,b) return #a==#b and a<b or #a<#b end)
        chapters={};for _i,uid in ipairs(keys) do chapters[#chapters+1]={chapterUid=uid,title=_('Chapter')..' '..uid} end
    end
    if #chapters>10000 then return nil end
    local result,missing={},0
    for _i,chapter in ipairs(chapters) do
        local uid=tostring(chapter.chapterUid);local paths,seen={},{}
        local mapped=type(book.cached_chapters)=='table' and (book.cached_chapters[uid] or book.cached_chapters[tonumber(uid)])
        local function add(value)
            if type(value)=='string' and value~='' and not seen[value] then paths[#paths+1]=value;seen[value]=true end
        end
        if file==full then add(full);add(mapped) else add(mapped);add(full) end
        if #chapters==1 then add(file) end
        if #paths>0 and tonumber(uid) and tonumber(uid)<=2147483647 then
            result[#result+1]={uid=uid,title=chapter.title,paths=paths}
        else missing=missing+1 end
    end
    return result,missing,#chapters,catalog_missing
end

local render,start,download_missing,fetch_catalog
render=function(host,owner)
    if not current(host,owner) or not owner.menu then return end
    Popup.redraw(owner.menu,function()
        if not current(host,owner) then return end
        local items={}
        if not owner.finished and not owner.job and not owner.limit and not owner.download then
            items[#items+1]={text=_('Continue searching downloaded chapters'),callback=function()
                if current(host,owner) and not owner.job and not owner.navigation and not owner.download then start(host,owner) end
            end}
        end
        -- Keep incomplete coverage and recovery visible even when the result
        -- list spans many pages or the search reached its result limit.
        local incomplete=owner.missing>0 or owner.catalog_missing or owner.discovery_incomplete or owner.limit or owner.unresolved>0
        if owner.limit then items[#items+1]={text=_('Downloaded search result limit reached; results may be incomplete.'),select_enabled=false} end
        if incomplete then
            items[#items+1]={text=T(_('Downloaded search: %1 of %2 chapters checked; %3 unavailable.'),
                owner.checked,owner.total,owner.missing),select_enabled=false}
        end
        if owner.unresolved>0 then
            items[#items+1]={text=_('Some matches could not be located safely and were omitted.'),select_enabled=false}
        end
        if owner.catalog_missing then
            items[#items+1]={text=_(owner.discovered and 'Chapter list unavailable; only indexed downloads were searched.'
                or 'Chapter list unavailable; only mapped downloads were searched.'),select_enabled=false}
        end
        if owner.discovery_incomplete then
            items[#items+1]={text=_('Some chapters in the downloaded book could not be indexed.'),select_enabled=false}
        end
        if (owner.finished or owner.limit) and owner.missing>0 and owner.catalog and not owner.download then
            items[#items+1]={text=_('Download full book and search again'),callback=function()
                if current(host,owner) and not owner.job and not owner.navigation and not owner.download then
                    download_missing(host,owner)
                end
            end}
        end
        if (owner.finished or owner.limit) and owner.catalog_missing and not owner.job and not owner.download then
            items[#items+1]={text=_('Fetch chapter list for this search'),callback=function()
                if current(host,owner) and not owner.job and not owner.navigation and not owner.download then
                    fetch_catalog(host,owner)
                end
            end}
        end
        for _i,hit in ipairs(owner.value) do
            local row=Target.row(owner.id,owner.keyword,hit)
            items[#items+1]={text=(owner.titles[hit.chapter_uid] or _('Chapter unavailable'))..' · '..hit.context,
                select_enabled=row~=nil,callback=function()
                    if current(host,owner) and not owner.job and not owner.navigation and not owner.download and row then
                        Navigation.start(host,owner,row,current)
                    end
                end}
        end
        if owner.finished and #owner.value==0 then
            items[#items+1]={text=_('No locatable matches in downloaded chapters.'),select_enabled=false}
        end
        if not incomplete then
            items[#items+1]={text=T(_('Downloaded search: %1 of %2 chapters checked; %3 unavailable.'),
                owner.checked,owner.total,owner.missing),select_enabled=false}
        end
        owner.menu:switchItemTable(nil,items)
    end)
end

start=function(host,owner)
    if not current(host,owner) or owner.job or owner.navigation or owner.download or owner.finished or owner.limit then return false end
    local ok,worker=pcall(function()
        return owner.worker or require('weread.lib.memory_worker'):new{scheduler=UI,codec=host.client,max_bytes=1024*1024}
    end)
    if not ok or not worker then host:showInfo(_('Could not search downloaded chapters.'));return false end
    owner.worker=worker
    local job={};owner.job=job
    host:showBusy(_('Searching downloaded chapters…\nTap or press a key to stop.'),function()
        if owner.job==job then stop(host,owner);render(host,owner) end
    end)
    job.busy=host.busy_message
    local step
    step=function()
        owner.task=nil
        if owner.job~=job then return end
        if not current(host,owner) then M.cancel(host);return end
        local function later()
            local task;task=function() if owner.task==task then step() end end
            owner.task=task;UI:scheduleIn(.01,task)
        end
        if owner.discovery_pending then
            local request={book=owner.id,file=owner.full}
            local called,started=pcall(worker.start,worker,function() return Search.discover(request) end,function(result)
                if owner.job~=job then return end
                if not current(host,owner) then M.cancel(host);return end
                local valid=type(result)=='table' and not result.error and type(result.entries)=='table'
                    and #result.entries<=10000 and type(result.incomplete)=='boolean'
                local seen,last={},0
                if valid then for _i,row in ipairs(result.entries) do
                    if type(row)~='table' or type(row.uid)~='string' or not Access.book_id(row.uid)
                        or tonumber(row.uid)>2147483647 or type(row.index)~='number' or row.index%1~=0
                        or row.index<=last or row.index>100000 or seen[row.uid] then valid=false;break end
                    seen[row.uid]=true;last=row.index
                end end
                if valid then
                    local mapped,merged={},{}
                    for _i,row in ipairs(owner.queue) do mapped[row.uid]=row end
                    for _i,row in ipairs(result.entries) do
                        local existing=mapped[row.uid]
                        local title=T(_('Downloaded chapter %1'),row.index)
                        merged[#merged+1]=existing or {uid=row.uid,paths={owner.full}}
                        merged[#merged].title=title;owner.titles[row.uid]=title;mapped[row.uid]=nil
                    end
                    for _i,row in ipairs(owner.queue) do if mapped[row.uid] then merged[#merged+1]=row end end
                    if #merged<=10000 then
                        owner.queue=merged;owner.total=#merged;owner.discovered=#result.entries>0
                        owner.discovery_incomplete=result.incomplete
                    else owner.discovery_incomplete=true end
                else owner.discovery_incomplete=true end
                owner.discovery_pending=false
                render(host,owner);later()
            end)
            if not called or not started then stop(host,owner);render(host,owner);host:showInfo(_('Could not search downloaded chapters.')) end
            return
        end
        local chapter=owner.queue[owner.index]
        if not chapter then owner.finished=true;stop(host,owner);render(host,owner);return end
        local from=owner.from
        local request={book=owner.id,chapter=chapter.uid,paths=chapter.paths,keyword=owner.keyword,from=from,
            ignore_ascii_case=owner.ignore_ascii_case}
        local called,started=pcall(worker.start,worker,function() return Search.scan(request) end,function(result)
            if owner.job~=job then return end
            if not current(host,owner) then M.cancel(host);return end
            if type(result)~='table' or type(result.hits)~='table' or #result.hits>Search.MAX_HITS
                or result.error or type(result.unresolved or 0)~='number' or (result.unresolved or 0)%1~=0
                or (result.unresolved or 0)<0 or (result.unresolved or 0)>Search.MAX_EXAMINED
                or result.complete==true and result.next_byte~=nil
                or result.missing==true and (#result.hits~=0 or result.complete or result.next_byte or (result.unresolved or 0)~=0)
                or result.missing~=true and result.complete~=true
                    and (type(result.next_byte)~='number' or result.next_byte%1~=0 or result.next_byte<=from
                        or result.next_byte>require('weread.lib.position_source').MAX_BYTES*4+1) then
                stop(host,owner);render(host,owner);host:showInfo(_('Could not search downloaded chapters.'));return
            end
            for _i,hit in ipairs(result.hits) do
                if type(hit)~='table' or hit.chapter_uid~=chapter.uid or type(hit.context)~='string'
                    or #hit.context>1024 or not Target.row(owner.id,owner.keyword,hit) then
                    stop(host,owner);render(host,owner);host:showInfo(_('Could not search downloaded chapters.'));return
                end
            end
            owner.unresolved=owner.unresolved+(result.unresolved or 0)
            for _i,hit in ipairs(result.hits) do
                if #owner.value>=M.MAX_RESULTS then owner.limit=true;break end
                owner.value[#owner.value+1]=hit
            end
            if result.missing or result.complete then
                owner.checked=owner.checked+1
                if result.missing then owner.missing=owner.missing+1 end
                owner.index=owner.index+1;owner.from=1
            else owner.from=result.next_byte end
            if owner.limit or #owner.value>=M.MAX_RESULTS then owner.limit=true;stop(host,owner);render(host,owner);return end
            render(host,owner)
            later()
        end)
        if not called or not started then stop(host,owner);render(host,owner);host:showInfo(_('Could not search downloaded chapters.')) end
    end
    step();return true
end

fetch_catalog=function(host,owner)
    if not current(host,owner) or not owner.catalog_missing or owner.job or owner.navigation or owner.download then return end
    if not host:isNetworkOnline() then host:showOffline(_('Loading chapter list...'));return end
    if not host:requireLogin(true,false) or not current(host,owner) then return end
    local WorkerSettings=require('weread.lib.worker_settings')
    local fingerprint=WorkerSettings.fingerprint(host.settings)
    local made,worker=pcall(function()
        return owner.catalog_worker or require('weread.lib.memory_worker'):new{scheduler=UI,codec=host.client,max_bytes=8*1024*1024}
    end)
    if not made or not worker then host:showInfo(_("Could not load this book's chapter list."));return end
    owner.catalog_worker=worker
    local job={};owner.job=job
    host:showBusy(_('Loading chapter list...'),function()
        if owner.job==job then stop(host,owner);render(host,owner) end
    end)
    job.busy=host.busy_message
    local called,started=pcall(worker.start,worker,function()
        local Content=require('weread.lib.content')
        local auth=WorkerSettings.capture(host.settings)
        local book=host.settings:get_book(owner.id) or {book_id=owner.id}
        local copy={book_id=owner.id,title=book.title,author=book.author,reader_url=book.reader_url}
        Content.ensure_reader_state(host.client,copy)
        return {book_id=owner.id,chapters=Reading.catalog(Content.fetch_catalog(host.client,copy)),auth=auth()}
    end,function(result)
        if owner.job~=job then return end
        if not current(host,owner) or WorkerSettings.fingerprint(host.settings)~=fingerprint then M.cancel(host);return end
        local chapters=type(result)=='table' and result.book_id==owner.id and Reading.catalog(result.chapters)
        if not chapters or #chapters>10000 or result.auth and not WorkerSettings.merge(host.settings,fingerprint,result.auth) then
            stop(host,owner);render(host,owner);host:showInfo(_("Could not load this book's chapter list."));return
        end
        if not current(host,owner) then M.cancel(host);return end
        local book=host.settings:get_book(owner.id)
        local entries,missing,total
        if type(book)=='table' then entries,missing,total=queue(book,chapters,owner.file,owner.full) end
        local saved=entries and pcall(function()
            local Content=require('weread.lib.content')
            assert(host.library_db:putChapters(owner.id,chapters))
            assert(Content.save_catalog_cache(host.client,host.settings,book,chapters))
        end)
        if not current(host,owner) then M.cancel(host);return end
        if not saved then
            stop(host,owner);render(host,owner);host:showInfo(_("Could not load this book's chapter list."));return
        end
        stop(host,owner)
        owner.catalog,owner.catalog_missing,owner.discovery_pending=chapters,false,false
        owner.discovery_incomplete,owner.discovered=false,false
        owner.queue,owner.missing,owner.total=entries,missing,total
        owner.index,owner.from,owner.checked,owner.unresolved=1,1,0,0
        owner.finished,owner.limit,owner.value,owner.titles=false,false,{},{}
        for _i,entry in ipairs(entries) do owner.titles[entry.uid]=entry.title end
        render(host,owner);start(host,owner)
    end)
    if not called or not started then stop(host,owner);render(host,owner);host:showInfo(_("Could not load this book's chapter list.")) end
end

-- Do not replace an EPUB which KOReader currently has open, including aliases.
local function safe_destination(path,opened)
    if type(path)~='string' or type(opened)~='string' or path==opened then return false end
    local ok,result=pcall(function()
        local lfs=require('libs/libkoreader-lfs')
        local entry,_,entry_errno=lfs.symlinkattributes(path)
        if not entry and entry_errno~=2 then return false end
        if entry and entry.mode=='link' then return false end
        local target,_,errno=lfs.attributes(path)
        if not target then return errno==2 end
        local active=lfs.attributes(opened)
        if not active or target.dev==nil or target.ino==nil or active.dev==nil or active.ino==nil then return false end
        return target.dev~=active.dev or target.ino~=active.ino
    end)
    return ok and result==true
end

download_missing=function(host,owner)
    if not current(host,owner) or not owner.catalog or owner.download then return end
    if not host:isNetworkOnline() then host:showOffline(_('Download full book'));return end
    local download={};owner.download=download
    local confirm
    confirm=require('ui/widget/confirmbox'):new{
        text=T(_('Download all %1 chapters, then search the downloaded book again?'),tostring(#owner.catalog)),
        ok_text=_('Download'),cancel_text=_('Cancel'),keep_dialog_open=true,
        cancel_callback=function()
            if owner.download~=download then return end
            download.confirm=nil;owner.download=nil;Popup.close(owner.menu);render(host,owner)
        end,
        ok_callback=function()
            if owner.download~=download or not current(host,owner) or download.confirm~=confirm then return end
            download.confirm=nil;Popup.close(owner.menu)
            if not host:isNetworkOnline() then owner.download=nil;host:showOffline(_('Download full book'));render(host,owner);return end
            local book=host.settings:get_book(owner.id)
            local ok,path=pcall(function() return require('weread.lib.content').book_epub_path(host.settings,book,'full') end)
            if type(book)~='table' or not ok or not safe_destination(path,owner.file) then
                owner.download=nil;host:showInfo(_('Cannot replace the book currently open in the reader.'));render(host,owner);return
            end
            download.complete=function(success,saved_path)
                if owner.download~=download then return end
                if not success or saved_path~=path or not current(host,owner) then owner.download=nil;render(host,owner);return end
                local task
                task=function()
                    if owner.task~=task then return end
                    owner.task=nil
                    if owner.download~=download or not current(host,owner) then return end
                    owner.download=nil
                    local latest=host.settings:get_book(owner.id)
                    local entries,missing,total
                    if type(latest)=='table' then entries,missing,total=queue(latest,owner.catalog,path,path) end
                    if not entries then host:showInfo(_('Could not search downloaded chapters.'));return end
                    owner.queue,owner.missing,owner.total=entries,missing,total
                    owner.full=path;owner.index,owner.from,owner.checked,owner.unresolved=1,1,0,0
                    owner.finished,owner.limit,owner.value,owner.titles=false,false,{},{}
                    for _i,entry in ipairs(entries) do owner.titles[entry.uid]=entry.title end
                    render(host,owner);start(host,owner)
                end
                owner.task=task;UI:scheduleIn(.1,task)
            end
            if not host.downloader or type(host.downloader.start)~='function' then
                owner.download=nil;host:showInfo(_('Could not download this book.'));render(host,owner);return
            end
            local called,accepted=pcall(host.downloader.start,host.downloader,book,owner.catalog,'full',{
                offer_read=false,silent_completion=true,on_complete=download.complete})
            if owner.download==download and (not called or not accepted) then
                owner.download=nil;host:showInfo(_('Could not download this book.'));render(host,owner)
            end
        end,
    }
    confirm.onCloseWidget=function()
        if owner.download==download and download.confirm==confirm then
            download.confirm=nil;owner.download=nil;render(host,owner)
        end
    end
    download.confirm=confirm;Popup.show(owner.menu,confirm);render(host,owner)
end

function M.open(host,id,chapters,initial_keyword)
    if type(id)~='string' or not Access.display_book_id(id) then return false end
    if initial_keyword~=nil and (type(initial_keyword)~='string' or #initial_keyword>160
        or initial_keyword:find('[%z%c]')) then return false end
    local document=host.ui and host.ui.document
    if not document or not document.file or not host.library_db then return false end
    local scope=host.settings:get_auth_scope()
    if scope and not host.settings:auth_scope_matches(scope) then return false end
    local book=host.settings:get_book(id)
    if type(book)~='table' then return false end
    local full
    if type(host.getFullBookCachePath)=='function' then
        local ok,value=pcall(host.getFullBookCachePath,host,book);if ok then full=value end
    end
    local entries,missing,total,catalog_missing=queue(book,chapters,document.file,full)
    if not entries then host:showInfo(_('Could not search downloaded chapters.'));return false end
    if host.cancelBookSearch then host:cancelBookSearch() else M.cancel(host) end
    local owner={id=id,scope=scope,auth_epoch=host.settings:get('auth_epoch',0),account=host.library_db:accountKey(),
        document=document,file=document.file,session=host._reader_session_gen or 0,local_search=true,search_results=true,
        queue=entries,missing=missing,total=total,catalog_missing=catalog_missing,catalog=Reading.catalog(chapters),
        full=full,discovery_pending=catalog_missing and type(full)=='string' and full~='',
        checked=0,index=1,from=1,unresolved=0,value={},titles={}}
    for _i,entry in ipairs(entries) do owner.titles[entry.uid]=entry.title end
    host._cached_book_search_owner=owner
    local Input=require('ui/widget/inputdialog');local input
    local function search(ignore_ascii_case)
        return function()
            if not current(host,owner) or owner.input~=input then return end
            local keyword=input:getInputText();local normalized=require('weread.lib.source_dom').normalize(keyword)
            if type(keyword)~='string' or #keyword>160 or keyword:find('[%z%c]') or not normalized or normalized=='' then return end
            owner.keyword=keyword;owner.ignore_ascii_case=ignore_ascii_case;owner.input=nil;UI:close(input)
            local menu=host:showList(_('Downloaded search results'),{{text=_('Searching downloaded chapters…'),select_enabled=false}})
            if not menu then M.cancel(host);return end
            owner.menu=menu
            local closed=menu.onCloseWidget
            menu.onCloseWidget=function(instance,...)
                instance._shelf_closed=true;Popup.close(instance)
                if host._cached_book_search_owner==owner then owner.menu=nil;M.cancel(host) end
                if closed then return closed(instance,...) end
            end
            render(host,owner);start(host,owner)
        end
    end
    input=Input:new{title=_('Search downloaded chapters (ignores spaces)'),input=initial_keyword or '',buttons={{
        {text=_('Cancel'),callback=function() if current(host,owner) then M.cancel(host) end end},
        {text=_('Search (match case)'),is_enter_default=true,callback=search(false)},
    },{
        {text=_(Search.unicode_casefold_available() and 'Search (ignore case)' or 'Search (ignore English case)'),callback=search(true)},
    }}}
    owner.input=input
    local closed=input.onCloseWidget
    input.onCloseWidget=function(instance,...)
        if owner.input==instance and host._cached_book_search_owner==owner then owner.input=nil;M.cancel(host) end
        if closed then return closed(instance,...) end
    end
    UI:show(input);input:onShowKeyboard();return true
end
return M
