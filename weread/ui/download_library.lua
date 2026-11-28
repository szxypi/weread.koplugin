local Data = require('weread.lib.discovery_data')
local Browse = require('weread.lib.download_browse')
local ReadAccess = require('weread.lib.read_access')
local Search = require('weread.lib.shelf_search')
local Query = require('weread.lib.search_query')
local Plan = require('weread.lib.native_direct_batch_plan')
local ShelfSnapshot = require('weread.lib.shelf_snapshot')
local Popup = require('weread.ui.shelf_popup')
local Scope = require('weread.ui.page_scope')
local Util = require('weread.lib.plugin_util')
local UI = require('ui/uimanager')
local _, T = Util.tr, Util.T
local M = {}
local run
local remembered
local copy_labels = {all='All',standard='Standard downloads',eink='Saved E-Ink chapters',both='Both download types'}

local function owned(record, account)
    return record and account and (record._library_account_key == account
        or record._library_account_key == nil and (record.home_recent_account or record.recent_read_account) == account)
end

local function collect(host, current)
    local account = host.library_db and host.library_db:accountKey()
    if not account then return {}, {} end
    local saved = host.settings:download_books()
    local shelf = host.library_db:getShelf() or {}
    local scope=host.settings.get_auth_scope and host.settings:get_auth_scope()
    local records={}
    if scope then
        for _,kind in ipairs({'eink','standard','selected'}) do
            local store=Plan:new(host.library_db,scope,kind)
            for _,record in ipairs(store:list(current) or {}) do
                records[#records+1]={kind=kind,record=record}
            end
        end
    end
    local rows, seen, books = {}, {}, {}
    for _,entry in ipairs(records) do books[entry.record.book_id]=false end
    local function append(id, source, saved_native)
        if not id or seen[id] then return end
        local row = Data.book(source)
        if not row then return end
        seen[id] = true
        local record, conflict = ReadAccess.cached_book(saved, id)
        if conflict then return end
        local downloaded = host:bookRecordHasDownload(record)
        local native_cached = saved_native or host:nativeChapterCachePresent(id, current)
        if not (downloaded or native_cached or books[id]~=nil) then return end
        row.bookId = id
        if row.title == '' then row.title = id end
        if row.author == '' and type(source.authors)=='string' then row.author = source.authors end
        if books[id]~=nil then books[id]=row end
        if downloaded or native_cached then
            row._cached = true
            row._download_standard = downloaded or nil
            row._download_eink = native_cached or nil
            rows[#rows + 1] = row
        end
    end
    for _, book in ipairs(shelf) do
        append(ReadAccess.display_book_id(ShelfSnapshot.persisted_id(book)), book)
    end
    for key in pairs(saved) do
        local id = ReadAccess.display_book_id(key)
        local record = id and ReadAccess.cached_book(saved, id)
        if owned(record, account) then append(id, record) end
    end
    if scope and host.settings.auth_scope_matches
        and require('weread.lib.native_position_contract').account_key(scope.vid)==account then
        local function native_current()
            return current() and host.settings:auth_scope_matches(scope)
        end
        local cache=require('weread.lib.native_direct_cache')
        for _,entry in ipairs(cache.list_books(host.settings,scope.vid,seen,native_current)) do
            local id=entry.book_id
            local metadata=host.library_db.getBook and host.library_db:getBook(id)
            if not metadata or type(metadata.title)~='string' or metadata.title=='' then
                metadata=cache.book_metadata(host.settings,scope.vid,entry,native_current) or metadata
            end
            append(id,metadata or {bookId=id,title=T(_('Book ID: %1'),id)},true)
        end
    end
    local titles = {}
    for _, row in ipairs(rows) do titles[row] = Search.prepare(row.title) or row.bookId end
    table.sort(rows, function(a,b)
        if titles[a] == titles[b] then return a.bookId < b.bookId end
        return titles[a] < titles[b]
    end)
    local plans={}
    for _,entry in ipairs(records) do
        local id=entry.record.book_id
        local book=books[id]
        if not book and host.library_db.getBook then book=Data.book(host.library_db:getBook(id)) end
        if not book or book.bookId~=id or book.title=='' then book={bookId=id,title=T(_('Book ID: %1'),id)} end
        plans[#plans+1]={book=book,kind=entry.kind,record=entry.record}
    end
    return rows,plans
end

local function downloaded_copies(host,book)
    local record, conflict = ReadAccess.load_cached_book(host.settings, book.bookId)
    if conflict then return false,false end
    return host:bookRecordHasDownload(record),book._download_eink or host:nativeChapterCachePresent(book.bookId),record
end

local function show_detail(host, book, choose_native)
    local downloaded,native_cached,record=downloaded_copies(host,book)
    if not native_cached and (choose_native or not downloaded) then
        host:showInfo(_('No cached file.'))
        return
    end
    local detail = {}
    if owned(record, host.library_db:accountKey()) then
        for key,value in pairs(record) do detail[key] = value end
    end
    for key,value in pairs(Data.book(book)) do detail[key] = value end
    local owner = host.shelf_view
    local menu = host:showBookMenu(detail,{read_saved_native=native_cached and (choose_native or not downloaded)})
    if menu and owner then owner._download_detail_book_id=book.bookId end
    return menu
end

local function show_actions(host, book, view, current, reload)
    if view._shelf_popup then return end
    local dialog
    local function action(callback)
        return function()
            UI:nextTick(function()
                if not current() or not Popup.current(view, dialog) then return end
                Popup.close(view)
                if current() and callback then callback() end
            end)
        end
    end
    local standard,native=downloaded_copies(host,book)
    local both=standard and native
    local buttons={{{text=_(both and 'Continue reading' or 'Read downloaded copy'),callback=action(function()
        host:readFromBookList(Data.book(book),view,current,true,book._download_eink)
    end)}}}
    if both then
        buttons[#buttons+1]={{text=_('Read standard download'),callback=action(function()
            local latest,conflict=ReadAccess.load_cached_book(host.settings,book.bookId)
            if not conflict and host:bookRecordHasDownload(latest) then host:readCachedCopy(latest)
            else host:showInfo(_('No cached file.')) end
        end)}}
        buttons[#buttons+1]={{text=_('Read saved E-Ink chapter'),callback=action(function()
            local detail=show_detail(host,book,true)
            if detail then require('weread.ui.native_direct_reading').start(host,book,detail,{cached=true}) end
        end)}}
    end
    buttons[#buttons+1]={{text=_('Book details'),callback=action(function() show_detail(host,book) end)}}
    if standard then
        buttons[#buttons+1]={{text=_('Clear standard download cache'),callback=action(function()
            local latest,conflict=ReadAccess.load_cached_book(host.settings,book.bookId)
            if not conflict and host:bookRecordHasDownload(latest) then
                host:confirmClearBookCache(book.bookId,book.title,function()
                    if current() then reload(view:getBrowsePosition()) end
                end)
            else host:showInfo(_('No cached file.')) end
        end)}}
    end
    if native then
        buttons[#buttons+1]={{text=_('Clear unused E-Ink chapters'),callback=action(function()
            local detail=show_detail(host,book,true)
            if detail then require('weread.ui.native_direct_cleanup').start(host,book,detail) end
        end)}}
    end
    buttons[#buttons+1]={{text=_('Cancel'),callback=action()}}
    dialog = require('ui/widget/buttondialog'):new{title=book.title,buttons=buttons}
    Popup.show(view, dialog)
end

local function confirm_remove_plan(host, entry, view, menu, current, removed)
    local dialog
    dialog=require('ui/widget/confirmbox'):new{
        text=_('Remove this resume record? Downloaded chapters will still be available.'),
        ok_text=_('Remove resume record'),cancel_text=_('Cancel'),keep_dialog_open=true,
        ok_callback=function()
            if not current() or not Popup.current(view,menu) or not Popup.current(menu,dialog) then return end
            Popup.close(menu)
            run(host,current,_('Removing resume record…'),function()
                local scope=host.settings:get_auth_scope()
                if not scope then return {removed=false} end
                local store=Plan:new(host.library_db,scope,entry.kind)
                return {removed=store:remove(entry.book.bookId,entry.record,current)}
            end,function(result)
                if not Popup.current(view,menu) then return end
                if result and result.removed==true then removed(entry,view,menu)
                else host:showInfo(_('Could not remove this resume record. Refresh the list and try again.')) end
            end)
        end,
    }
    Popup.show(menu,dialog)
end

local function show_plan_actions(host, entry, view, menu, current, removed, reload)
    if menu._shelf_popup then return end
    local dialog
    local function action(callback)
        return function()
            UI:nextTick(function()
                if not current() or not Popup.current(view,menu) or not Popup.current(menu,dialog) then return end
                Popup.close(menu)
                if callback and current() then callback() end
            end)
        end
    end
    local function open(options)
        return function()
            Popup.close(view)
            if not current() then return end
            local detail=host:showBookMenu(entry.book,{read_saved_native=options.cached==true})
            if detail then require('weread.ui.native_direct_reading').start(host,entry.book,detail,options) end
        end
    end
    local buttons
    if entry.kind~='eink' then
        local function finished(ok)
            if ok and current() then reload(view:getBrowsePosition()) end
        end
        local function build_offline()
            Popup.close(view)
            if not current() then return end
            local recovery=require('weread.ui.download_recovery')
            run(host,current,_('Checking saved chapters…'),function()
                return recovery.cachedTargets(host,entry,current)
            end,function(result)
                if not result or not result.plan then
                    host:showInfo(_('The saved download needs verification. Connect to continue.'))
                    return
                end
                local selected=entry.kind=='selected'
                local prompt=selected and _('Build separate EPUBs from the %1 saved chapters?')
                    or _('Build one EPUB from all %1 saved chapters?')
                host:confirmAndDownloadChapters(result.book,result.chapters,selected and 'chapters' or 'full',{
                    separate_chapters=selected,local_only=true,resume_plan=result.plan,on_complete=finished,
                    confirmation_text=T(prompt,result.plan.count), recovery_current=current,
                })
            end,true)
        end
        buttons={
            {{text=_('Continue download'),callback=action(function()
                Popup.close(view)
                local resume=entry.kind=='selected' and host.confirmResumeSelectedChapters or host.confirmDownloadAllChapters
                if current() then resume(host,entry.book,entry.record,finished) end
            end)}},
            {{text=_('Build EPUB offline'),callback=action(build_offline)}},
        }
    else
        buttons={
            {{text=_('Continue download'),callback=action(open({batch=true,resume_plan=entry.record}))}},
            {{text=_('Saved E-Ink chapters'),callback=action(open({cached=true}))}},
        }
    end
    buttons[#buttons+1]={{text=_('Remove resume record'),callback=action(function()
        confirm_remove_plan(host,entry,view,menu,current,removed)
    end)}}
    buttons[#buttons+1]={{text=_('Cancel'),callback=action()}}
    dialog=require('ui/widget/buttondialog'):new{title=entry.book.title,buttons=buttons}
    Popup.show(menu,dialog)
end

local function show_plans(host,plans,removed,reload,page)
    local view=host.shelf_view
    if not view or view._shelf_popup then return end
    local page_current=Scope.capture(host,view)
    local function current() return not host._weread_suspended and page_current() end
    local items,menu={}
    for index,entry in ipairs(plans) do
        local text=entry.kind=='standard' and T(_('Full EPUB · %1 chapters'),entry.record.count)
            or entry.kind=='selected' and T(_('Selected EPUBs · %1 chapters'),entry.record.count)
            or T(_('Chapters %1–%2'),entry.record.first,entry.record.last)
        items[index]={text=text..' · '..entry.book.title,index=index}
    end
    menu=host:showList(_('Unfinished downloads'),items,nil,{on_choice=function(item)
        if type(item)~='table' or not item.index or items[item.index]~=item or not current()
            or not Popup.current(view,menu) then return end
        show_plan_actions(host,plans[item.index],view,menu,current,removed,reload)
    end})
    if not menu then return end
    local closed=menu.onCloseWidget
    menu.onCloseWidget=function(widget,...)
        widget._shelf_closed=true
        Popup.close(widget)
        if closed then return closed(widget,...) end
    end
    Popup.show(view,menu,function() end)
    if page and page>1 then menu:onGotoPage(math.min(page,menu.page_num)) end
end

local load
local function render(host, rows, plans, browse, plan_page, normalize)
    local query, key = browse.query, browse.copy_type
    local positions = Browse.positions(browse)
    local position = positions[key]
    local db = host.library_db
    local account = db and db:accountKey()
    normalize = normalize or Search.cached_fold()
    local books = rows
    if query ~= '' or key ~= 'all' then
        local needle = Search.prepare(query)
        local terms = Search.terms(needle)
        books = {}
        for _, row in ipairs(rows) do
            local matches_type = key == 'all' or key == 'standard' and row._download_standard
                or key == 'eink' and row._download_eink
                or key == 'both' and row._download_standard and row._download_eink
            if matches_type and Search.matches(row, needle, terms, normalize) then books[#books+1] = row end
        end
    end
    local function at(next_position)
        positions[key]=next_position
        return browse
    end
    local function reload(next_position) load(host, at(next_position)) end
    local function open_plans()
        show_plans(host,plans,function(entry,view,menu)
            local remaining={}
            for _,candidate in ipairs(plans) do
                if candidate~=entry then remaining[#remaining+1]=candidate end
            end
            local previous_page=menu.page
            Popup.close(view)
            render(host,rows,remaining,at(view:getBrowsePosition()),previous_page,normalize)
        end,reload,plan_page)
    end
    local anchor = position and position.anchor
    if position and position.book_id then
        anchor = require('weread.ui.library_view').bookIndex(books,position.book_id) or anchor
    end
    local title = key == 'all' and _('Downloaded books') or _(copy_labels[key])
    host:showDiscoveryPage('downloads', books, {
        title = query == '' and title or T(_('%1 · %2'), title, query),
        rotation_anchor = anchor,
        focus_book_id = position and position.focus_book_id,
        capture_download_return = function(view)
            local snapshot = Browse.normalize(browse)
            if not account or not snapshot then return end
            local saved_positions = Browse.positions(snapshot)
            saved_positions[key] = view:getBrowsePosition()
            return function()
                if host.library_db:accountKey() == account then
                    -- Reuse the collected list for Back. Refresh still rescans local files.
                    render(host, rows, plans, snapshot, nil, normalize)
                end
            end
        end,
        remember_position = function(next_position)
            if not account or db:accountKey()~=account then return end
            local snapshot=Browse.normalize(at(next_position))
            if not snapshot then return end
            local saved=remembered and remembered.account==account and remembered.saved
            remembered={account=account,browse=snapshot,saved=saved}
            if Browse.same(snapshot,saved) or not db.putProfileState then return end
            local ok,written=pcall(db.putProfileState,db,Browse.KEY,snapshot)
            if ok and written==true then remembered.saved=snapshot end
        end,
        actions = #plans>0 and {{text=T(_('Unfinished downloads · %1'),#plans),callback=open_plans}} or nil,
        empty_text = query ~= '' and _('No matching books.')
            or key ~= 'all' and _('No downloads match this filter.') or _('No downloaded books for this account.'),
        on_refresh = reload,
        on_return = function(next_position)
            local view = host.shelf_view
            local book_id = view._download_detail_book_id
            view._download_detail_book_id = nil
            if book_id and next_position.focus_book_id ~= book_id then
                next_position.book_id = book_id
                next_position.focus_book_id = nil
            end
            local current = Scope.capture(host, view)
            -- The detail close callback runs before KOReader removes its widget.
            UI:nextTick(function() if current() then reload(next_position) end end)
        end,
        on_settings = function(view, current)
            if view._shelf_popup then return end
            local dialog
            local buttons = {}
            for _index,choice in ipairs(Browse.copy_types) do
                buttons[#buttons+1] = {{ text = _(copy_labels[choice]),
                    checked_func = function() return choice == key end,
                    callback = function()
                        UI:nextTick(function()
                            if not current() or not Popup.current(view,dialog) then return end
                            Popup.close(view)
                            if choice ~= key then
                                at(view:getBrowsePosition())
                                browse.copy_type=choice
                                render(host,rows,plans,browse,nil,normalize)
                            end
                        end)
                    end,
                }}
            end
            dialog = require('ui/widget/buttondialog'):new{title=_('Filter by download type'),buttons=buttons}
            Popup.show(view,dialog)
        end,
        on_search = function(view, current)
            local dialog
            local function submit(value)
                if not current() or not Popup.current(view, dialog) then return end
                local next_query = Query.trim(value)
                if #next_query > 1024 then host:showInfo(_('Search text is too long.')); return end
                Popup.close(view)
                if next_query ~= query then
                    at(view:getBrowsePosition())
                    browse.query=next_query
                    browse.matches={}
                    render(host,rows,plans,browse,nil,normalize)
                end
            end
            dialog = require('ui/widget/inputdialog'):new{
                title = _('Search downloaded books'), input = query, input_type = 'text', buttons = {{
                    { text = _('Clear'), callback = function() submit('') end },
                    { text = _('Search'), is_enter_default = true, callback = function() submit(dialog:getInputText()) end },
                }},
            }
            Popup.show(view, dialog, function(widget) host:showInputDialog(widget) end)
        end,
        on_select = function(book) show_detail(host, book) end,
        on_hold = function(book, view, current)
            show_actions(host, book, view, current, reload)
        end,
    })
    if plan_page and #plans>0 then open_plans() end
end

function M.cancel(host)
    local job = host._download_library_job
    if not job then return end
    host._download_library_job = nil
    job.worker:cancel()
    if job.busy and host.busy_message == job.busy then host:closeBusy() end
end

run = function(host,current,label,task,done,cancellable)
    M.cancel(host)
    local ok, worker = pcall(function()
        return require('weread.lib.memory_worker'):new{ scheduler=UI, codec=host.client, max_bytes=4*1024*1024 }
    end)
    if not ok or not worker then
        if current() then done() end
        return
    end
    local job = { worker=worker }
    host._download_library_job = job
    local cancel=cancellable and function()
        if host._download_library_job==job then M.cancel(host) end
    end or nil
    host:showBusy(label,cancel)
    job.busy = host.busy_message
    local function complete(result)
        if host._download_library_job ~= job then return end
        local live = not host._weread_suspended and current()
        M.cancel(host)
        if live then done(result) end
    end
    local called,started=pcall(worker.start,worker,task,complete)
    if not called or not started then complete() end
end

load = function(host, browse)
    local current = Scope.capture(host, host.shelf_view)
    run(host,current,_('Loading downloaded books…'),function()
        local rows,plans=collect(host,current)
        return {rows=rows,plans=plans}
    end,function(result)
        if not result or type(result.rows)~='table' or type(result.plans)~='table' then
            host:showInfo(_('Could not load downloaded books.'));return
        end
        render(host, result.rows, result.plans, browse)
    end,true)
end

function M.show(host)
    host:closeWeReadUI()
    local db=host.library_db
    local account=db and db:accountKey()
    if account and (not remembered or remembered.account~=account) then
        local ok,value=pcall(db.getProfileState,db,Browse.KEY)
        local saved=ok and Browse.normalize(value)
        remembered={account=account,browse=saved,saved=saved}
    end
    local browse=account and remembered and Browse.normalize(remembered.browse)
    load(host,browse or Browse.new())
end

function M.clearBrowsePosition() remembered=nil end

return M
